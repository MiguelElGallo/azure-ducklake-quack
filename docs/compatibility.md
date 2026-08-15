# Quack compatibility contract

The v0.1.0 spike used DuckDB 1.5.5, Quack's matching extension, PostgreSQL 17,
and a Linux ARM64 container. The Rust runtime supervises the official DuckDB CLI,
which attaches DuckLake as `lake` using DuckDB-managed PostgreSQL and DuckLake
secrets.

Verified behavior:

- `quack_query(...)` with `USE lake` returns DuckLake data.
- DDL and DML work through `quack_query(...)` on the writer endpoint.
- A new client can reconnect and read committed data.
- Attaching DuckLake with `READ_ONLY` rejects writes at the reader endpoint.
- The Rust client process receives generated SQL over stdin and uses Quack's
  `DISABLE_SSL` attach option only inside the isolated HTTP integration network.
- The default role routes to the reader; an explicit writer role routes to the
  separately credentialed writer runtime through the same opaque gateway.

Known limitations:

- Normal client-side `ATTACH` followed by direct attached-table scans fails for
  DuckLake-backed catalogs. This is upstream
  [Quack issue #190](https://github.com/duckdb/duckdb-quack/issues/190). The
  release therefore makes `quack_query(...)` its explicit public contract.
- `autoinstall_known_extensions=false` causes Quack requests to return HTTP 500
  even when the required extensions were loaded before the setting changed.
  The pinned image preinstalls them; community and unsigned extensions remain
  disabled, but known signed core-extension auto-install cannot be disabled in
  this preview.

No custom Quack messages are implemented by this project.

Run the reproducible contract locally with:

```bash
./tests/spike/quack-postgres.sh
```

The script creates uniquely named Docker objects, validates bootstrap and exact
PostgreSQL logins, exercises the real `azdq` process, commits through the writer,
reconnects through the default reader, and requires a reader write to fail.
