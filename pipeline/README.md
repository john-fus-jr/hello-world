# dbt + Snowflake pipeline

A small, production-ready scaffold for transforming data in Snowflake with dbt,
scheduled on an on-premises Windows server.

```
Windows Task Scheduler ──► orchestration/run.py ──► dbt source freshness ──► dbt build ──► Snowflake
   (daily, no overlap)        │                                                   │
                              ├─ logs/pipeline.jsonl   (one JSON summary per step) │
                              ├─ logs/dbt.log          (full dbt detail, JSON)     │
                              └─ webhook alert on failure                          ▼
                                                     OBSERVABILITY.DBT_RUN_RESULTS (per-node history)
                                                     QUERY_HISTORY tagged per model (cost)
```

**Why this shape:** dbt already provides the DAG, retries-by-rerun, testing and
lineage, so the only extra code is a ~150-line Python runner. No Airflow, Docker or
extra services to operate on Windows, and no package downloads at deploy time.

## Layout

| Path | Purpose |
| --- | --- |
| `models/staging/<source>/` | 1:1 cleanup of raw tables (views). One folder per source system. |
| `models/marts/` | Business-facing facts and dimensions (tables / incremental). |
| `data_tests/` | Singular tests; `data_tests/generic/` holds reusable column tests. |
| `macros/` | Schema naming, Snowflake query tags, run-result logging. |
| `orchestration/run.py` | Scheduled entrypoint: freshness → build → summary → alert. |
| `scripts/*.ps1` | Windows setup, interactive dbt wrapper, Task Scheduler registration. |
| `profiles.yml` | Connection config. Every secret comes from environment variables / `.env`. |

The example models use `SNOWFLAKE_SAMPLE_DATA.TPCH_SF1`, which exists in every
Snowflake account, so the project runs end-to-end before you add your own sources.

## 1. Snowflake setup (once)

Generate a key pair (OpenSSL ships with Git for Windows):

```powershell
openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 aes256 -inform PEM -out svc_dbt.p8
openssl rsa -in svc_dbt.p8 -pubout -out svc_dbt.pub
```

```sql
use role securityadmin;
create role if not exists transformer;
create user if not exists svc_dbt
    type = service
    default_role = transformer
    default_warehouse = transforming_wh
    rsa_public_key = '<contents of svc_dbt.pub without the BEGIN/END lines>';
grant role transformer to user svc_dbt;

use role sysadmin;
create warehouse if not exists transforming_wh
    warehouse_size = xsmall auto_suspend = 60 auto_resume = true initially_suspended = true;
create database if not exists analytics;
grant usage on warehouse transforming_wh to role transformer;
grant usage, create schema on database analytics to role transformer;
grant imported privileges on database snowflake_sample_data to role transformer;
```

Consider a resource monitor on `transforming_wh` to cap spend.

## 2. Install on the Windows server

Prerequisite: Python 3.12 from python.org (includes the `py` launcher).

```powershell
cd pipeline
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1   # creates .venv and .env
notepad .env                                                 # fill in Snowflake settings
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1   # installs + runs `dbt debug`
```

