use anyhow::Result;
use azdq_gateway::{Settings, app};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .json()
        .init();
    let settings = Settings::from_env()?;
    let listener = TcpListener::bind(settings.listen_addr).await?;
    tracing::info!(address = %settings.listen_addr, "gateway listening");
    axum::serve(listener, app(settings)?).await?;
    Ok(())
}
