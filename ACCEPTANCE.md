# Acceptance report — jcheng-ops

> Status: **inconclusive** as of 2026-11-24 for v0.1.0.
> Operator: JerichoCheng. Reviewer: pending.
> Scope: the robot-side guards, the laptop Studio watchdog and the repository
> gate.
> All installed-item gates pass; the failure-path drills have not run, so the
> operational acceptance is not complete. The watchdog has never fired in a real
> wedge and the reboot path has not been exercised.
> No motion command is sent by this repository.

## 1. Gates

| Gate | Command | Level | Result | Evidence |
|---|---|---|---|---|
| Unit tests | `python3 -m pytest -q tests` | L1 | pass (5 tests) | `tests/test_ops_health.py` |
| Shell syntax | `bash -n robot/*.sh studio/*.sh scripts/*.sh` | L0 | pass | `scripts/check_repo_gate.sh` |
| Repository gate | `bash scripts/check_repo_gate.sh` | L0 | pass | CI `ops-gate` |
| Hardware watchdog armed | `systemctl show -p RuntimeWatchdogUSec` | L5 | pass (`15s`) | `evidence/20261124/verification.txt` |
| PID 1 holds the watchdog | `ls -l /proc/1/fd \| grep watchdog` | L5 | pass (`/dev/watchdog0`) | `evidence/20261124/verification.txt` |
| Health timer active and green | `systemctl is-active armpi-ops-health.timer`; `status.json` | L5 | pass (`summary=ok`, all failure counts 0) | `evidence/20261124/verification.txt` |
| Gateway health probes | `GET 8765/health`, `GET 8766/health` | L5 | pass (`status=ok`) | `evidence/20261124/verification.txt` |
| Restart policies | `systemctl show -p Restart` | L5 | pass (`always` / `on-failure`) | `evidence/20261124/verification.txt` |
| OOM protection | `systemctl show -p OOMScoreAdjust` | L5 | pass (sshd -800, gateways -500, start_node -300) | `evidence/20261124/verification.txt` |
| fstab repair | `findmnt --verify` | L5 | pass (0 errors; 2 expected warnings) | `evidence/20261124/verification.txt` |
| Studio watchdog branches | `studio_watchdog.sh --once --dry-run` | L5 | pass (restart and refuse) | `docs/VERIFICATION.md` §3 |
| Watchdog real trigger | controlled stall | L5 | not run | — |
| Reboot with drop-ins | `reboot` with an operator | L5 | not run | — |
| `linger` enabled | `loginctl show-user -p Linger` | L5 | not verified (`no` at the time) | `docs/VERIFICATION.md` §3 |

## 2. Verified claims

| Claim | Level | Evidence |
|---|---|---|
| The 15 s hardware watchdog is armed and PID 1 holds the device | L5 | `RuntimeWatchdogUSec=15s`; `/proc/1/fd` |
| The health timer runs every 30 s and reports green | L5 | `status.json`; `--dry-run` |
| A gateway restart requires the other gateway's motion state to be idle/disabled | L1 | `tests/test_ops_health.py`; decision logic |
| Three consecutive failures are required before a restart | L1 | `tests/test_ops_health.py` |
| Restart policies and OOM scores are installed | L5 | `systemctl show` |
| The Studio watchdog restarts an unhealthy backend when the gateway is reachable | L5 | branch A dry run |
| It refuses to kill the backend when the robot gateway is unreachable | L5 | branch B dry run |
| No motion command is sent and no device is opened | L0 | static scan; `capability.yaml` |

## 3. Not verified

| Item | Reason | Risk |
|---|---|---|
| Watchdog firing in a real wedge | No incident reproduced; a synthetic kernel stall was not attempted (the robot is the only test unit and the vendor boot moves the arm) | The trigger path is correct by design only |
| Reboot persistence of the drop-ins | Reboot runs the vendor startup sequence; needs an operator | OOM and watchdog settings are applied after the next boot |
| The 4 GB `python3` identity | Unknown; not part of the startup stack | The health check may not record the culprit before the OOM killer acts |
| 30-minute or longer stability | The timer had only run for minutes at verification time | Long-run behavior is unknown |
| `linger` for the Studio watchdog | The operator had not run `loginctl enable-linger` | The watchdog stops at logout/reboot |
| ROS-graph health | Only 8765/8766 and sshd are probed | MoveIt/controller/camera failures are invisible |

## 4. Limitations

- Not an e-stop; it cannot stop motion or protect personnel.
- A watchdog reboot runs the vendor startup sequence and the arm moves. The
  workspace must be clear.
- The BCM2835 watchdog timeout is fixed at 15 s.
- No per-process memory limit is imposed; the 4 GB process remains
  unidentified.
- The laptop watchdog depends on `linger` and on the gateway token file.

## 5. Sign-off

| Role | Name | Date |
|---|---|---|
| Operator | JerichoCheng | 2026-11-24 |
| Reviewer | pending | — |

## 6. Machine-readable report

None. Per-run reports, when produced, must validate against
`jcheng-interfaces/schemas/acceptance-report.v1.schema.json`.
