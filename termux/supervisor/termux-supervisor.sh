#!/data/data/com.termux/files/usr/bin/bash
# Termux-AGT supervisor — keeps the whole phone system alive.
#
# Supervises three processes (each restarted on exit, with crash backoff):
#   1. control-plane API (node, 127.0.0.1:3100) — if installed via
#      termux/setup-control-plane.sh
#   2. cloudflared tunnel (publishes https://termux.novamail.store from the
#      phone) — if installed
#   3. host worker (claims deploys, runs apps as supervised processes)
#
# Honors updates/restart-requested for the worker (the self-update path).
# Holds a Termux wake lock while running. Started by setup-termux.sh and by
# the Termux:Boot entry (~/.termux/boot/termux-agt.sh).
# Logs to ~/agent-host/logs/supervisor.log.
set -u

AGENT_HOME="$HOME/agent-host"
WORKER_DIR="$AGENT_HOME/worker"
ENV_FILE="$AGENT_HOME/config/worker.env"
CP_ENV="$AGENT_HOME/config/control-plane.env"
CP_API="$AGENT_HOME/control-plane/agent-host-platform/control-plane/api/dist/index.js"
CLOUDFLARED_BIN="$AGENT_HOME/bin/cloudflared"
TOKEN_FILE="$AGENT_HOME/config/tunnel.token"
LOG_DIR="$AGENT_HOME/logs"
LOG="$LOG_DIR/supervisor.log"
RESTART_FLAG="$AGENT_HOME/updates/restart-requested"

mkdir -p "$LOG_DIR"
log() { echo "$(date '+%F %T') supervisor: $*" >>"$LOG"; }

[ -f "$ENV_FILE" ] || { log "FATAL: $ENV_FILE missing — run termux/setup-termux.sh"; exit 1; }
[ -d "$WORKER_DIR" ] || { log "FATAL: $WORKER_DIR missing — run termux/setup-termux.sh"; exit 1; }

# One supervisor at a time: if another copy is running, exit quietly.
# pgrep -f also matches our own ancestors (the ssh/nohup parents whose command
# lines contain the script name) — exclude self and the whole ancestor chain.
if command -v pgrep >/dev/null 2>&1; then
  ancestors=" $$ "
  _p="$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || true)"
  while [ -n "$_p" ] && [ "$_p" != "0" ] && [ "$_p" != "1" ]; do
    ancestors="$ancestors$_p "
    _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ' || true)"
  done
  others=""
  for _pid in $(pgrep -f 'termux-supervisor\.sh' 2>/dev/null || true); do
    case "$ancestors" in *" $_pid "*) continue ;; esac
    others="$others$_pid "
  done
  if [ -n "$others" ]; then
    log "another supervisor is already running (pid(s):$others); exiting"
    exit 0
  fi
fi

if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock 2>/dev/null || log "warning: termux-wake-lock failed"
else
  log "warning: termux-wake-lock not found (install Termux:API); the phone may sleep"
fi

# supervise <name> <command-string>
# Runs the command forever via `bash -c`; restarts on exit. More than 5
# restarts in 120s means something is fundamentally broken — back off 5
# minutes instead of hot-spinning the phone's CPU.
supervise() {
  local name="$1" cmd="$2"
  local restart_ts=()
  log "$name: supervisor loop started"
  while true; do
    local now fresh=() t
    now="$(date +%s)"
    for t in ${restart_ts[@]+"${restart_ts[@]}"}; do
      if [ "$((now - t))" -lt 120 ]; then fresh+=("$t"); fi
    done
    restart_ts=("${fresh[@]}" "$now")
    if [ "${#restart_ts[@]}" -gt 5 ]; then
      log "$name: crashed >5 times in 120s; backing off 300s"
      sleep 300
      restart_ts=()
      continue
    fi
    log "$name: starting"
    bash -c "$cmd" >>"$LOG" 2>&1
    local rc=$?
    log "$name: exited rc=$rc; restarting in 5s"
    sleep 5
  done
}

# --- 1. control-plane API ----------------------------------------------------
if [ -f "$CP_API" ] && [ -s "$CP_ENV" ]; then
  supervise "control-plane" \
    'set -a; source "$HOME/agent-host/config/control-plane.env"; set +a; exec node "$HOME/agent-host/control-plane/agent-host-platform/control-plane/api/dist/index.js"' &
  log "control-plane: enabled"
else
  log "control-plane: not installed (run termux/setup-control-plane.sh first); skipping"
fi

# --- 2. cloudflared tunnel ----------------------------------------------------
# Prefer the Termux-packaged cloudflared (Android-native build with working
# DNS). The precompiled linux-arm64 binary cannot resolve DNS on Android
# ("server misbehaving" on [::1]:53) — verified on-device 2026-10-10.
CFD_BIN=""
if command -v cloudflared >/dev/null 2>&1; then
  CFD_BIN="$(command -v cloudflared)"
elif [ -x "$CLOUDFLARED_BIN" ]; then
  CFD_BIN="$CLOUDFLARED_BIN"
fi
if [ -n "$CFD_BIN" ] && [ -s "$TOKEN_FILE" ]; then
  supervise "cloudflared" \
    "exec \"$CFD_BIN\" tunnel --no-autoupdate run --token \"\$(cat \"$TOKEN_FILE\")\"" &
  log "cloudflared: enabled ($CFD_BIN)"
else
  log "cloudflared: not installed; skipping (https://termux.novamail.store will not work)"
fi

# --- 3. host worker -------------------------------------------------------------
# Also honors updates/restart-requested (the self-update path): restarts
# immediately so the new release boots.
worker_loop() {
  local restart_ts=()
  while true; do
    if [ -f "$RESTART_FLAG" ]; then
      rm -f "$RESTART_FLAG"
      log "worker: restart requested by self-update; restarting into the new release"
      restart_ts=()
    fi
    local now fresh=() t
    now="$(date +%s)"
    for t in ${restart_ts[@]+"${restart_ts[@]}"}; do
      if [ "$((now - t))" -lt 120 ]; then fresh+=("$t"); fi
    done
    restart_ts=("${fresh[@]}" "$now")
    if [ "${#restart_ts[@]}" -gt 5 ]; then
      log "worker: crashed >5 times in 120s; backing off 300s"
      sleep 300
      restart_ts=()
      continue
    fi
    log "worker: starting"
    WORKER_CONFIG="$ENV_FILE" \
      python3 "$WORKER_DIR/agent/main.py" --config "$ENV_FILE" >>"$LOG" 2>&1
    local rc=$?
    log "worker: exited rc=$rc; restarting in 5s"
    sleep 5
  done
}
worker_loop &
log "worker: enabled"

log "supervisor running"
# Stay alive as the group leader. The supervised loops never exit on their
# own; if this process is killed, everything stops — as intended.
wait
