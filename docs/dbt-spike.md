# Direct dbt Core 2 DuckLake spike

This opt-in spike runs dbt Core 2 inside an Azure Container Apps Job and writes
to the existing DuckLake directly through DuckDB's ADBC driver. It does not
call the public gateway, a Quack runtime, Flight SQL, or another database
service between dbt and DuckDB.

```text
Container Apps Job
  -> dbt Core 2.0.0-alpha.5
  -> DuckDB ADBC 1.5.5 (in process)
  -> DuckLake 1.5.5
     -> PostgreSQL metadata
     -> ADLS Gen2 Parquet
```

## What is pinned

The image pins dbt Core `2.0.0a5`, `dbc 0.3.0`, DuckDB ADBC `1.5.5`, and
DuckDB extensions `1.5.5`. The dbt and `dbc` wheels are downloaded by exact
URL and verified with SHA-256. `dbc` installs and verifies the DuckDB driver
during the image build. The `azure`, `ducklake`, and `postgres` extensions are
also installed during the image build, so the job needs no dependency download
at execution time.

This remains an experimental contract. dbt Core 2 alpha 5 emits a warning that
the catalogs v2 schema is not officially supported and may change. The project
therefore enables `flags.use_catalogs_v2` explicitly and keeps every version
pin visible in `docker/dbt-spike.Dockerfile`.

## Connection contract

`spikes/dbt/catalogs.yml` uses the alpha catalogs v2 DuckLake configuration:

```yaml
catalogs:
  - name: lake
    type: ducklake
    table_format: default
    config:
      duckdb:
        metadata_path: "postgres:"
        data_path: "az://.../ducklake/data/"
        metadata_schema: public
```

The actual values are rendered from environment variables. `postgres:` tells
DuckLake to use PostgreSQL metadata; DuckDB's PostgreSQL extension reads the
standard `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, and
`PGSSLMODE` variables. The password enters the job through the existing
Key Vault secret reference and is never put into `profiles.yml`, `catalogs.yml`,
the image, or a command line.

ADLS authentication uses an in-memory DuckDB secret with the Azure
`managed_identity` provider. The job reuses the writer user-assigned identity,
which already has container-scoped Blob Data Contributor, secret-scoped Key
Vault Secrets User, and ACR pull permissions.

## Local offline validation

Build and run the image against a temporary local DuckLake:

```bash
docker build --tag azdq-dbt-spike:local --file docker/dbt-spike.Dockerfile .
docker run --rm --network none \
  --env DBT_TARGET=local \
  --env DBT_SPIKE_RUN_ID=local \
  --env DUCKLAKE_METADATA_PATH=/tmp/azdq-dbt-spike/metadata.ducklake \
  --env DUCKLAKE_DATA_PATH=/tmp/azdq-dbt-spike/data/ \
  azdq-dbt-spike:local
```

The network-disabled run proves the ADBC driver and extensions were baked into
the image. It runs `dbt run`, exits that dbt process, then runs `dbt test` in a
new process. The second process must reattach DuckLake and read the committed
table. Four tests cover the row marker, expected connection-path marker, run ID,
and timestamp.

## Azure execution

Prerequisites:

- The existing project foundation, bootstrap job, PostgreSQL roles, DuckLake
  catalog, and writer identity have already been deployed successfully.
- The AZD environment contains the same secure values used by the main
  deployment.
- The worktree is clean, and the checked-out commit is the intended spike.

When deployment is explicitly authorized, run:

```bash
./scripts/deploy-dbt-spike.sh
```

The helper checks the existing resource group, ACR, Container Apps environment,
and available Consumption cores. It builds the image in ACR, resolves the tag
to a digest, previews and deploys the standalone job Bicep module, starts one
manual execution, and waits up to 15 minutes for a terminal result. The scoped
deployment cannot reconcile the existing apps, bootstrap job, PostgreSQL
server, ACR, or Container Apps environment.

The Bicep flag defaults to false:

```text
AZDQ_DEPLOY_DBT_SPIKE=false
```

The job has no ingress, runs one non-root replica with 0.5 vCPU and 1 GiB of
memory, retries zero times, and times out after 15 minutes. Its successful
model is `lake.dbt_spike.direct_dbt_smoke`.

## Reading the proof

The job output must include all of the following:

- `dbt-core 2.0.0-alpha.5`
- one successful `direct_dbt_smoke` model
- four successful tests from a fresh dbt process
- `Direct dbt spike completed successfully.`

An execution that reaches Quack is outside this topology: neither the job
definition nor its dbt project contains a Quack URL, token, gateway hostname,
or runtime command.
