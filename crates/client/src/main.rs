use std::{
    collections::HashMap, env, fmt::Write as _, path::PathBuf, process::Stdio, str::FromStr,
    time::Duration,
};

use anyhow::{Context, Result, bail};
use azdq_policy::Role;
use clap::{Parser, Subcommand};
use serde::Deserialize;
use tokio::{io::AsyncWriteExt as _, process::Command, time::sleep};

#[derive(Parser)]
#[command(
    version,
    about = "Entra-authenticated DuckDB Quack client for Azure DuckLake"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Authenticate with device code and execute SQL through `quack_query()`.
    Sql {
        #[arg(long, env = "AZDQ_TENANT_ID")]
        tenant_id: String,
        #[arg(long, env = "AZDQ_CLIENT_ID")]
        client_id: String,
        #[arg(long, env = "AZDQ_SCOPE")]
        scope: String,
        #[arg(long, env = "AZDQ_ENDPOINT")]
        endpoint: String,
        /// Primary role. When omitted, the service selects its default reader role.
        #[arg(long)]
        role: Option<String>,
        #[arg(short, long)]
        query: String,
        #[arg(long, env = "DUCKDB_PATH", default_value = "duckdb")]
        duckdb: PathBuf,
    },
}

#[derive(Deserialize)]
struct DeviceCodeResponse {
    device_code: String,
    message: String,
    interval: Option<u64>,
    expires_in: u64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
}

#[derive(Deserialize)]
struct OAuthError {
    error: String,
    error_description: Option<String>,
}

#[derive(Deserialize)]
struct SessionResponse {
    role: Role,
    quack_uri: String,
    token: String,
    query_mode: String,
    catalog: String,
}

struct TestPrincipal {
    encoded: String,
    subject_id: String,
    disable_ssl: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    match Cli::parse().command {
        Commands::Sql {
            tenant_id,
            client_id,
            scope,
            endpoint,
            role,
            query,
            duckdb,
        } => {
            let role = role.as_deref().map(Role::from_str).transpose()?;
            let expected_role = role.unwrap_or(Role::Reader);
            let http = reqwest::Client::new();
            let access_token = match env::var("AZDQ_ACCESS_TOKEN") {
                Ok(token) if !token.is_empty() => token,
                _ => device_login(&http, &tenant_id, &client_id, &scope).await?,
            };
            let test_principal = test_principal_from_env()?;
            let session = create_session(
                &http,
                &endpoint,
                role,
                &access_token,
                test_principal.as_ref(),
            )
            .await?;
            if session.role != expected_role
                || session.query_mode != "quack_query"
                || session.catalog != "lake"
            {
                bail!("gateway returned an incompatible session contract");
            }
            run_duckdb(
                &duckdb,
                &session,
                &access_token,
                test_principal.as_ref(),
                &query,
            )
            .await?;
        }
    }
    Ok(())
}

async fn device_login(
    http: &reqwest::Client,
    tenant_id: &str,
    client_id: &str,
    scope: &str,
) -> Result<String> {
    let authority = format!("https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0");
    let device: DeviceCodeResponse = http
        .post(format!("{authority}/devicecode"))
        .form(&[("client_id", client_id), ("scope", scope)])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    eprintln!("{}", device.message);

    let mut interval = device.interval.unwrap_or(5).max(1);
    let started = tokio::time::Instant::now();
    loop {
        if started.elapsed() >= Duration::from_secs(device.expires_in) {
            bail!("device-code login expired before authentication completed");
        }
        sleep(Duration::from_secs(interval)).await;
        let response = http
            .post(format!("{authority}/token"))
            .form(&HashMap::from([
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("client_id", client_id),
                ("device_code", device.device_code.as_str()),
            ]))
            .send()
            .await?;
        if response.status().is_success() {
            return Ok(response.json::<TokenResponse>().await?.access_token);
        }
        let error: OAuthError = response
            .json()
            .await
            .context("identity provider returned an unreadable error")?;
        match error.error.as_str() {
            "authorization_pending" => {}
            "slow_down" => interval += 5,
            _ => bail!(
                "device-code login failed: {}",
                error.error_description.unwrap_or(error.error)
            ),
        }
    }
}

async fn create_session(
    http: &reqwest::Client,
    endpoint: &str,
    role: Option<Role>,
    access_token: &str,
    test_principal: Option<&TestPrincipal>,
) -> Result<SessionResponse> {
    let mut request = http
        .get(format!("{}/session", endpoint.trim_end_matches('/')))
        .bearer_auth(access_token);
    if let Some(role) = role {
        request = request.header("x-ducklake-role", role.to_string());
    }
    if let Some(principal) = test_principal {
        request = request
            .header("x-ms-client-principal", &principal.encoded)
            .header("x-ms-client-principal-id", &principal.subject_id);
    }
    request
        .send()
        .await?
        .error_for_status()?
        .json()
        .await
        .context("gateway returned an invalid session response")
}

