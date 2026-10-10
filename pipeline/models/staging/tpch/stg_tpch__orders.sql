with source as (
    select * from {{ source('tpch', 'orders') }}
)

select
    o_orderkey as order_key,
    o_custkey as customer_key,
    case o_orderstatus
        when 'O' then 'open'
        when 'F' then 'fulfilled'
        when 'P' then 'partial'
    end as order_status,
    o_totalprice::number(18, 2) as total_price,
    o_orderdate as order_date,
    o_orderpriority as order_priority
from source
