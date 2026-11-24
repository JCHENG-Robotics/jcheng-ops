#!/usr/bin/env bash
# Install the ArmPi host operations guards. Run on the robot as root:
#
#   sudo bash install-pi-ops.sh            # default: 15 s hardware watchdog
#   sudo bash install-pi-ops.sh --no-watchdog
#
# It installs four independent layers, each of which can be removed on its own:
#
# 1. Health timer: `/usr/local/sbin/armpi-ops-health` every 30 s. It restarts a
#    gateway or sshd after three consecutive failed probes and logs memory
#    pressure with the top resident processes.
# 2. Restart policies: `armpi-gateway-pose` and `start_node` get
#    Restart=always / on-failure so a crash does not need a manual start.
# 3. OOM protection: sshd and both gateways get a negative OOMScoreAdjust so
#    the next memory hog is killed instead of the operator's only way in.
# 4. Hardware watchdog: systemd pings the BCM2835 watchdog and the board
#    reboots by itself if user space stops responding (the 2026-11-24 wedge
#    accepted TCP but never completed an SSH banner and needed a power cycle).
#    The Broadcom timer's timeout is fixed at 15 s and cannot be changed, so
#    that is the effective worst-case recovery time.
#
# Nothing here moves the arm: restarts only re-exec gateways and the ROS
# bringup. A watchdog reboot *does* run the vendor boot sequence, which moves
# the arm, so keep the workspace clear when the robot is unattended.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG=1
for arg in "$@"; do
    case "$arg" in
        --no-watchdog) WATCHDOG=0 ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "run as root (sudo bash $0)" >&2; exit 1; }

echo "== health script and units"
install -m 0755 "$HERE/armpi-ops-health" /usr/local/sbin/armpi-ops-health
install -m 0644 "$HERE/armpi-ops-health.service" /etc/systemd/system/armpi-ops-health.service
install -m 0644 "$HERE/armpi-ops-health.timer" /etc/systemd/system/armpi-ops-health.timer

echo "== restart policies and OOM protection"
install -d /etc/systemd/system/armpi-gateway-pose.service.d \
           /etc/systemd/system/armpi-gateway.service.d \
           /etc/systemd/system/start_node.service.d \
           /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/armpi-gateway-pose.service.d/restart.conf <<'EOF'
# The pose gateway is started by hand after a boot; a crash or a wedged
# process should bring it back without an operator at the bench.
[Service]
Restart=always
RestartSec=5
OOMScoreAdjust=-500
EOF
cat > /etc/systemd/system/armpi-gateway.service.d/oom.conf <<'EOF'
# Keep the read-only gateway (cameras + telemetry) alive under memory pressure.
[Service]
OOMScoreAdjust=-500
EOF
cat > /etc/systemd/system/start_node.service.d/restart.conf <<'EOF'
# A failed vendor bringup used to stay down until someone SSH'd in.
# Restarting it re-execs the ROS launch; it does not command the arm.
[Service]
Restart=on-failure
RestartSec=15
OOMScoreAdjust=-300
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=5
EOF
cat > /etc/systemd/system/ssh.service.d/oom.conf <<'EOF'
# sshd is the only remote way in; never let the OOM killer pick it first.
[Service]
OOMScoreAdjust=-800
EOF

echo "== hardware watchdog"
install -d /etc/systemd/system.conf.d
if [[ "$WATCHDOG" == "1" ]]; then
    cat > /etc/systemd/system.conf.d/10-runtime-watchdog.conf <<'EOF'
# Reboot if systemd stops pinging the BCM2835 watchdog. The chip's timeout is
# fixed at 15 s; systemd pings it every 7.5 s. This is the only automatic
# recovery from a user-space wedge (2026-11-24: TCP accepted, no SSH banner,
# gateway socket dead, manual power cycle required).
[Manager]
RuntimeWatchdogSec=15
EOF
else
    rm -f /etc/systemd/system.conf.d/10-runtime-watchdog.conf
fi

systemctl daemon-reload
systemctl enable --now armpi-ops-health.timer >/dev/null
if [[ "$WATCHDOG" == "1" ]]; then
    # Reload PID 1 in place so it opens /dev/watchdog without a reboot.
    systemctl daemon-reexec
fi

echo "== status"
systemctl is-enabled armpi-ops-health.timer
systemctl is-active armpi-ops-health.timer
systemctl show -p RuntimeWatchdogUSec
[[ "$WATCHDOG" == "1" ]] && ls -l /proc/1/fd 2>/dev/null | grep -i watchdog || true
systemctl start armpi-ops-health.service
cat /run/armpi-ops/status.json 2>/dev/null || echo "WARN: no status file yet"
