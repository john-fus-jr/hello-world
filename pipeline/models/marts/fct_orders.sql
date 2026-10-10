{{
    config(
        materialized='incremental',
        unique_key='order_key',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

select
    order_key,
    customer_key,
    order_date,
    order_status,
    total_price,
    current_timestamp()::timestamp_ltz as updated_at
from {{ ref('stg_tpch__orders') }}

{% if is_incremental() %}
    -- Only scan recent rows; the lookback absorbs late-arriving updates.
    where order_date >= (
        select dateadd(day, -{{ var('orders_lookback_days', 3) }}, max(existing.order_date))
        from {{ this }} as existing
    )
{% endif %}
