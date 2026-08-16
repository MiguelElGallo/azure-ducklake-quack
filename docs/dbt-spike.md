# Direct dbt Core 2 DuckLake spike

This opt-in spike runs dbt Core 2 inside an Azure Container Apps Job and writes
to the existing DuckLake directly through DuckDB's ADBC driver. It does not
call the public gateway, a Quack runtime, Flight SQL, or another database
service between dbt and DuckDB.

```text
Container Apps Job
  -> dbt Core 2.0.0-alpha.5
  -> DuckDB ADBC 1.5.5 (in process)
  -> ADLS Parquet source: data/sources/dbt-spike/orders.parquet
  -> stg_orders (table)
  -> fct_orders (incremental MERGE by order_id)
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

## Parquet and incremental pipeline

The job has one source format: Parquet. A dbt operation creates a deterministic
six-row order fixture directly as
`az://<account>.blob.core.windows.net/ducklake/data/sources/dbt-spike/orders.parquet`.
There is no CSV input or CSV-to-Parquet build step. Keeping the source under a
dedicated prefix of the existing `ducklake` container avoids a new container or
broader role assignment; the writer identity already has contributor access at
that container scope.

The dbt DAG performs these transformations:

1. `publish_orders_parquet` writes the source Parquet object.
2. `stg_orders` reads that object with `read_parquet`, normalizes types and
   status values, and materializes a DuckLake staging table.
3. `fct_orders` incrementally merges rows by the non-null `order_id` key and
   filters subsequent work using the `source_updated_at` watermark.
4. Data and singular tests verify keys, accepted statuses, six rows, six
   distinct orders, and the expected total amount of `826.80`.
5. A fresh `dbt show` process reads the committed fact table and prints its
   aggregate metrics in the job log.

The entrypoint deliberately executes `fct_orders` twice. The first build creates
the table when needed, and the second build exercises DuckDB's native incremental
`MERGE` path. Repeated job executions remain idempotent because `order_id` is the
unique key.

The model leaves `on_schema_change` at the adapter default. In dbt Core 2 alpha
5, strict schema comparison misclassifies equivalent DuckLake types such as
`BIGINT`/`INTEGER`, `DECIMAL`/`FLOAT8`, and `TIMESTAMP`/`DATETIME` as changes.
The model tests enforce the current schema and data contract; an intentional
schema change should use a reviewed full refresh while this alpha behavior
remains.

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
the image. It publishes a local Parquet source, previews all six source rows,
builds three models with 19 tests, reruns the incremental model with nine tests,
and reads the final six-row fact table in a fresh dbt process.

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
relations include `lake.dbt_spike.stg_orders` and
`lake.dbt_spike.fct_orders` in addition to the original smoke relation.

## Reading the proof

The job output must include all of the following:

- `dbt-core 2.0.0-alpha.5`
- a Parquet publication message targeting the ADLS source prefix
- six source rows in the `stg_orders` preview
- three successful models and 19 passing tests in the full DAG build
- a second successful incremental `fct_orders` build and nine passing tests
- a final result with six rows, six distinct orders, and total amount `826.8`
- `Direct dbt spike completed successfully.`

An execution that reaches Quack is outside this topology: neither the job
definition nor its dbt project contains a Quack URL, token, gateway hostname,
or runtime command.

## Live Azure validation

The expanded pipeline was deployed and executed in Sweden Central on
2026-08-16. Azure Container Apps Job `caj-azdq-dbt-spike` execution
`caj-azdq-dbt-spike-vvy35gx` ran dbt Core `2.0.0-alpha.5` as a non-root user
against the existing PostgreSQL-backed DuckLake and ADLS Gen2 data path.

The live execution produced this proof:

- the job published six rows to
  `data/sources/dbt-spike/orders.parquet` and previewed all six from ADLS;
- the full build completed three models and 19 tests with 22/22 successes;
- the second build completed the incremental `fct_orders` MERGE and nine tests
  with 10/10 successes;
- a fresh `dbt show` returned six rows, six distinct orders, dates from
  `2026-08-10` through `2026-08-15`, and total amount `826.8`; and
- the execution completed without a Quack URL, token, secret reference,
  command, or runtime in the job configuration.

The deployed image was pinned to digest
`sha256:965b62b482149b98042e145dd81cf73db5b26e131c66b5ea2b154461a92ebd61`.
The only dbt warning was the expected notice that catalogs v2 remains
experimental in this alpha release.
