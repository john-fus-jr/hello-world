"""Pipeline entrypoint: source freshness -> dbt build -> structured summary -> alert on failure.

Usage (from the pipeline/ folder):
    python orchestration/run.py --target prod
    python orchestration/run.py --target dev --select staging+ --full-refresh

Any argument the runner doesn't recognise is passed straight to `dbt build`.
Exit codes: 0 = success, 1 = dbt reported failures, 2 = unexpected error.
"""

from __future__ import annotations

import argparse
import json
import logging
import logging.handlers
import os
import sys
import time
import urllib.request
from collections import Counter
from pathlib import Path

from dotenv import load_dotenv

PROJECT_DIR = Path(__file__).resolve().parent.parent
LOG_DIR = PROJECT_DIR / "logs"
FAILED_STATUSES = {"error", "fail", "runtime error"}

log = logging.getLogger("pipeline")


class JsonFormatter(logging.Formatter):
    """One JSON object per line; extra fields go in `logging.info(..., extra={"fields": {...}})`."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "msg": record.getMessage(),
            **getattr(record, "fields", {}),
        }
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


def setup_logging() -> None:
    LOG_DIR.mkdir(exist_ok=True)
    file_handler = logging.handlers.RotatingFileHandler(
        LOG_DIR / "pipeline.jsonl", maxBytes=10_000_000, backupCount=10, encoding="utf-8"
    )
    file_handler.setFormatter(JsonFormatter())
    console = logging.StreamHandler()
    console.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.handlers[:] = [file_handler, console]
    log.setLevel(logging.INFO)


def dbt(command: list[str], target: str):
    """Run a dbt command in-process (no subprocess / re-import overhead)."""
    from dbt.cli.main import dbtRunner

    args = [
        *command,
        "--target", target,
        "--project-dir", str(PROJECT_DIR),
        "--profiles-dir", str(PROJECT_DIR),
        "--log-path", str(LOG_DIR),
        "--log-format-file", "json",
    ]
    log.info("dbt %s", " ".join(command))
    return dbtRunner().invoke(args)


def summarize(step: str, res) -> dict:
    """Condense a dbtRunnerResult into a small, log/alert-friendly dict."""
    results = list(getattr(res.result, "results", None) or [])
    by_status = Counter(str(r.status) for r in results)
    failures = [
        {"node": r.node.unique_id, "status": str(r.status), "message": (r.message or "")[:500]}
        for r in results
        if str(r.status) in FAILED_STATUSES
    ]
    slowest = sorted(results, key=lambda r: r.execution_time or 0, reverse=True)[:5]
    return {
        "step": step,
        "success": bool(res.success),
        "nodes": len(results),
        "by_status": dict(by_status),
        "failures": failures,
        "slowest": [{"node": r.node.unique_id, "seconds": round(r.execution_time or 0, 1)} for r in slowest],
        "error": str(res.exception) if res.exception else None,
    }


def send_alert(text: str) -> None:
    url = os.getenv("ALERT_WEBHOOK_URL")
    if not url:
        return
    body = json.dumps({"text": text}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except Exception:
        log.exception("Failed to send alert")


def format_alert(target: str, summary: dict) -> str:
    lines = [f"dbt pipeline FAILED on {os.getenv('COMPUTERNAME', 'host')} (target={target}, step={summary['step']})"]
    lines += [f"- {f['node']} [{f['status']}]: {f['message']}" for f in summary["failures"][:10]]
    if summary["error"]:
        lines.append(f"- error: {summary['error']}")
    lines.append(f"Logs: {LOG_DIR}")
    return "\n".join(lines)


def run(target: str, build_args: list[str]) -> int:
    steps = [
        ("freshness", ["source", "freshness"]),
        ("build", ["build", *build_args]),
    ]
    for step, command in steps:
        started = time.monotonic()
        summary = summarize(step, dbt(command, target))
        summary["duration_seconds"] = round(time.monotonic() - started, 1)
        log.info("step %s %s", step, "succeeded" if summary["success"] else "FAILED", extra={"fields": summary})
        if not summary["success"]:
            send_alert(format_alert(target, summary))
            return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", default=os.getenv("DBT_TARGET", "dev"), choices=["dev", "prod"])
    args, build_args = parser.parse_known_args(argv)

    load_dotenv(PROJECT_DIR / ".env")  # real environment variables take precedence
    setup_logging()
    started = time.monotonic()
    try:
        code = run(args.target, build_args)
    except Exception as exc:
        log.exception("Pipeline crashed")
        send_alert(f"dbt pipeline CRASHED (target={args.target}): {exc!r}")
        code = 2
    log.info(
        "pipeline finished",
        extra={"fields": {"exit_code": code, "target": args.target, "duration_seconds": round(time.monotonic() - started, 1)}},
    )
    return code


if __name__ == "__main__":
    sys.exit(main())
