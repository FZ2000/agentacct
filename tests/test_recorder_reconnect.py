"""Recorder-only startup skips integration writers, not runtime ownership."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest
from typer.testing import CliRunner

import agentacct.cli as cli
from agentacct.activation import RuntimeManagerError


@pytest.mark.parametrize("foreground", [False, True])
@pytest.mark.parametrize("flag", [None, "--sync-clients", "--no-sync-clients"])
def test_start_client_sync_option_preserves_runtime_path(tmp_path, monkeypatch, foreground, flag):
    resynced: list[Path] = []
    starts: list[bool] = []
    stops: list[bool] = []
    health_checks: list[Path] = []
    manager_requests: list[tuple[Path, str, int]] = []

    class Manager:
        def start(self, *, external_watcher_running):
            starts.append(external_watcher_running)
            return {"state": "running", "dashboard_url": "http://127.0.0.1:9999"}

        def stop(self):
            stops.append(True)

    def runtime(store, *, host, port):
        manager_requests.append((store, host, port))
        return Manager()

    def health(store):
        health_checks.append(store)
        return {}, True

    monkeypatch.setattr(cli, "_resolve_dashboard_cli_store_dir", lambda value: SimpleNamespace(path=Path(value)))
    monkeypatch.setattr(cli, "_resync_client_integration_on_start", resynced.append)
    monkeypatch.setattr(cli, "_runtime_ingestion_health", health)
    monkeypatch.setattr(cli, "_managed_runtime", runtime)
    monkeypatch.setattr(cli, "_supervise_foreground", lambda ensure, stop: (ensure(), stop()))
    args = ["start", "--store-dir", str(tmp_path), "--port", "9999", "--json"]
    if foreground:
        args.append("--foreground")
    if flag:
        args.append(flag)

    result = CliRunner().invoke(cli.app, args)

    assert result.exit_code == 0, result.output
    assert resynced == ([] if flag == "--no-sync-clients" else [tmp_path])
    assert starts == [True] * (2 if foreground else 1)
    assert health_checks == [tmp_path] * len(starts)
    assert manager_requests == [(tmp_path, "127.0.0.1", 9999)]
    assert stops == ([True] if foreground else [])


@pytest.mark.parametrize("foreground", [False, True])
def test_recorder_only_start_still_reports_runtime_refusal(tmp_path, monkeypatch, foreground):
    def refused(**kwargs):
        raise RuntimeManagerError("process ownership changed")

    monkeypatch.setattr(cli, "_resolve_dashboard_cli_store_dir", lambda value: SimpleNamespace(path=Path(value)))
    monkeypatch.setattr(cli, "_resync_client_integration_on_start", lambda store: pytest.fail("client config must not change"))
    monkeypatch.setattr(cli, "_runtime_ingestion_health", lambda store: ({}, False))
    monkeypatch.setattr(cli, "_managed_runtime", lambda *args, **kwargs: SimpleNamespace(start=refused))
    args = ["start", "--no-sync-clients", "--store-dir", str(tmp_path)]
    if foreground:
        args.append("--foreground")

    result = CliRunner().invoke(cli.app, args)

    assert result.exit_code == 1
    assert "process ownership changed" in result.output
