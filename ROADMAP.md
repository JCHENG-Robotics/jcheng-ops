# jcheng-ops roadmap

> Status: **v0.1.0** as of 2026-11-24. The guards are deployed and verified
> item by item; failure-path drills remain.

## Current state

| Item | State | Evidence |
|---|---|---|
| Incident record and root-cause analysis | Complete (2026-11-24) | `docs/INCIDENT-2026-11-24.md` |
| 15 s hardware watchdog | Deployed and verified | `RuntimeWatchdogUSec=15s`; PID 1 holds the fd |
| 30 s health timer with motion-idle guard | Deployed and verified | `status.json` green; `--dry-run` |
| Restart policies and OOM protection | Deployed and verified | `systemctl show` |
| Studio watchdog (laptop) | Deployed; both branches dry-run tested | `systemctl --user status`; `docs/VERIFICATION.md` |
| Operations admission manifest | Complete (2026-11-24) | `capability.yaml` |
| Watchdog real-trigger drill | Not started | — |
| Reboot with drop-ins | Not started | Vendor boot moves the arm |
| Memory attribution for the 4 GB process | Not started | Identity unknown |

## Milestones

| Milestone | Scope | State | Exit criterion | Evidence |
|---|---|---|---|---|
| M0 | Incident response and recovery | Complete (2026-11-24) | Robot recovered; timeline recorded | `docs/INCIDENT-2026-11-24.md` |
| M1 | Robot guards and Studio watchdog | Complete (2026-11-24) | All five layers installed; checks pass | `docs/VERIFICATION.md` |
| M2 | Operations admission manifest | Complete (2026-11-24) | `capability.yaml` accepted | `capability.yaml` |
| M3 | Failure-path drills | Not started | Watchdog fires in a controlled stall; reboot verified with an operator | — |
| M4 | Memory attribution and incident replay | Not started | The 4 GB process is identified or bounded | — |
| M5 | ROS-graph coverage | Not started | A health probe covers MoveIt/controllers/cameras | — |

## Next

1. **M3 — controlled failure drill.** Create a synthetic user-space stall with
   an operator present and confirm the hardware watchdog reboots the board. The
   vendor boot sequence moves the arm; keep the workspace clear.
2. **Verify reboot persistence.** Confirm `OOMScoreAdjust`, `Restart` and
   `RuntimeWatchdogUSec` survive a reboot.
3. **Memory attribution.** Add per-cgroup memory accounting or a watchdog that
   records the top processes before the OOM killer chooses a victim.

## Out of scope

- Sending motion commands or touching the control lease.
- Replacing the e-stop or enforcing workspace safety.
- Restarting the vendor container, which moves the arm on startup.
- Full ROS-graph health (MoveIt, controllers, camera drivers) in v0.1.

## Dependencies

- Robot: Raspberry Pi 5, systemd 252, BCM2835 `/dev/watchdog0`.
- Laptop: systemd user manager with `linger` enabled for the Studio watchdog.
- The Studio backend and gateways remain in `jcheng-manipulation`; this
  repository only observes and restarts them.
