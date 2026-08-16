select
    count(*) as actual_row_count,
    count(distinct order_id) as actual_distinct_orders,
    round(sum(amount), 2) as actual_total_amount
from {{ ref('fct_orders') }}
having
    count(*) != 6
    or count(distinct order_id) != 6
    or round(sum(amount), 2) != 826.80
