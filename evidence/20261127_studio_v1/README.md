# Studio `/v1` wiring — 2026-11-27

> Evidence class: **L4 read-only**. The console reaches the robot's read-only
> `jcheng_telemetry` gateway and never sends an intent. No motion was commanded,
> no vendor unit or container was restarted.

## 1. What was installed on the laptop

| Item | Value |
|---|---|
| Tunnel unit | `armpi-studio-v1-tunnel.service` (user, enabled) |
| Forwards | `127.0.0.1:8766` → robot `127.0.0.1:8766` (legacy pose), `127.0.0.1:8767` → robot `127.0.0.1:8767` (read-only `/v1`) |
| Backend env | `~/.config/armpi-studio/studio.env` (0600) + `ARMPI_GATEWAY_V1_URL=http://127.0.0.1:8767`, `ARMPI_GATEWAY_V1_TOKEN`, `ARMPI_GATEWAY_V1_CONTRACT_HASH=sha256:0b8d72…` |
| Watchdog | `armpi-studio-watchdog.service` (user, enabled, `ARMPI_HARDWARE_MOTION=0`) |

Before this run the machine had an unversioned tunnel that forwarded only 8766
and pointed at the legacy pose gateway, so the `/v1` rows stayed
`not_configured`. The unit is now versioned in `studio/systemd-user/` and
installed by `studio/install-studio-watchdog.sh`.

## 2. Measured result

`GET /api/gateway/v1/status` (console → tunnel → robot loopback):

```json
{"configured": true, "reachable": true, "authenticated": true, "read_only": true,
 "ready": false, "health_status": "degraded",
 "contract_hash": "sha256:0b8d72…", "contract_match": true,
 "state_fresh": true, "state_truth": "commanded", "joint_count": 5,
 "battery_voltage": 7.677, "safety_state": "STOP_LATCHED", "stop_latched": true,
 "violation_codes": ["STATE_STALE", "HARDWARE_UNAVAILABLE"],
 "system_version": "0.2.0-dev", "profile_hash": "sha256:2098e5e5…",
 "latency_ms": 172, "errors": []}
```

`GET /api/health` still reports `hardware_motion: false`, `motion_mode:
read-only`, `gripper_control: false`.

Capability rows: `gateway_v1` and `session` moved from `not_configured` to
`degraded` ("网关未就绪"); `system_stop` stays `not_configured`
(`ARMPI_SYSTEM_STOP=0`), `teleop` stays `not_configured`
(`JCHENG_TELEOP_STATUS_URL` unset). Summary: available 9 / read_only 3 /
degraded 3 / not_configured 2 / offline 2.

## 3. Why `degraded` and not `available`

The read-only node's own preflight, from its journal:

```
read-only preflight degraded: ['bus_measured_fresh: age_s=None limit=0.5',
                               'battery_fresh: age_s=None limit=5.0']
```

`bus_measured_fresh: None` means no bus measurement has ever arrived. The vendor
service `/ros_robot_controller/bus_servo/get_state` is advertised in the
container, and `/joint_states` is present, but that topic is a **command cache**
(`state_truth: commanded`), so it cannot satisfy `require_bus=true`. The vendor
stack also reports `STOP_LATCHED`.

This is a robot/vendor condition, not a console or tunnel defect: the wiring is
complete and the numbers above are live. Clearing it needs a real bus read on
the robot (operator present); it must not be faked by setting
`require_bus=false`, which is what makes the read-only claim meaningful.

## 4. Regression found and fixed

`systemctl --user enable --now` does not restart an already-running unit, so the
first install attempt left the old tunnel (8766 only) and the old backend
environment in place, and a stale watchdog kept restarting the backend against
the pre-move `~/jcheng` path. The installer now runs `enable` + `restart` for
both units. During the bad window port 8000 was down for ~3 minutes; it
recovered to `/api/health` 200 once the watchdog reloaded the new env.
