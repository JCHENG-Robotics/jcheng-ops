#!/usr/bin/env bash
# Install the laptop-side Studio watchdog as a systemd user service.
#
#   studio/install-studio-watchdog.sh
#
# It writes ~/.config/armpi-studio/studio.env (0600, contains the gateway
# token), installs armpi-studio-watchdog.service into the user manager and
# enables it. The token is taken from ARMPI_GATEWAY_TOKEN if set, otherwise
# from a running Studio backend, otherwise over SSH from the robot.
#
# The generated configuration is READ-ONLY: it points at the reachable 8765
# gateway and sets ARMPI_HARDWARE_MOTION=0. A service unit must never enable
# motion; an operator starts a motion-enabled console by hand, per session.
#
# Persistence across logout/reboot needs lingering, which needs sudo once:
# the installer tries `sudo -n loginctl enable-linger` and prints the command
# if that is not possible.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$HOME/.config/armpi-studio"
ENV_FILE="$ENV_DIR/studio.env"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="armpi-studio-watchdog.service"
ROBOT_HOST="${ROBOT_HOST:-10.42.0.218}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_armpi}"
TOKEN_FILE="${TOKEN_FILE:-/home/pi/docker/tmp/armpi_gateway_deploy/token}"
PORT="${PORT:-8000}"

resolve_token() {
    if [[ -n "${ARMPI_GATEWAY_TOKEN:-}" ]]; then
        printf '%s' "$ARMPI_GATEWAY_TOKEN"
        return 0
    fi
    local pid token
    for pid in $(pgrep -f 'uvicorn app.main:create_app' || true); do
        [[ -r "/proc/$pid/environ" ]] || continue
        token="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^ARMPI_GATEWAY_TOKEN=//p' | head -1)"
        if [[ -n "$token" ]]; then
            printf '%s' "$token"
            return 0
        fi
    done
    timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
        -i "$SSH_KEY" "pi@$ROBOT_HOST" "sudo cat '$TOKEN_FILE' 2>/dev/null" || true
}

TOKEN="$(resolve_token)"
[[ -n "$TOKEN" ]] || { echo "ERROR: cannot find the gateway token; export ARMPI_GATEWAY_TOKEN" >&2; exit 1; }

# Default to the sibling jcheng-studio checkout in the workspace; the
# environment variable overrides it for a different layout.
BACKEND_DIR="${ARMPI_STUDIO_BACKEND_DIR:-$(cd "$REPO/.." && pwd)/jcheng-studio/backend}"
if [[ -x "$BACKEND_DIR/.venv/bin/python" ]]; then
    echo "backend: $BACKEND_DIR"
else
    echo "WARN: $BACKEND_DIR/.venv/bin/python is missing; the watchdog will not be able to start the backend"
fi

mkdir -p "$ENV_DIR"
if [[ -f "$ENV_FILE" ]]; then
    cp -a "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
fi
umask 077
cat > "$ENV_FILE" <<EOF
# ArmPi Studio backend environment, sourced by studio_watchdog.sh.
# Regenerate with studio/install-studio-watchdog.sh.
ARMPI_STUDIO_BACKEND_DIR=$BACKEND_DIR
ARMPI_MODE=hardware
ARMPI_HARDWARE_MOTION=0
ARMPI_GATEWAY_URL=http://$ROBOT_HOST:8765
ARMPI_CAMERA_GATEWAY_URL=http://$ROBOT_HOST:8765
ARMPI_GATEWAY_TOKEN=$TOKEN
ARMPI_CAMERA_GATEWAY_TOKEN=$TOKEN
DB_PATH=$HOME/.local/state/armpi-studio/studio.db
BIND_HOST=127.0.0.1
PORT=$PORT
EOF
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE (0600, ${#TOKEN}-char token)"

mkdir -p "$UNIT_DIR"
sed "s|@REPO@|$REPO|g" "$REPO/studio/systemd-user/$UNIT" > "$UNIT_DIR/$UNIT"
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT"

if ! loginctl show-user "$USER" -p Linger --value | grep -qx yes; then
    if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
        echo "enabled linger for $USER (watchdog survives logout/reboot)"
    else
        echo "WARN: lingering is off, so the watchdog stops at logout/reboot."
        echo "      run once: sudo loginctl enable-linger $USER"
    fi
fi

sleep 2
echo "== status"
systemctl --user --no-pager status "$UNIT" | head -6 || true
tail -3 "$HOME/.local/state/armpi-studio/watchdog.log" 2>/dev/null || true
