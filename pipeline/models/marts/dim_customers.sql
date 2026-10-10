with customers as (
    select * from {{ ref('stg_tpch__customers') }}
),

nations as (
    select * from {{ ref('stg_tpch__nations') }}
),

order_stats as (
    select
        customer_key,
        count(*) as order_count,
        sum(total_price) as lifetime_value,
        min(order_date) as first_order_date,
        max(order_date) as last_order_date
    from {{ ref('fct_orders') }}
    group by customer_key
)

select
    customers.customer_key,
    customers.customer_name,
    customers.market_segment,
    nations.nation_name,
    coalesce(order_stats.order_count, 0) as order_count,
    coalesce(order_stats.lifetime_value, 0) as lifetime_value,
    order_stats.first_order_date,
    order_stats.last_order_date
from customers
left join nations on customers.nation_key = nations.nation_key
left join order_stats on customers.customer_key = order_stats.customer_key
