use std::{env, net::SocketAddr, path::PathBuf, str::FromStr};

use anyhow::{Context, Result, bail};
use azdq_policy::Role;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StorageProvider {
    Azure {
        account_name: String,
        managed_identity_client_id: String,
    },
    Local,
}

#[derive(Clone, Debug)]
pub struct Settings {
    pub role: Role,
    pub postgres_host: String,
    pub postgres_port: u16,
    pub postgres_database: String,
    pub postgres_user: String,
    pub postgres_password: String,
    pub postgres_sslmode: String,
    pub metadata_schema: String,
    pub data_path: String,
    pub storage_provider: StorageProvider,
    pub quack_token: String,
    pub quack_port: u16,
    pub health_addr: SocketAddr,
    pub memory_limit: String,
    pub max_temp_directory_size: String,
    pub temp_directory: String,
    pub duckdb_path: PathBuf,
}

impl Settings {
    /// Read and validate runtime configuration from environment variables.
    ///
    /// `PostgreSQL` credentials are intentionally separate values. They are placed in
    /// `DuckDB`'s secret manager at startup and never embedded in a connection URI.
    ///
    /// # Errors
    ///
    /// Returns an error when a required variable is absent or invalid.
    pub fn from_env() -> Result<Self> {
        let role = Role::from_str(&required("AZDQ_ROLE")?).context("AZDQ_ROLE is invalid")?;
        let storage_provider = match optional("AZDQ_STORAGE_PROVIDER", "azure").as_str() {
            "azure" => StorageProvider::Azure {
                account_name: required("AZURE_STORAGE_ACCOUNT")?,
                managed_identity_client_id: required("AZURE_CLIENT_ID")?,
            },
            "local" => StorageProvider::Local,
            value => bail!("AZDQ_STORAGE_PROVIDER must be azure or local, got {value}"),
        };
        let settings = Self {
            role,
            postgres_host: required("POSTGRES_HOST")?,
            postgres_port: optional("POSTGRES_PORT", "5432")
                .parse()
                .context("POSTGRES_PORT is invalid")?,
            postgres_database: required("POSTGRES_DATABASE")?,
            postgres_user: required("POSTGRES_USER")?,
            postgres_password: required("POSTGRES_PASSWORD")?,
            postgres_sslmode: optional("POSTGRES_SSLMODE", "require"),
            metadata_schema: optional("DUCKLAKE_METADATA_SCHEMA", "public"),
            data_path: required("DUCKLAKE_DATA_PATH")?,
            storage_provider,
            quack_token: required("QUACK_TOKEN")?,
            quack_port: optional("QUACK_PORT", "9494")
                .parse()
                .context("QUACK_PORT is invalid")?,
            health_addr: optional("HEALTH_ADDR", "0.0.0.0:8080")
                .parse()
                .context("HEALTH_ADDR is invalid")?,
            memory_limit: optional("DUCKDB_MEMORY_LIMIT", "768MB"),
            max_temp_directory_size: optional("DUCKDB_MAX_TEMP_SIZE", "2GB"),
            temp_directory: optional("DUCKDB_TEMP_DIRECTORY", "/tmp/azdq"),
            duckdb_path: PathBuf::from(optional("DUCKDB_PATH", "/usr/local/bin/duckdb")),
        };
        settings.validate()?;
        Ok(settings)
    }

    fn validate(&self) -> Result<()> {
        if self.quack_token.len() < 16 {
            bail!("QUACK_TOKEN must contain at least 16 characters");
        }
        for (name, value) in [
            ("POSTGRES_DATABASE", &self.postgres_database),
            ("POSTGRES_USER", &self.postgres_user),
            ("DUCKLAKE_METADATA_SCHEMA", &self.metadata_schema),
        ] {
            if value.is_empty()
                || !value
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || character == '_')
            {
                bail!("{name} may contain only ASCII letters, digits, and underscores");
            }
        }
        if !matches!(self.postgres_sslmode.as_str(), "require" | "disable") {
            bail!("POSTGRES_SSLMODE must be require or disable");
        }
        for (name, value) in [
            ("POSTGRES_HOST", &self.postgres_host),
            ("DUCKLAKE_DATA_PATH", &self.data_path),
        ] {
            if value.contains(['\n', '\r']) {
                bail!("{name} contains an invalid newline");
            }
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
