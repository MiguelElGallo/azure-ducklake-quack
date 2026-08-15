use std::{env, fmt::Write as _, time::Duration};

use anyhow::{Context, Result, bail};
use duckdb::{Config as DuckDbConfig, Connection};
use native_tls::TlsConnector;
use postgres_native_tls::MakeTlsConnector;
use tokio_postgres::{Client, Config as PostgresConfig, NoTls, config::SslMode};

use azdq_runtime::sql_string;

struct BootstrapSettings {
    host: String,
    port: u16,
    database: String,
    admin_user: String,
    admin_password: String,
    sslmode: String,
    metadata_schema: String,
    data_path: String,
    storage_account: Option<String>,
    managed_identity_client_id: Option<String>,
    reader_user: String,
    reader_password: String,
    writer_user: String,
    writer_password: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let settings = BootstrapSettings::from_env()?;
    let admin = connect_postgres(&settings, &settings.admin_user, &settings.admin_password).await?;

    create_or_rotate_login(&admin, &settings.reader_user, &settings.reader_password).await?;
    create_or_rotate_login(&admin, &settings.writer_user, &settings.writer_password).await?;
    configure_database_boundary(&admin, &settings).await?;

    initialize_ducklake(&settings)?;
    grant_metadata_permissions(&admin, &settings).await?;
    configure_writer_default_privileges(&settings).await?;
    validate_login(
        &settings,
        &settings.reader_user,
        &settings.reader_password,
        false,
    )
    .await?;
    validate_login(
        &settings,
        &settings.writer_user,
        &settings.writer_password,
        true,
    )
    .await?;
    Ok(())
}

impl BootstrapSettings {
    fn from_env() -> Result<Self> {
        let storage_provider = optional("AZDQ_STORAGE_PROVIDER", "azure");
        if !matches!(storage_provider.as_str(), "azure" | "local") {
            bail!("AZDQ_STORAGE_PROVIDER must be azure or local");
        }
        let settings = Self {
            host: required("POSTGRES_HOST")?,
            port: optional("POSTGRES_PORT", "5432")
                .parse()
                .context("POSTGRES_PORT is invalid")?,
            database: required("POSTGRES_DATABASE")?,
            admin_user: required("POSTGRES_ADMIN_USER")?,
            admin_password: required("POSTGRES_ADMIN_PASSWORD")?,
            sslmode: optional("POSTGRES_SSLMODE", "require"),
            metadata_schema: optional("DUCKLAKE_METADATA_SCHEMA", "public"),
            data_path: required("DUCKLAKE_DATA_PATH")?,
            storage_account: (storage_provider == "azure")
                .then(|| required("AZURE_STORAGE_ACCOUNT"))
                .transpose()?,
            managed_identity_client_id: (storage_provider == "azure")
                .then(|| required("AZURE_CLIENT_ID"))
                .transpose()?,
            reader_user: required("POSTGRES_READER_USER")?,
            reader_password: required("POSTGRES_READER_PASSWORD")?,
            writer_user: required("POSTGRES_WRITER_USER")?,
            writer_password: required("POSTGRES_WRITER_PASSWORD")?,
        };
        for value in [
            &settings.database,
            &settings.admin_user,
            &settings.reader_user,
            &settings.writer_user,
            &settings.metadata_schema,
        ] {
            validate_identifier(value)?;
        }
        if !matches!(settings.sslmode.as_str(), "require" | "disable") {
            bail!("POSTGRES_SSLMODE must be require or disable");
        }
        Ok(settings)
    }
}

