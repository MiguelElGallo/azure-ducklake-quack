with parquet_orders as (
    select *
    from read_parquet(
        '{{ env_var("DBT_PARQUET_SOURCE_PATH", "/tmp/azdq-dbt-spike/orders-source.parquet") }}'
    )
),

typed as (
    select
        order_id::bigint as order_id,
        customer_id::bigint as customer_id,
        order_date::date as order_date,
        lower(trim(status))::varchar as status,
        amount::decimal(12, 2) as amount,
        source_updated_at::timestamp as source_updated_at
    from parquet_orders
)

select *
from typed
