#!/usr/bin/env bash
# Repository gate for jcheng-ops. Run locally or from CI; it touches no robot.
#
#   bash scripts/check_repo_gate.sh
#
# It checks: required files, shell syntax, the Python checker compiles, the
# tests pass, docs links resolve, and no gateway token is committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'GATE FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '== %s\n' "$*"; }

step "required files"
while IFS= read -r path; do
    [[ -e "$path" ]] || fail "missing $path"
done <<'EOF'
README.md
VERSION
CHANGELOG.md
LICENSE-REVIEW.md
capability.yaml
robot/armpi-ops-health
robot/armpi-ops-health.service
robot/armpi-ops-health.timer
robot/install-pi-ops.sh
studio/studio_watchdog.sh
studio/install-studio-watchdog.sh
studio/systemd-user/armpi-studio-watchdog.service
tests/test_ops_health.py
docs/ARCHITECTURE.md
docs/RUNBOOK.md
docs/INCIDENT-2026-11-24.md
docs/VERIFICATION.md
evidence/20261124/README.md
EOF

step "shell syntax"
while IFS= read -r script; do
    bash -n "$script" || fail "bash -n $script"
done < <(find robot studio scripts -name '*.sh' -type f | sort)

step "python syntax"
python3 -m py_compile robot/armpi-ops-health

step "secret scan"
if grep -rInE 'ARMPI_(GATEWAY|CAMERA_GATEWAY)_TOKEN=[0-9a-fA-F]{32,}' \
        --exclude-dir=.git . >/dev/null 2>&1; then
    fail "a gateway token looks committed"
fi
if find . -path ./.git -prune -o -name '*.env' -print | grep -q .; then
    fail "*.env files must stay outside the repository"
fi

step "tests"
python3 -m pytest -q tests

step "docs links"
python3 - <<'PY'
import re
import sys
from pathlib import Path

problems = []
for doc in [Path("README.md"), *sorted(Path("docs").glob("*.md")), Path("evidence/20261124/README.md")]:
    text = doc.read_text(encoding="utf-8")
    for target in re.findall(r"\]\(([^)]+)\)", text):
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        path = target.split("#", 1)[0]
        if not path:
            continue
        resolved = (doc.parent / path).resolve()
        if not resolved.exists():
            problems.append(f"{doc}: {target}")
if problems:
    print("broken relative links:", *problems, sep="\n  ")
    sys.exit(1)
print("all relative links resolve")
PY

step "gate OK"
