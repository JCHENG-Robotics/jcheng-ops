#!/usr/bin/env bash
# Keep the ArmPi Debug Studio backend alive on the operator laptop.
#
# Originally a manual restart after every robot reboot; it now runs as a
# systemd user service (studio/install-studio-watchdog.sh). Every
# ARMPI_STUDIO_INTERVAL seconds it checks /api/health. After
# ARMPI_STUDIO_FAIL_THRESHOLD consecutive failures it restarts the backend,
# but only when the robot gateway is reachable.
#
# The guard exists because of 2026-11-24: `start_studio.sh` killed a healthy
# backend and then failed to fetch the gateway token over SSH, leaving the
# Studio down while the robot was wedged. A dead robot must never cost a
# running backend: if the gateway is unreachable and port 8000 is held, this
# script logs once every five minutes and leaves the process alone.
#
# Configuration lives in ~/.config/armpi-studio/studio.env (0600), written by
# the installer: ARMPI_MODE, ARMPI_GATEWAY_URL/TOKEN, DB_PATH, PORT, BIND_HOST.
# The installer writes a read-only configuration (no motion scope or takeover
# acknowledgement); motion is never enabled by this service.
#
# Flags: --once (single cycle, for tests), --dry-run (log only).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ARMPI_STUDIO_ENV:-$HOME/.config/armpi-studio/studio.env}"
LOG_DIR="${ARMPI_STUDIO_LOG_DIR:-$HOME/.local/state/armpi-studio}"
INTERVAL="${ARMPI_STUDIO_INTERVAL:-30}"
FAIL_THRESHOLD="${ARMPI_STUDIO_FAIL_THRESHOLD:-2}"
LOG="$LOG_DIR/watchdog.log"
ONCE=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --once) ONCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$LOG_DIR"
if [[ -f "$LOG" ]] && (( $(stat -c%s "$LOG") > 1048576 )); then
    mv -f "$LOG" "$LOG.1"
fi

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

[[ -r "$ENV_FILE" ]] || { echo "missing $ENV_FILE (run install-studio-watchdog.sh)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
PORT="${PORT:-8000}"
BIND_HOST="${BIND_HOST:-127.0.0.1}"
# Resolved after the environment file is sourced: the installer writes the
# backend checkout to ARMPI_STUDIO_BACKEND_DIR, and that value must win.
BACKEND_DIR="${ARMPI_STUDIO_BACKEND_DIR:-$REPO/../jcheng-studio/backend}"
PYTHON="$BACKEND_DIR/.venv/bin/python"

last_stuck_log=0

health() { curl -sf -m 4 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; }

gateway_ok() {
    [[ -n "${ARMPI_GATEWAY_URL:-}" && -n "${ARMPI_GATEWAY_TOKEN:-}" ]] || return 1
    local body
    body="$(curl -s -m 5 --noproxy '*' -H "X-Armpi-Token: $ARMPI_GATEWAY_TOKEN" \
        "$ARMPI_GATEWAY_URL/health" 2>/dev/null)" || return 1
    [[ "$body" == *'"status": "ok"'* || "$body" == *'"status":"ok"'* ]]
}

port_pids() {
    ss -ltnp 2>/dev/null | grep ":$PORT " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

is_studio() {
    [[ -r "/proc/$1/cmdline" ]] && tr '\0' ' ' < "/proc/$1/cmdline" | grep -q 'app.main:create_app'
}

start_backend() {
    if [[ ! -x "$PYTHON" ]]; then
        log "ERROR: $PYTHON is missing; run: python3 -m venv backend/.venv && backend/.venv/bin/pip install -e '.[dev]'"
        return 1
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[dry-run] would start the backend on $BIND_HOST:$PORT"
        return 0
    fi
    (
        cd "$BACKEND_DIR" || exit 1
        nohup "$PYTHON" -m uvicorn app.main:create_app --factory \
            --host "$BIND_HOST" --port "$PORT" >> "$LOG_DIR/backend.log" 2>&1 &
    )
    for _ in $(seq 1 25); do
        health && { log "backend started on $BIND_HOST:$PORT"; return 0; }
        sleep 1
    done
    log "ERROR: backend did not answer /api/health within 25 s (see $LOG_DIR/backend.log)"
    return 1
}

restart_backend() {
    local pid
    for pid in $(port_pids); do
        if is_studio "$pid"; then
            log "killing unhealthy backend pid $pid"
            [[ "$DRY_RUN" == "1" ]] || kill "$pid" 2>/dev/null
        else
            log "port $PORT is held by non-studio pid $pid; refusing to kill it"
            return 1
        fi
    done
    for _ in $(seq 1 15); do
        ss -ltnp 2>/dev/null | grep -q ":$PORT " || break
        sleep 1
    done
    if ss -ltnp 2>/dev/null | grep -q ":$PORT "; then
        log "port $PORT still busy after SIGTERM; not forcing"
        return 1
    fi
    start_backend
}

trap 'log "watchdog stopping"; exit 0' TERM INT

log "watchdog start: pid $$ interval ${INTERVAL}s threshold $FAIL_THRESHOLD port $PORT"
fails=0
while :; do
    if health; then
        fails=0
    else
        fails=$((fails + 1))
        log "health check failed (${fails}/${FAIL_THRESHOLD})"
        if (( fails >= FAIL_THRESHOLD )); then
            if gateway_ok; then
                log "gateway reachable; restarting the unhealthy backend"
                restart_backend
            elif [[ -n "$(port_pids)" ]]; then
                now=$(date +%s)
                if (( now - last_stuck_log >= 300 )); then
                    log "gateway unreachable and port $PORT is held; leaving the backend alone (robot down)"
                    last_stuck_log=$now
                fi
            else
                log "gateway unreachable and no backend is running; starting one anyway"
                start_backend
            fi
            fails=0
        fi
    fi
    [[ "$ONCE" == "1" ]] && exit 0
    sleep "$INTERVAL" &
    wait $! 2>/dev/null
done
