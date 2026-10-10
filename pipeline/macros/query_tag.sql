{#-
  Tag every query dbt issues with JSON metadata so Snowflake cost and
  performance can be attributed per model/run:

    select try_parse_json(query_tag):model::string as model,
           sum(total_elapsed_time) / 1000 as seconds
    from snowflake.account_usage.query_history
    where try_parse_json(query_tag):app::string = 'dbt'
    group by 1 order by 2 desc;

  Overrides the adapter defaults (which only tag when `query_tag` is configured).
-#}
{% macro snowflake__set_query_tag() -%}
    {%- set tag = {
        'app': 'dbt',
        'project': project_name,
        'target': target.name,
        'model': model.name if model is defined else none,
        'invocation_id': invocation_id
    } -%}
    {%- set original_query_tag = get_current_query_tag() -%}
    {%- do run_query("alter session set query_tag = '" ~ (tojson(tag) | replace("'", "''")) ~ "'") -%}
    {{ return(original_query_tag) }}
{%- endmacro %}

{% macro snowflake__unset_query_tag(original_query_tag) -%}
    {%- if original_query_tag -%}
        {%- do run_query("alter session set query_tag = '" ~ (original_query_tag | replace("'", "''")) ~ "'") -%}
    {%- else -%}
        {%- do run_query("alter session unset query_tag") -%}
    {%- endif -%}
{%- endmacro %}
