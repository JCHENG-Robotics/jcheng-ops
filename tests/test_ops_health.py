"""Tests for the robot-side health watch (robot/armpi-ops-health).

The script has no ``.py`` suffix because it is installed as an executable, so
it is loaded with a SourceFileLoader. Every probe is monkeypatched: the tests
cover the decision logic (streaks, motion guard, dry-run restarts), never the
robot.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import types
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "robot" / "armpi-ops-health"


def load(tmp_path: Path) -> types.ModuleType:
    if not SCRIPT.is_file():
        raise AssertionError(f"missing {SCRIPT}")
    loader = importlib.machinery.SourceFileLoader("armpi_ops_health", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    module.STATE_DIR = str(tmp_path)
    module.STATE_PATH = str(tmp_path / "state.json")
    module.STATUS_PATH = str(tmp_path / "status.json")
    module.TOKEN_CANDIDATES = (str(tmp_path / "token"),)
    (tmp_path / "token").write_text("test-token\n", encoding="utf-8")
    module.DRY_RUN = True
    module.FAIL_THRESHOLD = 1
    module.ssh_banner_ok = lambda: True
    return module


def read_status(tmp_path: Path) -> dict:
    return json.loads((tmp_path / "status.json").read_text(encoding="utf-8"))


def test_motion_active_only_for_busy_states(tmp_path):
    module = load(tmp_path)
    assert module.motion_active({"motion_state": "executing"}) is True
    assert module.motion_active({"motion_state": "idle"}) is False
    assert module.motion_active({"motion_state": "disabled"}) is False
    assert module.motion_active({"motion_state": None}) is False
    assert module.motion_active(None) is False


def test_gateway_bind_reads_env_and_falls_back(tmp_path, monkeypatch):
    module = load(tmp_path)
    env = tmp_path / "gateway.env"
    env.write_text("# comment\nARMPI_GATEWAY_BIND=10.0.0.9\n", encoding="utf-8")
    monkeypatch.setattr(module, "GATEWAY_ENV", {"gw": (str(env), "ARMPI_GATEWAY_BIND")})
    assert module.gateway_bind("gw") == "10.0.0.9"
    assert module.gateway_bind("missing") == module.DEFAULT_BIND


def test_gateway_restart_skipped_while_motion_active(tmp_path, monkeypatch):
    module = load(tmp_path)
    monkeypatch.setattr(module, "GATEWAYS", (("gw-a", 1), ("gw-b", 2)))

    def probe(unit, port, token):
        if unit == "gw-b":
            return {"status": "ok", "motion_state": "executing"}
        return None

    monkeypatch.setattr(module, "http_health", probe)
    module.main()

    actions = read_status(tmp_path)["actions"]
    assert actions == ["skipped restart of gw-a: motion active"]


def test_both_gateways_down_restarts_them(tmp_path, monkeypatch):
    module = load(tmp_path)
    monkeypatch.setattr(module, "GATEWAYS", (("gw-a", 1), ("gw-b", 2)))
    monkeypatch.setattr(module, "http_health", lambda unit, port, token: None)
    module.main()

    actions = read_status(tmp_path)["actions"]
    assert "dry-run restart gw-a: 1 consecutive health failures" in actions
    assert "dry-run restart gw-b: 1 consecutive health failures" in actions


def test_status_file_records_memory_and_gateways(tmp_path, monkeypatch):
    module = load(tmp_path)
    monkeypatch.setattr(module, "GATEWAYS", (("gw-a", 1),))
    monkeypatch.setattr(
        module,
        "http_health",
        lambda unit, port, token: {"status": "ok", "motion_state": "idle"},
    )
    module.main()

    status = read_status(tmp_path)
    assert status["summary"] == "ok"
    assert status["gateways"]["gw-a"]["motion_state"] == "idle"
    assert "mem_available_mb" in status
