select *
from {{ ref('direct_dbt_smoke') }}
where expected_row_count != 1