Store the private key outside the repo (e.g. `C:\secrets\snowflake\`) and restrict
both it and `.env` to the service account.

## 3. Run

```powershell
.venv\Scripts\python.exe orchestration\run.py --target prod              # what the scheduler runs
.venv\Scripts\python.exe orchestration\run.py --target dev --select marts # extra args go to `dbt build`
.venv\Scripts\python.exe orchestration\run.py --target prod --full-refresh
```

Exit codes: `0` success, `1` dbt failure (failed test/model or stale source), `2` crash.

Schedule it (as Administrator; prompts for the service account password):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1 -At 05:00 -User CORP\svc_dbt
```

The task never overlaps itself and is killed after 4 hours (`-TimeoutHours`).

### Developing

```powershell
scripts\setup.ps1 -Dev                         # adds sqlfluff + pytest
scripts\dbt.ps1 build --select +dim_customers  # any dbt command, .env loaded
scripts\dbt.ps1 docs generate; scripts\dbt.ps1 docs serve   # lineage graph in the browser
.venv\Scripts\sqlfluff lint models
.venv\Scripts\python -m pytest orchestration
```

In `dev`, all models build into `<DBT_DEV_SCHEMA>_STAGING` / `<DBT_DEV_SCHEMA>_MARTS`,
so developers never touch production schemas. In `prod` they go to `STAGING` / `MARTS`.

CI (`.github/workflows/pipeline-ci.yml`) runs on Windows and checks SQL lint,
`dbt parse --warn-error`, the runner's unit tests and PowerShell syntax — no
Snowflake credentials required.

## Observability

| Question | Where to look |
| --- | --- |
| Did last night's run succeed? | Task Scheduler history (exit code), or the last `pipeline finished` line in `logs/pipeline.jsonl` |
| What failed and why? | Alert webhook message; `failures` in `logs/pipeline.jsonl`; `logs/dbt.log` for full SQL errors |
| Which rows failed a test? | `TEST_AUDIT` schema (dev: `<DBT_DEV_SCHEMA>_TEST_AUDIT`); `store_failures` is on for all tests |
| Is a model getting slower / failing more often? | `OBSERVABILITY.DBT_RUN_RESULTS` (queries below) |
| What does each model cost? | `ACCOUNT_USAGE.QUERY_HISTORY`, every dbt query carries a JSON `query_tag` |

Logs rotate automatically (10 MB × 10 files for the runner, dbt's own rotation for `dbt.log`).
Set `ALERT_WEBHOOK_URL` in `.env` to post a `{"text": ...}` message on failure (Slack
incoming webhook or a Teams Workflows webhook).

```sql
-- Run history (last 7 days)
select invocation_id, target_name, min(run_started_at) as started_at,
       count(*) as nodes,
       count_if(status in ('error', 'fail')) as failures,
       round(sum(execution_seconds)) as node_seconds
from analytics.observability.dbt_run_results
where run_started_at > dateadd(day, -7, current_timestamp())
group by all
order by started_at desc;

-- Slowest models, with trend
select unique_id,
       round(avg(execution_seconds), 1) as avg_seconds,
       round(max_by(execution_seconds, run_started_at), 1) as last_seconds
from analytics.observability.dbt_run_results
where resource_type = 'model' and run_started_at > dateadd(day, -30, current_timestamp())
group by all
order by avg_seconds desc
limit 20;

-- Warehouse time per model (ACCOUNT_USAGE lags up to ~45 min)
select try_parse_json(query_tag):model::string as model,
       round(sum(total_elapsed_time) / 1000) as seconds,
       sum(bytes_scanned) as bytes_scanned
from snowflake.account_usage.query_history
where try_parse_json(query_tag):app::string = 'dbt'
  and start_time > dateadd(day, -7, current_timestamp())
group by all
order by seconds desc;
```

Pin these as Snowsight dashboard tiles, or wrap the first one in a Snowflake
`ALERT` for an independent check that doesn't depend on the Windows host.

## Extending

1. **New source:** create `models/staging/<system>/_<system>__sources.yml` and one
   `stg_<system>__<table>.sql` per table (rename, cast, nothing else). Add
   `loaded_at_field` + `freshness` so stale loads stop the pipeline before it builds.
2. **New mart:** add a model in `models/marts/` built only from `ref()`s, plus a YAML
   entry with `unique` / `not_null` tests on its key.
3. **Large tables:** copy the `fct_orders` pattern (`incremental` + `merge` + lookback
   window) so each run scans only recent data.
4. **New reusable test:** add a `{% test %}` block to `data_tests/generic/`.
5. **Packages:** need `dbt_utils` etc.? Add a `packages.yml`, run `scripts\dbt.ps1 deps`,
   and commit `package-lock.yml`.
6. **Different schedules:** tag models (`+tags: hourly`) and register a second task:
   `scripts\register-task.ps1 -TaskName dbt-hourly -ExtraArgs "--select tag:hourly"`
   (then change its trigger to hourly in Task Scheduler).