fn initialize_ducklake(settings: &BootstrapSettings) -> Result<()> {
    let secret_directory = tempfile::Builder::new()
        .prefix("bootstrap-secrets-")
        .tempdir()
        .context("failed to create bootstrap secret directory")?;
    let config = DuckDbConfig::default().with(
        "secret_directory",
        secret_directory.path().to_string_lossy(),
    )?;
    let connection = Connection::open_in_memory_with_flags(config)?;
    let mut sql = format!(
        "LOAD postgres; LOAD ducklake;\n\
         CREATE SECRET azdq_postgres (\n\
           TYPE POSTGRES, HOST {}, PORT {}, DATABASE {}, USER {}, PASSWORD {}, SSLMODE {}\n\
         );\n",
        sql_string(&settings.host),
        settings.port,
        sql_string(&settings.database),
        sql_string(&settings.admin_user),
        sql_string(&settings.admin_password),
        sql_string(&settings.sslmode),
    );
    if let (Some(account), Some(client_id)) = (
        &settings.storage_account,
        &settings.managed_identity_client_id,
    ) {
        write!(
            sql,
            "LOAD azure;\n\
             CREATE SECRET azdq_storage (\n\
               TYPE AZURE, PROVIDER MANAGED_IDENTITY, ACCOUNT_NAME {}, CLIENT_ID {}\n\
             );\n",
            sql_string(account),
            sql_string(client_id),
        )?;
    }
    write!(
        sql,
        "CREATE SECRET azdq_catalog (\n\
           TYPE DUCKLAKE, METADATA_PATH '', DATA_PATH {}, METADATA_SCHEMA {},\n\
           METADATA_PARAMETERS MAP {{'TYPE': 'postgres', 'SECRET': 'azdq_postgres'}}\n\
         );\n\
         ATTACH 'ducklake:azdq_catalog' AS lake;\n\
         USE lake;\n\
         CREATE SCHEMA IF NOT EXISTS analytics;",
        sql_string(&settings.data_path),
        sql_string(&settings.metadata_schema),
    )?;
    connection
        .execute_batch(&sql)
        // DuckDB errors can echo CREATE SECRET input, so intentionally discard the source.
        .map_err(|_| anyhow::anyhow!("failed to initialize the DuckLake catalog"))?;
    Ok(())
}

async fn configure_database_boundary(client: &Client, settings: &BootstrapSettings) -> Result<()> {
    client
        .batch_execute(&format!(
            "REVOKE CONNECT ON DATABASE {database} FROM PUBLIC;\n\
             GRANT CONNECT ON DATABASE {database} TO {reader};\n\
             GRANT CONNECT ON DATABASE {database} TO {writer};\n\
             REVOKE CREATE ON SCHEMA {schema} FROM PUBLIC;\n\
             GRANT USAGE ON SCHEMA {schema} TO {reader};\n\
             GRANT USAGE, CREATE ON SCHEMA {schema} TO {writer};",
            database = pg_identifier(&settings.database),
            schema = pg_identifier(&settings.metadata_schema),
            reader = pg_identifier(&settings.reader_user),
            writer = pg_identifier(&settings.writer_user),
        ))
        .await
        .context("failed to configure PostgreSQL database boundaries")
}

async fn configure_writer_default_privileges(settings: &BootstrapSettings) -> Result<()> {
    let writer =
        connect_postgres(settings, &settings.writer_user, &settings.writer_password).await?;
    writer
        .batch_execute(&format!(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA {schema}\n\
               GRANT SELECT ON TABLES TO {reader};",
            schema = pg_identifier(&settings.metadata_schema),
            reader = pg_identifier(&settings.reader_user),
        ))
        .await
        .context("failed to configure writer-owned DuckLake metadata privileges")
}

async fn grant_metadata_permissions(client: &Client, settings: &BootstrapSettings) -> Result<()> {
    client
        .batch_execute(&format!(
            "GRANT SELECT ON ALL TABLES IN SCHEMA {schema} TO {reader};\n\
             GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {schema} TO {writer};\n\
             ALTER DEFAULT PRIVILEGES FOR USER {admin} IN SCHEMA {schema}\n\
               GRANT SELECT ON TABLES TO {reader};\n\
             ALTER DEFAULT PRIVILEGES FOR USER {admin} IN SCHEMA {schema}\n\
               GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {writer};",
            schema = pg_identifier(&settings.metadata_schema),
            admin = pg_identifier(&settings.admin_user),
            reader = pg_identifier(&settings.reader_user),
            writer = pg_identifier(&settings.writer_user),
        ))
        .await
        .context("failed to grant DuckLake metadata permissions")
}

