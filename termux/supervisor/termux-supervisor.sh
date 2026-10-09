#!/data/data/com.termux/files/usr/bin/bash
# Termux-AGT supervisor — keeps the phone worker alive.
#
#   * holds a Termux wake lock while running (CPU stays on)
#   * starts the worker; restarts it if it exits (backoff on crash loops)
#   * honors updates/restart-requested (the self-update path): restarts
#     immediately so the new release boots
#
# Started by termux/setup-termux.sh and by the Termux:Boot entry
# (~/.termux/boot/termux-agt.sh). Logs to ~/agent-host/logs/supervisor.log.
set -u

AGENT_HOME="$HOME/agent-host"
WORKER_DIR="$AGENT_HOME/worker"
ENV_FILE="$AGENT_HOME/config/worker.env"
LOG_DIR="$AGENT_HOME/logs"
LOG="$LOG_DIR/supervisor.log"
RESTART_FLAG="$AGENT_HOME/updates/restart-requested"

mkdir -p "$LOG_DIR"
log() { echo "$(date '+%F %T') supervisor: $*" >>"$LOG"; }

[ -f "$ENV_FILE" ] || { log "FATAL: $ENV_FILE missing — run termux/setup-termux.sh"; exit 1; }
[ -d "$WORKER_DIR" ] || { log "FATAL: $WORKER_DIR missing — run termux/setup-termux.sh"; exit 1; }

# One supervisor at a time: if another copy is running, exit quietly.
if command -v pgrep >/dev/null 2>&1; then
  others="$(pgrep -f 'termux-supervisor.sh' | grep -v "^$$$" || true)"
  if [ -n "$others" ]; then
    log "another supervisor is already running (pid(s): $others); exiting"
    exit 0
  fi
fi

if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock 2>/dev/null || log "warning: termux-wake-lock failed"
else
  log "warning: termux-wake-lock not found (install Termux:API); the phone may sleep"
fi

log "supervisor started (worker: $WORKER_DIR)"

restart_ts=()
while true; do
  if [ -f "$RESTART_FLAG" ]; then
    rm -f "$RESTART_FLAG"
    log "restart requested by self-update; restarting into the new release"
    restart_ts=()
  fi

  # Crash backoff: more than 5 restarts in 120s means something is
  # fundamentally broken (e.g. a bad release) — wait 5 minutes instead
  # of hot-spinning the phone's CPU.
  now="$(date +%s)"
  fresh=()
  for t in ${restart_ts[@]+"${restart_ts[@]}"}; do
    if [ "$((now - t))" -lt 120 ]; then fresh+=("$t"); fi
  done
  restart_ts=("${fresh[@]}" "$now")
  if [ "${#restart_ts[@]}" -gt 5 ]; then
    log "worker crashed >5 times in 120s; backing off 300s"
    sleep 300
    restart_ts=()
    continue
  fi

  log "starting worker"
  # The worker reads $WORKER_CONFIG and the --config flag alike.
  WORKER_CONFIG="$ENV_FILE" \
    python3 "$WORKER_DIR/agent/main.py" --config "$ENV_FILE" >>"$LOG" 2>&1
  rc=$?
  log "worker exited rc=$rc; restarting in 5s"
  sleep 5
done
