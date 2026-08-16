#!/usr/bin/env bash
set -euo pipefail

project_dir=${DBT_PROJECT_DIR:-/opt/azdq/dbt-spike}
target=${DBT_TARGET:-writer}

if [[ "$target" == "writer" || "$target" == "postgres_local" ]]; then
  postgres_variables=(
    PGHOST
    PGDATABASE
    PGUSER
    PGPASSWORD
  )
  for variable_name in "${postgres_variables[@]}"; do
    if [[ -z "${!variable_name:-}" ]]; then
      echo "Required environment variable is unset: ${variable_name}" >&2
      exit 2
    fi
  done
fi

if [[ "$target" == "writer" ]]; then
  azure_variables=(
    AZURE_CLIENT_ID
    AZURE_STORAGE_ACCOUNT
    DUCKLAKE_DATA_PATH
  )
  for variable_name in "${azure_variables[@]}"; do
    if [[ -z "${!variable_name:-}" ]]; then
      echo "Required environment variable is unset: ${variable_name}" >&2
      exit 2
    fi
  done
fi

echo "Running direct dbt spike with target=${target}; Quack is not in this path."
dbt --version

echo "Phase 1/5: publishing the deterministic Parquet source."
dbt run-operation publish_orders_parquet \
  --project-dir "$project_dir" \
  --profiles-dir "$project_dir" \
  --target "$target"

echo "Phase 2/5: previewing the Parquet source through dbt."
dbt show \
  --project-dir "$project_dir" \
  --profiles-dir "$project_dir" \
  --target "$target" \
  --select stg_orders \
  --limit 6

echo "Phase 3/5: building the Parquet stage and incremental fact DAG."
dbt build \
  --project-dir "$project_dir" \
  --profiles-dir "$project_dir" \
  --target "$target" \
  --select direct_dbt_smoke stg_orders+

# This second build is deliberate. The first execution creates fct_orders;
# this fresh dbt process must take the incremental MERGE branch. On later job
# executions, both builds remain idempotent because order_id is the unique key.
echo "Phase 4/5: rerunning fct_orders through its incremental MERGE path."
dbt build \
  --project-dir "$project_dir" \
  --profiles-dir "$project_dir" \
  --target "$target" \
  --select fct_orders

echo "Phase 5/5: reading the committed incremental result in a fresh dbt process."
dbt show \
  --project-dir "$project_dir" \
  --profiles-dir "$project_dir" \
  --target "$target" \
  --inline "select count(*) as row_count, count(distinct order_id) as distinct_orders, min(order_date) as first_order_date, max(order_date) as last_order_date, round(sum(amount), 2) as total_amount from {{ ref('fct_orders') }}" \
  --limit 1

echo "Direct dbt spike completed successfully."
