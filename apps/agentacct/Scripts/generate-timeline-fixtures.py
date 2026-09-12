#!/usr/bin/env python3
"""Refresh synthetic native fixtures through the real shared timeline projection.

Session-shaped fixtures predate the shared contract. This fixture-only adapter
supplies their task shape; it is never a production reconstruction fallback.
"""
from copy import deepcopy
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "src"))
from agentacct.task_timeline import SCHEMA, build_timeline_events  # noqa: E402


def enrich(receipt, details):
    members = {(m["client"], m["client_session_id"]): m
               for group in receipt.get("sessions", []) for m in group.get("members", [])}
    groups = receipt.get("sessions", [])
    task = {"primary_root": groups[0]["root"] if groups else {}, "sessions": list(members.values()),
            "work_items": [], "task_evidence_events": []}
    for detail in details:
        session = detail["session"]
        if (session["client"], session["client_session_id"]) not in members:
            continue
        for step in detail.get("steps", []):
            work = deepcopy(step)
            work.update(client=session["client"], client_session_id=session["client_session_id"],
                        reporting_source=session["client"], evidence_events=work.pop("checks", []))
            task["work_items"].append(work)
    for check in receipt.get("dimensions", {}).get("evidence", {}).get("checks", []):
        row = deepcopy(check)
        row.update(created_at=row.pop("at", None), evidence_type=row.pop("kind", None),
                   source_type=row.pop("source", None), check_identity=row.pop("scope", None))
        task["task_evidence_events"].append(row)
    events = build_timeline_events(task)
    receipt["timeline"] = {"schema_version": SCHEMA, "events": events, "shown": len(events),
                           "total": len(events), "truncated": False}


def update(path):
    value = json.loads(path.read_text())
    work = value.get("work", {})
    for name in ["receipt", "attention_receipt"]:
        if work.get(name): enrich(work[name], work.get("sessions", []))
    for frame in value.get("native_review_frames", []):
        enrich(frame["receipt"], frame.get("sessions", []))
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    for path in sys.argv[1:] or [
        "apps/agentacct/Tests/agentacctTests/Fixtures/dashboard.json",
        "design-plans/native-macos-overhaul/fixtures/live-progress.json",
        "design-plans/native-macos-overhaul/fixtures/parallel-session-identity.json",
    ]:
        update(ROOT / path)
