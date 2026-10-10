{#-
  prod: models land in clean schemas      -> STAGING, MARTS
  dev:  everything is isolated per person -> DBT_JDOE_STAGING, DBT_JDOE_MARTS
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema | trim }}
    {%- elif target.name == 'prod' -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema | trim }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
