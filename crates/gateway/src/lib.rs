mod auth;
mod config;

use std::{str::FromStr, sync::Arc, time::Duration};

use auth::{PrincipalError, security_groups};
use axum::{
    Json, Router,
    body::{Body, to_bytes},
    extract::State,
    http::{HeaderMap, Method, Request, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use azdq_policy::{PolicyError, Role, RolePolicy};
use futures_util::StreamExt as _;
use serde::Serialize;
use thiserror::Error;
use tokio::sync::Semaphore;
use tracing::instrument;

pub use config::Settings;

const ROLE_HEADER: &str = "x-ducklake-role";
const MAX_QUACK_REQUEST_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone)]
struct AppState {
    settings: Settings,
    policy: RolePolicy,
    client: reqwest::Client,
    reader_limit: Arc<Semaphore>,
    writer_limit: Arc<Semaphore>,
}

/// Build the gateway router and its shared HTTP client.
///
/// # Errors
///
/// Returns an error if the HTTP client cannot be constructed.
pub fn app(settings: Settings) -> anyhow::Result<Router> {
    let policy = RolePolicy::new(&settings.reader_group_id, &settings.writer_group_id);
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        // ACA has a 240-second HTTP request limit; finish first so failures are explicit.
        .timeout(Duration::from_secs(230))
        .build()?;
    let state = Arc::new(AppState {
        settings,
        policy,
        client,
        reader_limit: Arc::new(Semaphore::new(1)),
        writer_limit: Arc::new(Semaphore::new(1)),
    });

    Ok(Router::new()
        .route("/healthz", get(health))
        .route("/readyz", get(health))
        .route("/session", get(session))
        .route("/quack", post(proxy_quack))
        .with_state(state))
}

async fn health() -> StatusCode {
    StatusCode::NO_CONTENT
}

#[derive(Serialize)]
struct SessionResponse {
    role: Role,
    quack_uri: String,
    token: String,
    query_mode: &'static str,
    catalog: &'static str,
}

async fn session(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<SessionResponse>, GatewayError> {
    let role = resolve_role(&state, &headers)?;
    let (token, uri) = match role {
        Role::Reader => (
            &state.settings.reader_quack_token,
            &state.settings.public_quack_uri,
        ),
        Role::Writer => (
            &state.settings.writer_quack_token,
            &state.settings.public_quack_uri,
        ),
    };

    Ok(Json(SessionResponse {
        role,
        quack_uri: uri.clone(),
        token: token.clone(),
        query_mode: "quack_query",
        catalog: "lake",
    }))
}

#[instrument(skip_all, fields(role))]
async fn proxy_quack(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    request: Request<Body>,
) -> Result<Response, GatewayError> {
    let role = resolve_role(&state, &headers)?;
    tracing::Span::current().record("role", tracing::field::display(role));
    let (backend, limiter) = match role {
        Role::Reader => (
            &state.settings.reader_backend_url,
            Arc::clone(&state.reader_limit),
        ),
        Role::Writer => (
            &state.settings.writer_backend_url,
            Arc::clone(&state.writer_limit),
        ),
    };
    let permit = limiter
        .acquire_owned()
        .await
        .map_err(|_| GatewayError::CapacityClosed)?;
    let url = format!("{}/quack", backend.trim_end_matches('/'));
    let (parts, body) = request.into_parts();
    // Quack's embedded HTTP server expects a concrete Content-Length. Buffer one
    // bounded protocol message so reqwest emits that header instead of chunked
    // transfer encoding. Responses remain streamed while the permit is held.
    let payload = to_bytes(body, MAX_QUACK_REQUEST_BYTES)
        .await
        .map_err(GatewayError::RequestBody)?;
    let mut outbound = state.client.request(Method::POST, url);

    // Only protocol-relevant headers cross the trust boundary. Easy Auth identity headers
    // and the public bearer token are intentionally not forwarded to the Quack backend.
    for name in [
        header::CONTENT_TYPE,
        header::ACCEPT,
        header::CONTENT_ENCODING,
    ] {
        if let Some(value) = parts.headers.get(&name) {
            outbound = outbound.header(name, value);
        }
    }

    let upstream = outbound
        .body(payload)
        .send()
        .await
        .map_err(GatewayError::Upstream)?;
    let status = upstream.status();
    let response_headers = upstream.headers().clone();
    let stream = upstream.bytes_stream();
    let guarded_stream = async_stream::stream! {
        // Retain the permit until the full streaming response has been consumed.
        let _permit = permit;
        futures_util::pin_mut!(stream);
        while let Some(chunk) = stream.next().await {
            yield chunk.map_err(std::io::Error::other);
        }
    };
    let mut response = Response::new(Body::from_stream(guarded_stream));
    *response.status_mut() = status;
    for name in [header::CONTENT_TYPE, header::CONTENT_ENCODING] {
        if let Some(value) = response_headers.get(&name) {
            response.headers_mut().insert(name, value.clone());
        }
    }
    Ok(response)
}

fn resolve_role(state: &AppState, headers: &HeaderMap) -> Result<Role, GatewayError> {
    let groups = security_groups(headers)?;
    let mut role_headers = headers.get_all(ROLE_HEADER).iter();
    let role_header = role_headers.next();
    if role_headers.next().is_some() {
        return Err(GatewayError::InvalidRoleHeader);
    }
    let requested = role_header
        .map(|value| value.to_str().map_err(|_| GatewayError::InvalidRoleHeader))
        .transpose()?
        .map(Role::from_str)
        .transpose()?;
    state.policy.resolve(&groups, requested).map_err(Into::into)
}

#[derive(Debug, Error)]
enum GatewayError {
    #[error(transparent)]
    Principal(#[from] PrincipalError),
    #[error(transparent)]
    Policy(#[from] PolicyError),
    #[error("role header is not valid UTF-8")]
    InvalidRoleHeader,
    #[error("the selected backend is unavailable")]
    Upstream(#[source] reqwest::Error),
    #[error("the query capacity limiter is unavailable")]
    CapacityClosed,
    #[error("the Quack request body is invalid or exceeds 32 MiB")]
    RequestBody(#[source] axum::Error),
}

impl IntoResponse for GatewayError {
    fn into_response(self) -> Response {
        let (status, public_message) = match &self {
            Self::Principal(_) => (
                StatusCode::UNAUTHORIZED,
                "authentication context is invalid",
            ),
            Self::Policy(_) | Self::InvalidRoleHeader => {
                (StatusCode::FORBIDDEN, "role is not granted")
            }
            Self::Upstream(_) => (StatusCode::BAD_GATEWAY, "DuckLake backend is unavailable"),
            Self::CapacityClosed => (
                StatusCode::SERVICE_UNAVAILABLE,
                "query capacity is unavailable",
            ),
            Self::RequestBody(_) => (StatusCode::PAYLOAD_TOO_LARGE, "Quack request is too large"),
        };
        tracing::warn!(error = %self, "gateway request rejected");
        (status, Json(serde_json::json!({ "error": public_message }))).into_response()
    }
}
