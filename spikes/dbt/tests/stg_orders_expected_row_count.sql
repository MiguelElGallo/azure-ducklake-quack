select count(*) as actual_row_count
from {{ ref('stg_orders') }}
having count(*) != 6