async fn validate_login(
    settings: &BootstrapSettings,
    user: &str,
    password: &str,
    writer: bool,
) -> Result<()> {
    let client = connect_postgres(settings, user, password).await?;
    let row = client
        .query_one(
            "SELECT current_user = $1,\n\
                    has_schema_privilege(current_user, $2, 'USAGE'),\n\
                    has_schema_privilege(current_user, $2, 'CREATE'),\n\
                    COALESCE(bool_and(has_table_privilege(current_user,\n\
                      quote_ident(schemaname) || '.' || quote_ident(tablename), 'SELECT')), false),\n\
                    COALESCE(bool_and(has_table_privilege(current_user,\n\
                      quote_ident(schemaname) || '.' || quote_ident(tablename), 'INSERT,UPDATE,DELETE')), false),\n\
                    count(*) > 0\n\
             FROM pg_tables WHERE schemaname = $2",
            &[&user, &settings.metadata_schema],
        )
        .await
        .context("failed to validate scoped PostgreSQL login")?;
    let identity_ok: bool = row.get(0);
    let schema_usage: bool = row.get(1);
    let schema_create: bool = row.get(2);
    let select_all: bool = row.get(3);
    let writes_all: bool = row.get(4);
    let tables_exist: bool = row.get(5);
    if !identity_ok
        || !schema_usage
        || !select_all
        || !tables_exist
        || (writer != schema_create)
        || (writer != writes_all)
    {
        bail!("PostgreSQL role validation failed for {user}");
    }
    Ok(())
}

async fn connect_postgres(
    settings: &BootstrapSettings,
    user: &str,
    password: &str,
) -> Result<Client> {
    let mut config = PostgresConfig::new();
    config
        .host(&settings.host)
        .port(settings.port)
        .dbname(&settings.database)
        .user(user)
        .password(password)
        .connect_timeout(Duration::from_secs(15))
        .application_name("azure-ducklake-quack-bootstrap");
    if settings.sslmode == "disable" {
        config.ssl_mode(SslMode::Disable);
        let (client, connection) = config
            .connect(NoTls)
            .await
            .map_err(|_| anyhow::anyhow!("failed to connect to PostgreSQL"))?;
        tokio::spawn(async move {
            if connection.await.is_err() {
                tracing::error!("PostgreSQL connection dropped");
            }
        });
        Ok(client)
    } else {
        config.ssl_mode(SslMode::Require);
        let connector = TlsConnector::builder().build()?;
        let (client, connection) = config
            .connect(MakeTlsConnector::new(connector))
            .await
            .map_err(|_| anyhow::anyhow!("failed to connect to PostgreSQL with TLS"))?;
        tokio::spawn(async move {
            if connection.await.is_err() {
                tracing::error!("PostgreSQL TLS connection dropped");
            }
        });
        Ok(client)
    }
}

async fn create_or_rotate_login(client: &Client, user: &str, password: &str) -> Result<()> {
    let exists = client
        .query_opt("SELECT 1 FROM pg_roles WHERE rolname = $1", &[&user])
        .await?
        .is_some();
    let statement = if exists {
        format!(
            "ALTER ROLE {} LOGIN PASSWORD {}",
            pg_identifier(user),
            pg_literal(password)
        )
    } else {
        format!(
            "CREATE ROLE {} LOGIN PASSWORD {}",
            pg_identifier(user),
            pg_literal(password)
        )
    };
    client
        .batch_execute(&statement)
        .await
        // The source can include the password-bearing statement.
        .map_err(|_| anyhow::anyhow!("failed to create or rotate PostgreSQL login"))?;
    Ok(())
}

fn validate_identifier(value: &str) -> Result<()> {
    if value.is_empty()
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
    {
        bail!("PostgreSQL identifiers may contain only ASCII letters, digits, and underscores");
    }
    Ok(())
}

fn pg_identifier(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn pg_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn required(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("required environment variable {name} is missing"))
}

fn optional(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_owned())
}
