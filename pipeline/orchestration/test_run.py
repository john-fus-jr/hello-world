import json
import logging
from types import SimpleNamespace as NS

import run


def result(node, status, seconds=1.0, message=None):
    return NS(node=NS(unique_id=node), status=status, execution_time=seconds, message=message)


def runner_result(results, success=True, exception=None):
    return NS(result=NS(results=results), success=success, exception=exception)


def test_summarize_counts_and_failures():
    res = runner_result(
        [
            result("model.pipeline.a", "success", 5),
            result("test.pipeline.b", "fail", 1, "Got 3 results"),
            result("model.pipeline.c", "skipped", 0),
        ],
        success=False,
    )
    s = run.summarize("build", res)
    assert s["success"] is False
    assert s["by_status"] == {"success": 1, "fail": 1, "skipped": 1}
    assert s["failures"] == [{"node": "test.pipeline.b", "status": "fail", "message": "Got 3 results"}]
    assert s["slowest"][0] == {"node": "model.pipeline.a", "seconds": 5.0}


def test_summarize_handles_crash_without_results():
    s = run.summarize("build", NS(result=None, success=False, exception=RuntimeError("boom")))
    assert s["nodes"] == 0 and s["error"] == "boom"


def test_format_alert_lists_failures():
    s = run.summarize("build", runner_result([result("model.pipeline.a", "error", message="SQL error")], False))
    text = run.format_alert("prod", s)
    assert "target=prod" in text and "model.pipeline.a [error]: SQL error" in text


def test_json_formatter_merges_fields():
    record = logging.LogRecord("pipeline", logging.INFO, __file__, 1, "hello", None, None)
    record.fields = {"step": "build"}
    entry = json.loads(run.JsonFormatter().format(record))
    assert entry["msg"] == "hello" and entry["step"] == "build" and entry["level"] == "INFO"


def test_failed_step_stops_pipeline_and_alerts(monkeypatch):
    calls, alerts = [], []
    monkeypatch.setattr(run, "dbt", lambda cmd, target: calls.append(cmd) or runner_result([], success=False))
    monkeypatch.setattr(run, "send_alert", alerts.append)
    assert run.run("prod", []) == 1
    assert calls == [["source", "freshness"]]  # build never ran on stale sources
    assert len(alerts) == 1
