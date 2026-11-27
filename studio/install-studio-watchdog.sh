#!/usr/bin/env bash
# Install the laptop-side Studio watchdog as a systemd user service.
#
#   studio/install-studio-watchdog.sh
#
# It writes ~/.config/armpi-studio/studio.env (0600, contains the gateway
# token), installs armpi-studio-watchdog.service and
# armpi-studio-v1-tunnel.service into the user manager and enables both. The
# token is taken from ARMPI_GATEWAY_TOKEN if set, otherwise from a running
# Studio backend, otherwise over SSH from the robot.
#
# The tunnel forwards the robot's two loopback-only gateways to this laptop:
# 8766 (legacy pose) and 8767 (R10 read-only /v1, installed by
# jcheng-system's install-readonly-gateway.sh). Its token and contract hash are
# read from the robot; with no /v1 gateway the console reports it unconfigured.
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
TUNNEL_UNIT="armpi-studio-v1-tunnel.service"
ROBOT_HOST="${ROBOT_HOST:-10.42.0.218}"
SSH_USER="${SSH_USER:-pi}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_armpi}"
TOKEN_FILE="${TOKEN_FILE:-/home/pi/docker/tmp/armpi_gateway_deploy/token}"
# The read-only /v1 gateway installed by jcheng-system's
# install-readonly-gateway.sh. Its token and contract hash come from the robot;
# when it is absent the /v1 diagnostics stay unconfigured instead of guessing.
V1_ENV_FILE="${V1_ENV_FILE:-/etc/jcheng-system/readonly.env}"
V1_LOCAL_PORT="${V1_LOCAL_PORT:-8767}"
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

# The /v1 gateway token and contract hash are read from the robot. A missing
# gateway is not an error: the console then reports /v1 as not configured.
robot_ssh() {
    timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
        -i "$SSH_KEY" "$SSH_USER@$ROBOT_HOST" "$1" 2>/dev/null || true
}
V1_TOKEN="${ARMPI_GATEWAY_V1_TOKEN:-$(robot_ssh "sudo sed -n 's/^JCHENG_GATEWAY_TOKEN=//p' $V1_ENV_FILE" | head -1)}"
# /v1/health is unauthenticated by design (that is how the console probes it);
# /v1/contract needs the bearer token, so it is not usable for this lookup.
V1_CONTRACT_HASH="${ARMPI_GATEWAY_V1_CONTRACT_HASH:-$(robot_ssh "curl -s -m 3 http://127.0.0.1:$V1_LOCAL_PORT/v1/health" | sed -n 's/.*"contract_hash"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1)}"
if [[ -n "$V1_TOKEN" && -n "$V1_CONTRACT_HASH" ]]; then
    echo "v1 gateway: 127.0.0.1:$V1_LOCAL_PORT (token ${#V1_TOKEN} chars, $V1_CONTRACT_HASH)"
else
    echo "WARN: no /v1 gateway on the robot ($V1_ENV_FILE or :$V1_LOCAL_PORT missing); /v1 stays not configured"
fi

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
EOF
if [[ -n "$V1_TOKEN" && -n "$V1_CONTRACT_HASH" ]]; then
    cat >> "$ENV_FILE" <<EOF
# Read-only /v1 gateway, reached through armpi-studio-v1-tunnel.service.
ARMPI_GATEWAY_V1_URL=http://127.0.0.1:$V1_LOCAL_PORT
ARMPI_GATEWAY_V1_TOKEN=$V1_TOKEN
ARMPI_GATEWAY_V1_CONTRACT_HASH=$V1_CONTRACT_HASH
EOF
fi
cat >> "$ENV_FILE" <<EOF
DB_PATH=$HOME/.local/state/armpi-studio/studio.db
BIND_HOST=127.0.0.1
PORT=$PORT
EOF
chmod 600 "$ENV_FILE"
echo "wrote $ENV_FILE (0600, ${#TOKEN}-char token)"

mkdir -p "$UNIT_DIR"
sed "s|@REPO@|$REPO|g" "$REPO/studio/systemd-user/$UNIT" > "$UNIT_DIR/$UNIT"
# The tunnel keeps both loopback-only gateways reachable from this laptop.
sed -e "s|@SSH_KEY@|$SSH_KEY|g" -e "s|@SSH_USER@|$SSH_USER@|g" -e "s|@ROBOT_HOST@|$ROBOT_HOST|g" \
    "$REPO/studio/systemd-user/$TUNNEL_UNIT" > "$UNIT_DIR/$TUNNEL_UNIT"
systemctl --user daemon-reload
# enable --now would leave an already-running process on its old configuration,
# so an env/unit change only takes effect after an explicit restart.
systemctl --user enable "$TUNNEL_UNIT"
systemctl --user restart "$TUNNEL_UNIT"
systemctl --user enable "$UNIT"
systemctl --user restart "$UNIT"

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
