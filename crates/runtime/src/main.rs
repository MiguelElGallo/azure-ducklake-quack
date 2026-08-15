use anyhow::Result;
use std::sync::{Arc, Mutex};

use axum::{Router, extract::State, http::StatusCode, routing::get};
use azdq_runtime::Settings;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .json()
        .init();
    let settings = Settings::from_env()?;
    let health_addr = settings.health_addr;
    let runtime = Arc::new(Mutex::new(azdq_runtime::start(&settings)?));

    let health = Router::new()
        .route("/healthz", get(health_status))
        .route("/readyz", get(health_status))
        .with_state(runtime);
    let listener = TcpListener::bind(health_addr).await?;
    tracing::info!(address = %health_addr, "runtime ready");
    axum::serve(listener, health).await?;
    Ok(())
}

async fn health_status(
    State(runtime): State<Arc<Mutex<azdq_runtime::RuntimeProcess>>>,
) -> StatusCode {
    match runtime.lock() {
        Ok(mut runtime) => {
            if runtime.is_running().unwrap_or(false) {
                StatusCode::NO_CONTENT
            } else {
                StatusCode::SERVICE_UNAVAILABLE
            }
        }
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}
