with source as (
    select * from {{ source('tpch', 'customer') }}
)

select
    c_custkey as customer_key,
    c_name as customer_name,
    c_nationkey as nation_key,
    c_mktsegment as market_segment,
    c_acctbal::number(18, 2) as account_balance
from source
