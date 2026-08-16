{% macro publish_orders_parquet() %}
    {% set source_path = env_var(
        'DBT_PARQUET_SOURCE_PATH',
        '/tmp/azdq-dbt-spike/orders-source.parquet'
    ) %}

    {% set publish_sql %}
        copy (
            select *
            from (
                values
                    (1001, 201, date '2026-08-10', 'completed', decimal '129.90', timestamp '2026-08-10 08:15:00'),
                    (1002, 202, date '2026-08-11', 'shipped', decimal '45.50', timestamp '2026-08-11 12:30:00'),
                    (1003, 201, date '2026-08-12', 'returned', decimal '18.75', timestamp '2026-08-12 16:45:00'),
                    (1004, 203, date '2026-08-13', 'completed', decimal '250.00', timestamp '2026-08-13 09:05:00'),
                    (1005, 204, date '2026-08-14', 'placed', decimal '72.25', timestamp '2026-08-14 18:20:00'),
                    (1006, 205, date '2026-08-15', 'completed', decimal '310.40', timestamp '2026-08-15 21:10:00')
            ) as fixture(
                order_id,
                customer_id,
                order_date,
                status,
                amount,
                source_updated_at
            )
        ) to '{{ source_path }}' (
            format parquet,
            compression zstd
        )
    {% endset %}

    {% do log('Publishing six source rows as Parquet to ' ~ source_path, info=true) %}
    {% do run_query(publish_sql) %}
{% endmacro %}
