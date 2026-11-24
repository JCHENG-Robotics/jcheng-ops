# Changelog

## [Unreleased]

### Added

- `capability.yaml` — the organization admission manifest: layer `ops`
  (cross-layer, not imported by any runtime repository), no hardware access,
  `motion_authority: none`, the three runtime roles and their forbidden
  actions, plus the verification record and the three open items.

## [0.1.0] — 2026-11-24

First version, extracted from the 2026-11-24 incident response.

### Added

- `robot/armpi-ops-health` — one-shot health cycle: both gateway `/health`
  endpoints, the local sshd banner, memory/swap pressure with the top resident
  processes. Restarts a gateway only after three consecutive failures and only
  while the other gateway reports motion idle; restarts sshd after three
  banner failures. Writes `/run/armpi-ops/status.json`.
- `robot/armpi-ops-health.timer` (30 s) and `.service` (oneshot, `Nice=5`,
  `OOMScoreAdjust=-500`).
- `robot/install-pi-ops.sh` — installs the timer plus systemd drop-ins:
  `armpi-gateway-pose` `Restart=always` (was `no`), `start_node`
  `Restart=on-failure`, negative `OOMScoreAdjust` for sshd (-800), both
  gateways (-500) and `start_node` (-300), and `RuntimeWatchdogSec=15` in
  `/etc/systemd/system.conf.d/` (BCM2835's fixed timeout).
- `studio/studio_watchdog.sh` — checks `/api/health` every 30 s, restarts the
  backend after two failures, but never while the robot gateway is
  unreachable; when the gateway is down and port 8000 is held it logs once per
  five minutes and leaves the process alone.
- `studio/install-studio-watchdog.sh` and the `armpi-studio-watchdog.service`
  user unit; configuration in `~/.config/armpi-studio/studio.env` (0600).
- `tests/test_ops_health.py` — the decision logic (streaks, motion guard,
  dry-run restarts) without the robot.
- `scripts/check_repo_gate.sh` — required files, shell syntax, Python compile,
  secret scan, tests, relative-link check; used by `.github/workflows/ci.yml`.

### Fixed (in the deployment, not in this repository)

- `start_studio.sh` in `jcheng-manipulation` reordered: token, gateway and venv
  are resolved **before** the port guard. The old order killed a healthy
  backend and then failed the SSH token fetch during the outage.
- `/etc/fstab` on the robot had four identical `/swapfile` lines;
  `systemd-fstab-generator` failed on every boot. Collapsed to one
  (`/etc/fstab.bak-20261124`).

### Not verified

- The watchdog has never fired in a real wedge (no reproduction on the day it
  was installed; a synthetic kernel stall was not attempted because the robot
  is the only test unit).
- No end-to-end reboot test after the drop-ins (the vendor boot sequence moves
  the arm).