async fn run_duckdb(
    executable: &PathBuf,
    session: &SessionResponse,
    access_token: &str,
    test_principal: Option<&TestPrincipal>,
    query: &str,
) -> Result<()> {
    let sql = build_sql(session, access_token, test_principal, query);
    let mut child = Command::new(executable)
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("failed to start {}", executable.display()))?;
    let mut stdin = child.stdin.take().context("DuckDB stdin is unavailable")?;
    stdin.write_all(sql.as_bytes()).await?;
    drop(stdin);
    let status = child.wait().await?;
    if !status.success() {
        bail!("DuckDB exited with {status}");
    }
    Ok(())
}

fn build_sql(
    session: &SessionResponse,
    access_token: &str,
    test_principal: Option<&TestPrincipal>,
    query: &str,
) -> String {
    // Quack currently serves attached external catalogs reliably through its
    // server-side query path. Select the DuckLake catalog inside every request.
    let server_query = format!("USE {};\n{query}", session.catalog);
    let mut headers = format!(
        "'Authorization': {}, 'X-DuckLake-Role': {}",
        sql_string(&format!("Bearer {access_token}")),
        sql_string(&session.role.to_string())
    );
    if let Some(principal) = test_principal {
        write!(
            headers,
            ", 'X-MS-CLIENT-PRINCIPAL': {}, 'X-MS-CLIENT-PRINCIPAL-ID': {}",
            sql_string(&principal.encoded),
            sql_string(&principal.subject_id)
        )
        .expect("writing to a String cannot fail");
    }
    let query_options = if test_principal.is_some_and(|principal| principal.disable_ssl) {
        ", disable_ssl => true"
    } else {
        ""
    };
    format!(
        "LOAD quack;\n\
         CREATE SECRET azdq_session (\n\
           TYPE quack, SCOPE {}, TOKEN {},\n\
           EXTRA_HTTP_HEADERS MAP {{{}}}\n\
         );\n\
         FROM quack_query({}, {}{});\n",
        sql_string(&session.quack_uri),
        sql_string(&session.token),
        headers,
        sql_string(&session.quack_uri),
        sql_string(&server_query),
        query_options,
    )
}

fn test_principal_from_env() -> Result<Option<TestPrincipal>> {
    match (
        env::var("AZDQ_TEST_CLIENT_PRINCIPAL").ok(),
        env::var("AZDQ_TEST_CLIENT_PRINCIPAL_ID").ok(),
    ) {
        (None, None) => Ok(None),
        (Some(encoded), Some(subject_id)) if !encoded.is_empty() && !subject_id.is_empty() => {
            Ok(Some(TestPrincipal {
                encoded,
                subject_id,
                disable_ssl: env::var("AZDQ_TEST_DISABLE_SSL").is_ok_and(|value| value == "true"),
            }))
        }
        _ => bail!(
            "AZDQ_TEST_CLIENT_PRINCIPAL and AZDQ_TEST_CLIENT_PRINCIPAL_ID must be set together"
        ),
    }
}

fn sql_string(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_sql_uses_query_fallback_and_escapes_values() {
        let session = SessionResponse {
            role: Role::Reader,
            quack_uri: "quack:example.test:443".to_owned(),
            token: "tok'en".to_owned(),
            query_mode: "quack_query".to_owned(),
            catalog: "lake".to_owned(),
        };
        let sql = build_sql(&session, "abc", None, "SELECT 'hello'");
        assert!(
            sql.contains(
                "FROM quack_query('quack:example.test:443', 'USE lake;\nSELECT ''hello''')"
            )
        );
        assert!(sql.contains("TOKEN 'tok''en'"));
        assert!(sql.contains("'Authorization': 'Bearer abc'"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn duckdb_process_receives_generated_sql_on_stdin() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("duckdb-test");
        std::fs::write(
            &executable,
            "#!/bin/sh\ninput=$(cat)\ncase \"$input\" in *\"FROM quack_query\"*) exit 0 ;; *) exit 42 ;; esac\n",
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&executable, permissions).unwrap();
        let session = SessionResponse {
            role: Role::Reader,
            quack_uri: "quack:test:9494".to_owned(),
            token: "test-token-0123456789".to_owned(),
            query_mode: "quack_query".to_owned(),
            catalog: "lake".to_owned(),
        };

        run_duckdb(&executable, &session, "access-token", None, "SELECT 1")
            .await
            .unwrap();
    }
}
