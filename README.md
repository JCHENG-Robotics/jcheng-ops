# jcheng-ops

**English** | [简体中文](README.zh-CN.md)

Robot operations for JCHENG Robotics: unattended health checks, a hardware
watchdog, service self-healing, the Studio watchdog on the operator laptop, and
the incident runbook behind them.

Target: **ArmPi Ultra** (Raspberry Pi 5 + vendor ROS 2 Humble stack) and the
ArmPi Debug Studio on the operator laptop.

> Status: **Deployed** — v0.1.0 (2026-11-24). The four robot-side guards (15 s
> hardware watchdog, 30 s health timer, restart policies, OOM protection) are
> installed and verified item by item; the laptop Studio watchdog is installed
> and both the restart and refuse-to-restart branches were exercised.
> **The watchdog has never fired in a real wedge.** No incident was reproduced
> on installation day, so this is "correct by design", not "it has saved a
> session".
> English canonical; the Chinese README is a translation.

This repository **sends no motion command**, owns no camera/serial/bus device
and does not replace the e-stop.

---

## 1. Why this exists

At 09:20 on 2026-11-24 the robot suffered an OOM: the kernel killed a ~4 GB
`python3` (12.4 GB virtual memory). sshd then hit its `MaxStartups` limit,
`armpi-vision` would not start, the 8765 gateway socket accepted connections but
never answered, and the system entered a half-dead state that **required a power
cycle**.

The worst part is that every network-only check looked fine:

| Check | During the incident | Conclusion |
|---|---|---|
| `ping <ROBOT_LINK_IP>` | 0.16 ms, normal | Cable and Pi kernel alive |
| TCP 22 | Connection established | Port listening |
| SSH banner | Never returned (IPv4 and IPv6 link-local alike) | sshd wedged in user space |
| `8765 /health` | SYN accepted, no response | Gateway process hung |
| `8766` | `Connection refused` | Pose gateway not running |

The first principle is therefore: **probe the application layer, not the
network layer**. The second: **never take the laptop Studio down because the
robot is unreachable**.

Full timeline and evidence: [`docs/INCIDENT-2026-11-24.md`](docs/INCIDENT-2026-11-24.md).

## 2. Layers

| Layer | Location | Trigger | Action | Verified |
|---|---|---|---|---|
| Hardware watchdog | Robot PID 1 | systemd stops feeding `/dev/watchdog0` | Full board reboot | Armed (`RuntimeWatchdogUSec=15s`; PID 1 holds the fd) |
| Health check | Robot `armpi-ops-health.timer` | Every 30 s; 3 consecutive failures per probe | Restart the matching systemd service | Running on hardware; `status.json` green |
| Restart policies | Robot systemd drop-ins | Process crash/exit | `armpi-gateway-pose` always restarts; `start_node` on failure | Confirmed with `systemctl show` |
| OOM protection | Robot systemd drop-ins | Kernel picks a victim | sshd/gateways/start_node are harder to kill | `OOMScoreAdjust` set; fully effective after process restart |
| Studio watchdog | Laptop systemd user service | 2 consecutive `/api/health` failures | Restart the backend; refuse while the gateway is unreachable | Both branches dry-run tested |

Safety constraints (all implemented):

- Before restarting a gateway, the health check requires the **other gateway**
  to report `motion_state` as `idle`/`disabled`; while motion is active it only
  logs.
- If both gateways are unreachable, a restart is allowed only on the third
  consecutive failure (motion state is then unknowable).
- The Studio watchdog **does not kill** a process on port 8000 while the robot
  gateway is unreachable; it logs once every five minutes.
- Every action restarts a process; none sends a motion command.

## 3. Installation

Robot (the robot account has NOPASSWD sudo; the installer is idempotent):

```bash
scp robot/* <ROBOT_USER>@<ROBOT_LINK_IP>:/tmp/armpi-ops/
ssh <ROBOT_USER>@<ROBOT_LINK_IP> sudo bash /tmp/armpi-ops/install-pi-ops.sh
# health/restart/OOM only, without the hardware watchdog:
ssh <ROBOT_USER>@<ROBOT_LINK_IP> sudo bash /tmp/armpi-ops/install-pi-ops.sh --no-watchdog
```

Laptop (Studio watchdog):

```bash
studio/install-studio-watchdog.sh
sudo loginctl enable-linger "$USER"   # once; otherwise the watchdog stops at logout/reboot
```

`install-studio-watchdog.sh` resolves the gateway token (in order:
`ARMPI_GATEWAY_TOKEN`, the running backend environment, an SSH read of the
robot token file) and writes `~/.config/armpi-studio/studio.env` (0600). The
backend directory defaults to
`~/jcheng/jcheng-manipulation/armpi-debug-studio/backend` and can be overridden
with `ARMPI_STUDIO_BACKEND_DIR`.

## 4. Verification

```bash
# Robot
systemctl show -p RuntimeWatchdogUSec            # 15s
sudo ls -l /proc/1/fd | grep watchdog            # PID 1 holds /dev/watchdog0
systemctl list-timers armpi-ops-health.timer
cat /run/armpi-ops/status.json
sudo journalctl -u armpi-ops-health.service -n 20
sudo /usr/local/sbin/armpi-ops-health --dry-run  # probe only, no restart

# Laptop
systemctl --user status armpi-studio-watchdog
tail -f ~/.local/state/armpi-studio/watchdog.log
```

Repository gate (CI equivalent, never touches the robot):

```bash
bash scripts/check_repo_gate.sh
```

Full verification record: [docs/VERIFICATION.md](docs/VERIFICATION.md); results
and open items: [ACCEPTANCE.md](ACCEPTANCE.md).

## 5. Boundaries and non-claims

- **Not an e-stop.** It does not read encoders, torque or human proximity and
  cannot stop motion.
- **A watchdog reboot runs the vendor startup sequence and the arm moves.**
  Keep the workspace clear during unattended operation.
- 15 s is the fixed BCM2835 watchdog timeout (`SETTIMEOUT` is unsupported); it
  is not tunable.
- It does not limit per-process memory. The 4 GB `python3` from the incident is
  not part of the startup stack and its identity is still unknown; the health
  check records the top three resident processes when `MemAvailable < 400 MB`
  for the next investigation.
- The health check covers 8765/8766 and sshd only, not the ROS graph (MoveIt,
  controllers, camera drivers).
- The Studio watchdog depends on `linger`; without it the watchdog only lives
  in the current login session.

## 6. Layout

```text
capability.yaml  admission manifest: layer ops, no hardware access, motion_authority: none
robot/    robot side: health check (Python, stdlib only), service/timer, installer
studio/   laptop side: Studio backend watchdog, systemd user unit, installer
docs/     incident record, architecture, runbook, verification
evidence/ journal excerpts and command output from the incident (redacted)
tests/    unit tests for the health-check decision logic (no robot)
scripts/  the CI-equivalent repository gate
```

## 7. Evidence

- [`docs/INCIDENT-2026-11-24.md`](docs/INCIDENT-2026-11-24.md) — timeline,
  root cause, contributing factors
- [`docs/VERIFICATION.md`](docs/VERIFICATION.md) — 2026-11-24 hardware
  verification record
- [`evidence/20261124/`](evidence/20261124/README.md) — journal excerpts and
  command output
- [`ACCEPTANCE.md`](ACCEPTANCE.md) — results and open items

## 8. License

**Pending.** Like the other JCHENG-Robotics repositories, this repository has
no `LICENSE`; see [`LICENSE-REVIEW.md`](LICENSE-REVIEW.md). The code depends
only on the Python standard library, bash, systemd and curl.
