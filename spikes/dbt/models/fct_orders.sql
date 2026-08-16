{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='order_id'
    )
}}

with staged_orders as (
    select
        order_id,
        customer_id,
        order_date,
        status,
        amount,
        source_updated_at
    from {{ ref('stg_orders') }}

    {% if is_incremental() %}
    where source_updated_at >= (
        select coalesce(max(source_updated_at), timestamp '1900-01-01')
        from {{ this }}
    )
    {% endif %}
),

final as (
    select
        order_id,
        customer_id,
        order_date,
        status,
        amount,
        source_updated_at,
        current_timestamp as dbt_loaded_at
    from staged_orders
)

select *
from final
