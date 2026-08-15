use std::{env, net::SocketAddr};

use anyhow::{Context, Result, bail};

#[derive(Clone, Debug)]
pub struct Settings {
    pub listen_addr: SocketAddr,
    pub public_quack_uri: String,
    pub reader_backend_url: String,
    pub writer_backend_url: String,
    pub reader_group_id: String,
    pub writer_group_id: String,
    pub reader_quack_token: String,
    pub writer_quack_token: String,
}

impl Settings {
    /// Read and validate gateway configuration from environment variables.
    ///
    /// # Errors
    ///
    /// Returns an error when a required variable is absent or invalid.
    pub fn from_env() -> Result<Self> {
        let settings = Self {
            listen_addr: optional("LISTEN_ADDR", "0.0.0.0:8080")
                .parse()
                .context("LISTEN_ADDR is invalid")?,
            public_quack_uri: required("PUBLIC_QUACK_URI")?,
            reader_backend_url: required("READER_BACKEND_URL")?,
            writer_backend_url: required("WRITER_BACKEND_URL")?,
            reader_group_id: required("ENTRA_READER_GROUP_ID")?,
            writer_group_id: required("ENTRA_WRITER_GROUP_ID")?,
            reader_quack_token: required("READER_QUACK_TOKEN")?,
            writer_quack_token: required("WRITER_QUACK_TOKEN")?,
        };
        settings.validate()?;
        Ok(settings)
    }

    fn validate(&self) -> Result<()> {
        for (name, value) in [
            ("READER_BACKEND_URL", &self.reader_backend_url),
            ("WRITER_BACKEND_URL", &self.writer_backend_url),
        ] {
            if !(value.starts_with("http://") || value.starts_with("https://")) {
                bail!("{name} must use http:// or https://");
            }
        }
        if self.reader_quack_token.len() < 16 || self.writer_quack_token.len() < 16 {
            bail!("Quack backend tokens must contain at least 16 characters");
        }
        Ok(())
    }
}

fn required(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("required environment variable {name} is missing"))
}

fn optional(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_owned())
}
