select
    '{{ env_var("DBT_SPIKE_RUN_ID", "manual") }}' as run_id,
    current_timestamp as built_at,
    'dbt-core-2-duckdb-adbc-ducklake' as connection_path,
    1 as expected_row_count
