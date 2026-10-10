{#- Reusable column test. Usage in YAML:  data_tests: [non_negative] -#}
{% test non_negative(model, column_name) %}
    select {{ column_name }}
    from {{ model }}
    where {{ column_name }} < 0
{% endtest %}
