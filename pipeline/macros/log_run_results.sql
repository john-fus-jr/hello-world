{#-
  on-run-end hook: writes one row per executed node to
  <target database>.<observability_schema>.DBT_RUN_RESULTS in a single INSERT.
  Query it from Snowsight to build run-health dashboards and alerts (see README).
-#}
{% macro log_run_results(results) %}
    {%- if not execute or not results or flags.WHICH not in ['build', 'run', 'test', 'seed', 'snapshot'] -%}
        {{ return('') }}
    {%- endif -%}

    {%- set relation = target.database ~ '.' ~ var('observability_schema') ~ '.DBT_RUN_RESULTS' -%}

    {%- set rows = [] -%}
    {%- for r in results -%}
        {%- do rows.append("(" ~ [
            sql_string(invocation_id),
            sql_string(run_started_at.isoformat()) ~ "::timestamp_tz",
            sql_string(flags.WHICH),
            sql_string(target.name),
            sql_string(r.node.unique_id),
            sql_string(r.node.resource_type),
            sql_string(r.status),
            (r.execution_time or 0) | round(3),
            sql_number((r.adapter_response or {}).get('rows_affected')),
            sql_number(r.failures),
            sql_string((r.message or '') | string | truncate(4000, true, '...'))
        ] | join(', ') ~ ")") -%}
    {%- endfor -%}

    {%- set sql -%}
        create schema if not exists {{ target.database }}.{{ var('observability_schema') }};
        create table if not exists {{ relation }} (
            invocation_id     varchar,
            run_started_at    timestamp_tz,
            command           varchar,
            target_name       varchar,
            unique_id         varchar,
            resource_type     varchar,
            status            varchar,
            execution_seconds number(12, 3),
            rows_affected     number,
            failures          number,
            message           varchar,
            logged_at         timestamp_tz default current_timestamp()
        );
        insert into {{ relation }} (
            invocation_id, run_started_at, command, target_name, unique_id, resource_type,
            status, execution_seconds, rows_affected, failures, message
        ) values
        {{ rows | join(',\n') }};
    {%- endset -%}

    {%- do run_query(sql) -%}
    {{ log("Logged " ~ results | length ~ " results to " ~ relation, info=true) }}
{% endmacro %}

{% macro sql_string(value) -%}
    {%- if value is none -%}null{%- else -%}
    '{{ value | string | replace("\\", "\\\\") | replace("'", "''") }}'
    {%- endif -%}
{%- endmacro %}

{% macro sql_number(value) -%}
    {{ 'null' if value is none else value }}
{%- endmacro %}
