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
dbt run \
  --project-dir "$project_dir" \
  --profiles-dir "$project_dir" \
  --target "$target" \
  --select direct_dbt_smoke

# A second dbt process reconnects, reattaches DuckLake, and reads the committed
# table through the same direct ADBC path.
dbt test \
  --project-dir "$project_dir" \
  --profiles-dir "$project_dir" \
  --target "$target" \
  --select direct_dbt_smoke

echo "Direct dbt spike completed successfully."
