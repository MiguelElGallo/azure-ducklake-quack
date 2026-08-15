mod config;

use std::{
    fmt::Write as _,
    fs,
    io::Write as _,
    net::{Ipv4Addr, SocketAddrV4, TcpStream},
    process::{Child, ChildStdin, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use azdq_policy::Role;
use duckdb::{Config, Connection};

pub use config::{Settings, StorageProvider};

/// Supervised official `DuckDB` process serving Quack.
///
/// Quack is a C++ extension. Running it in the official CLI keeps the extension and
/// host engine on the exact same build while Rust owns configuration and lifecycle.
pub struct RuntimeProcess {
    child: Child,
    // Keeping stdin open keeps the non-interactive DuckDB shell alive after startup.
    _stdin: ChildStdin,
}

impl RuntimeProcess {
    /// Return whether the supervised `DuckDB` process is still running.
    ///
    /// # Errors
    ///
    /// Returns an error if the operating system cannot inspect the process.
    pub fn is_running(&mut self) -> Result<bool> {
        Ok(self.child.try_wait()?.is_none())
    }
}

impl Drop for RuntimeProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Start the official `DuckDB` CLI, attach the role-scoped `DuckLake`, and serve Quack.
///
/// # Errors
///
/// Returns an error when the catalog, extensions, security configuration, or listener
/// cannot be initialized.
pub fn start(settings: &Settings) -> Result<RuntimeProcess> {
    initialize_and_validate_catalog(settings)?;

    let mut command = Command::new(&settings.duckdb_path);
    command.args(["-no-init", "-batch", "-bail"]);
    command
        .stdin(Stdio::piped())
        // Quack's startup result includes its token. Never emit CLI output to logs.
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        // The child receives temporary in-memory secrets over stdin. Do not also
        // leave the source credentials in its process environment.
        .env_remove("POSTGRES_PASSWORD")
        .env_remove("QUACK_TOKEN");
    let mut child = command.spawn().with_context(|| {
        format!(
            "failed to start the official DuckDB executable {}",
            settings.duckdb_path.display()
        )
    })?;
    let mut stdin = child.stdin.take().context("DuckDB stdin is unavailable")?;
    stdin
        .write_all(server_startup_sql(settings).as_bytes())
        .context("failed to configure the DuckDB Quack process")?;
    stdin.flush()?;

    wait_for_quack(&mut child, settings.quack_port)?;
    Ok(RuntimeProcess {
        child,
        _stdin: stdin,
    })
}

fn initialize_and_validate_catalog(settings: &Settings) -> Result<()> {
    fs::create_dir_all(&settings.temp_directory)
        .context("failed to create DuckDB temp directory")?;
    let connection = Connection::open_in_memory_with_flags(database_config(settings)?)?;
    let attach_options = if settings.role == Role::Reader {
        " (READ_ONLY)"
    } else {
        ""
    };
    let statements = format!(
        "{}\nATTACH 'ducklake:azdq_catalog' AS validation{};",
        temporary_secret_sql(settings)?,
        attach_options,
    );
    connection
        .execute_batch(&statements)
        // Do not attach DuckDB's source error: it can echo secret-bearing SQL.
        .map_err(|_| anyhow::anyhow!("failed to open the PostgreSQL-backed DuckLake catalog"))?;

    // Propagate lookup errors and require an exact property match. A missing or
    // unreadable property must never silently turn into an authorization decision.
    let read_only: bool = connection
        .query_row(
            "SELECT readonly FROM duckdb_databases() WHERE database_name = 'validation'",
            [],
            |row| row.get(0),
        )
        .context("failed to verify the validation catalog access mode")?;
    if (settings.role == Role::Reader) != read_only {
        bail!("catalog access mode does not match the configured role");
    }

    Ok(())
}

fn server_startup_sql(settings: &Settings) -> String {
    let attach_options = if settings.role == Role::Reader {
        " (READ_ONLY)"
    } else {
        ""
    };
    format!(
        "{}\n\
         LOAD quack;\n\
         SET memory_limit = {};\n\
         SET threads = 1;\n\
         SET temp_directory = {};\n\
         SET max_temp_directory_size = {};\n\
         -- Quack request workers must autoload the preinstalled DuckLake/PostgreSQL\n\
         -- extensions. Setting autoinstall_known_extensions=false currently makes\n\
         -- quack_query return HTTP 500; community and unsigned code stay disabled.\n\
         SET allow_community_extensions = false;\n\
         SET allow_unsigned_extensions = false;\n\
         ATTACH 'ducklake:azdq_catalog' AS lake{};\n\
         CALL quack_serve('quack:0.0.0.0:{}', token => {}, allow_other_hostname => true);\n",
        // Configuration has already been validated; rendering only fails on the
        // in-memory formatter, which cannot fail for String. Keep this function
        // infallible so startup SQL remains straightforward to unit test.
        temporary_secret_sql(settings).expect("formatting temporary secrets cannot fail"),
        sql_string(&settings.memory_limit),
        sql_string(&settings.temp_directory),
        sql_string(&settings.max_temp_directory_size),
        attach_options,
        settings.quack_port,
        sql_string(&settings.quack_token),
    )
}

fn wait_for_quack(child: &mut Child, port: u16) -> Result<()> {
    let address = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if TcpStream::connect_timeout(&address.into(), Duration::from_millis(100)).is_ok() {
            return Ok(());
        }
        if child.try_wait()?.is_some() {
            bail!("DuckDB exited before the Quack listener became ready");
        }
        thread::sleep(Duration::from_millis(100));
    }
    bail!("Quack listener did not become ready within 30 seconds")
}

fn database_config(settings: &Settings) -> Result<Config> {
    Config::default()
        .with("memory_limit", &settings.memory_limit)?
        .with("threads", "1")?
        .with("temp_directory", &settings.temp_directory)?
        .with("max_temp_directory_size", &settings.max_temp_directory_size)?
        .with("allow_community_extensions", "false")?
        .with("allow_unsigned_extensions", "false")?
        .with("autoinstall_known_extensions", "false")
        .map_err(Into::into)
}

fn temporary_secret_sql(settings: &Settings) -> Result<String> {
    let mut statements = format!(
        "LOAD postgres; LOAD ducklake;\n\
         CREATE OR REPLACE TEMPORARY SECRET azdq_postgres (\n\
           TYPE POSTGRES, HOST {}, PORT {}, DATABASE {}, USER {}, PASSWORD {}, SSLMODE {}\n\
         );\n",
        sql_string(&settings.postgres_host),
        settings.postgres_port,
        sql_string(&settings.postgres_database),
        sql_string(&settings.postgres_user),
        sql_string(&settings.postgres_password),
        sql_string(&settings.postgres_sslmode),
    );
    if let StorageProvider::Azure {
        account_name,
        managed_identity_client_id,
    } = &settings.storage_provider
    {
        write!(
            statements,
            "LOAD azure;\n\
             CREATE OR REPLACE TEMPORARY SECRET azdq_storage (\n\
               TYPE AZURE, PROVIDER MANAGED_IDENTITY, ACCOUNT_NAME {}, CLIENT_ID {}\n\
             );\n",
            sql_string(account_name),
            sql_string(managed_identity_client_id),
        )?;
    }
    write!(
        statements,
        "CREATE OR REPLACE TEMPORARY SECRET azdq_catalog (\n\
           TYPE DUCKLAKE, METADATA_PATH '', DATA_PATH {}, METADATA_SCHEMA {},\n\
           METADATA_PARAMETERS MAP {{'TYPE': 'postgres', 'SECRET': 'azdq_postgres'}}\n\
         );",
        sql_string(&settings.data_path),
        sql_string(&settings.metadata_schema),
    )?;
    Ok(statements)
}

#[must_use]
pub fn sql_string(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        net::{IpAddr, Ipv4Addr, SocketAddr},
        path::PathBuf,
    };

    #[test]
    fn sql_string_doubles_quotes() {
        assert_eq!(sql_string("O'Brien"), "'O''Brien'");
    }

    fn settings(role: Role) -> Settings {
        Settings {
            role,
            postgres_host: "postgres".to_owned(),
            postgres_port: 5432,
            postgres_database: "catalog".to_owned(),
            postgres_user: "runtime".to_owned(),
            postgres_password: "not-rendered".to_owned(),
            postgres_sslmode: "require".to_owned(),
            metadata_schema: "public".to_owned(),
            data_path: "az://ducklake/".to_owned(),
            storage_provider: StorageProvider::Local,
            quack_token: "token-value-0123456789".to_owned(),
            quack_port: 9494,
            health_addr: SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 8080),
            memory_limit: "768MB".to_owned(),
            max_temp_directory_size: "2GB".to_owned(),
            temp_directory: "/tmp/azdq".to_owned(),
            duckdb_path: PathBuf::from("/usr/local/bin/duckdb"),
        }
    }

    #[test]
    fn reader_startup_is_read_only_and_keeps_extension_guards() {
        let sql = server_startup_sql(&settings(Role::Reader));
        assert!(sql.contains("AS lake (READ_ONLY)"));
        assert!(sql.contains("SET allow_community_extensions = false"));
        assert!(sql.contains("SET allow_unsigned_extensions = false"));
        assert!(!sql.contains("SET autoinstall_known_extensions"));
        assert!(sql.contains("CREATE OR REPLACE TEMPORARY SECRET"));
        assert!(!sql.contains("PERSISTENT SECRET"));
    }

    #[test]
    fn writer_startup_is_not_read_only() {
        let sql = server_startup_sql(&settings(Role::Writer));
        assert!(sql.contains("AS lake;"));
        assert!(!sql.contains("READ_ONLY"));
    }
}
