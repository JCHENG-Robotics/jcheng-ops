# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `capability.yaml` — the organization admission manifest: layer `ops`
  (cross-layer, not imported by any runtime repository), no hardware access,
  `motion_authority: none`, the three runtime roles and their forbidden
  actions, plus the verification record and the three open items.

### Changed

- Studio watchdog defaults now target the successor `jcheng-studio` backend
  (the sibling checkout) instead of the frozen
  `jcheng-manipulation/armpi-debug-studio` checkout. The generated
  `studio.env` is read-only: `ARMPI_GATEWAY_URL` points at the reachable 8765
  gateway, `ARMPI_HARDWARE_MOTION=0`, and the pose takeover scope/ack are no
  longer written. A service unit must never enable motion.

### Fixed

- The watchdog resolves `ARMPI_STUDIO_BACKEND_DIR` after sourcing
  `studio.env`, so the installed backend path is honored instead of being
  overwritten by the script default.
- `install-pi-ops.sh` installs a `start_node` drop-in that waits for a stable
  `/dev/rrc` before launching. The CH340 servo adapter can re-enumerate about
  50 s after boot; the vendor controller opened the port during the gap,
  exited with ENOENT, and the ROS launch stayed up, so `Restart=on-failure`
  never fired (2026-11-27). The wait is state-based, opens no port and
  commands no motion.

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

### Fixed

In the deployment, not in this repository:

- `start_studio.sh` in `jcheng-manipulation` reordered: token, gateway and venv
  are resolved **before** the port guard. The old order killed a healthy
  backend and then failed the SSH token fetch during the outage.
- `/etc/fstab` on the robot had four identical `/swapfile` lines;
  `systemd-fstab-generator` failed on every boot. Collapsed to one
  (`/etc/fstab.bak-20261124`).
