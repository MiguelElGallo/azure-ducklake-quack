# Quack compatibility contract

The v0.2.0 server spike uses DuckDB 1.5.5, its matching extensions, PostgreSQL
17, and Linux containers. The authenticated client requires the official DuckDB
v1.5 preview build `v1.5.6-dev66` (`11d6c02c0a`) with Quack `c154811` because
Quack custom headers landed after the 1.5.5 release. The Rust runtime supervises
the stable official DuckDB CLI, which attaches DuckLake as `lake` using
DuckDB-managed PostgreSQL and DuckLake secrets.

Verified behavior:

- `quack_query(...)` with `USE lake` returns DuckLake data.
- DDL and DML work through `quack_query(...)` on the writer endpoint.
- A new client can reconnect and read committed data.
- Attaching DuckLake with `READ_ONLY` rejects writes at the reader endpoint.
- The Rust client process receives generated SQL over stdin and uses Quack's
  `DISABLE_SSL` attach option only inside the isolated HTTP integration network.
- The default role routes to the reader; an explicit writer role routes to the
  separately credentialed writer runtime through the same opaque gateway.
- Azure ADLS writes require the Debian CA bundle at the Azure SDK's expected
  `/etc/pki/tls/certs/ca-bundle.crt` path. The runtime image provides a symlink
  to Debian's maintained bundle and keeps TLS verification enabled.

Known limitations:

- Normal client-side `ATTACH` followed by direct attached-table scans fails for
  DuckLake-backed catalogs. This is upstream
  [Quack issue #190](https://github.com/duckdb/duckdb-quack/issues/190). The
  release therefore makes `quack_query(...)` its explicit public contract.
- `EXTRA_HTTP_HEADERS` was merged in upstream
  [Quack PR #204](https://github.com/duckdb/duckdb-quack/pull/204) after DuckDB
  1.5.5. The client image therefore pins the extracted official preview CLI
  binary by architecture and SHA-256, then also verifies the DuckDB source ID
  and Quack extension version. Upstream can reproducibly repackage the outer
  daily artifact without changing the executable, so an archive hash is not a
  stable binary identity. A future nightly with a changed executable still
  makes the image build fail closed until the reviewed binary pins are updated.
- `autoinstall_known_extensions=false` causes Quack requests to return HTTP 500
  even when the required extensions were loaded before the setting changed.
  The pinned image preinstalls them; community and unsigned extensions remain
  disabled, but known signed core-extension auto-install cannot be disabled in
  this preview.

No custom Quack messages are implemented by this project.

## Direct dbt 2 spike

The optional direct path pins dbt Core `2.0.0-beta.2`, `dbc 0.3.0`, DuckDB
ADBC `1.5.5`, and DuckDB extensions `1.5.5`. It uses the prerelease catalogs v2
DuckLake contract behind `flags.use_catalogs_v2`; dbt warns that this schema is
experimental and may change. This path is independent of the Quack client and
server compatibility contract above. See [dbt-spike.md](dbt-spike.md).

Run the reproducible contract locally with:

```bash
./tests/spike/quack-postgres.sh
```

The script creates uniquely named Docker objects, validates bootstrap and exact
PostgreSQL logins, exercises the real `azdq` process, commits through the writer,
reconnects through the default reader, and requires a reader write to fail.

For the Azure verification script, set `DUCKDB_PATH` to a client with custom
header support. The initial v0.1.0 release was validated with the official v1.5
preview build above; v0.2.0 retains the same reviewed binary identity, and the
script performs a feature probe before requesting Entra authentication.
