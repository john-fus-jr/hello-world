-- Singular test example: the fact table must not drop or duplicate revenue.
-- Any returned row is a failure.
with totals as (
    select
        (select sum(total_price) from {{ ref('stg_tpch__orders') }}) as staging_total,
        (select sum(total_price) from {{ ref('fct_orders') }}) as fact_total
)

select * from totals
where staging_total != fact_total
