#!/data/data/com.termux/files/usr/bin/bash
# Termux-AGT phone installer — turns this Android phone into a
# Universal-AGT host.
#
# Run INSIDE Termux, from the Termux-AGT repo root:
#     bash termux/setup-termux.sh
#
# What it does:
#   1. installs Termux packages (python, git, nodejs, openssh, termux-api)
#   2. creates ~/agent-host (worker state) and ~/agent-apps
#   3. copies the Python host worker into ~/agent-host/worker
#   4. registers this phone with the control plane (provisioning token)
#      as host_type=termux-android-host, capabilities=[termux]
#   5. writes ~/agent-host/config/worker.env (mode 600)
#   6. installs the boot entry (~/.termux/boot, needs the Termux:Boot app)
#      and the supervisor that keeps the worker alive
#   7. acquires a wake lock and offers to start the worker now
#
# The worker is OUTBOUND-ONLY: it dials out to the control plane over
# HTTPS and never listens inbound. Deployed apps listen on 127.0.0.1
# ports on the phone; reach them via the phone's IP (Tailscale or LAN).
set -euo pipefail

log()  { echo "[termux-agt] $*"; }
fail() { echo "[termux-agt] FATAL: $*" >&2; exit 1; }

# -- 0. must run inside Termux -------------------------------------------
if [[ "${PREFIX:-}" != *"com.termux"* ]]; then
  fail "this installer must run inside Termux on Android (PREFIX=$PREFIX)"
fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$REPO_DIR/agent-host-platform/host-worker" ] \
  || fail "run me from the Termux-AGT repo root: bash termux/setup-termux.sh"

AGENT_HOME="$HOME/agent-host"
WORKER_SRC="$REPO_DIR/agent-host-platform/host-worker"
WORKER_DIR="$AGENT_HOME/worker"
SUP_DIR="$AGENT_HOME/supervisor"
CONFIG_DIR="$AGENT_HOME/config"
ENV_FILE="$CONFIG_DIR/worker.env"

# -- 1. packages -----------------------------------------------------------
log "installing Termux packages (python, git, nodejs, openssh, termux-api)"
pkg update -y >/dev/null 2>&1 || log "pkg update had warnings; continuing"
pkg install -y python git nodejs openssh termux-api \
  || fail "pkg install failed; check your network and re-run"

command -v python3 >/dev/null || fail "python3 still missing after install"
python3 - <<'EOF' || fail "python3 >= 3.12 is required (worker uses tarfile.data_filter)"
import sys
assert sys.version_info >= (3, 12), sys.version
EOF
log "python3 OK: $(python3 -c 'import sys; print(sys.version.split()[0])')"
command -v termux-wake-lock >/dev/null \
  || log "WARNING: termux-wake-lock not found — install the Termux:API app (F-Droid) for keep-alive"

# -- 2. directories --------------------------------------------------------
log "creating $AGENT_HOME"
mkdir -p "$AGENT_HOME"/{config,deployments,artifacts,logs,builds,updates,releases,quarantine} \
         "$HOME/agent-apps" "$SUP_DIR" "$HOME/.termux/boot"

# -- 3. worker code ----------------------------------------------------------
log "installing worker code to $WORKER_DIR"
rm -rf "$WORKER_DIR"
cp -r "$WORKER_SRC" "$WORKER_DIR"
cp "$REPO_DIR/termux/supervisor/termux-supervisor.sh" "$SUP_DIR/"
chmod +x "$SUP_DIR/termux-supervisor.sh"

# -- 4. python deps (requests only) ------------------------------------------
if ! python3 -c "import requests" 2>/dev/null; then
  log "installing python requests"
  python3 -m pip install --quiet requests \
    || fail "pip install requests failed"
fi

# -- 5. worker import smoke test ----------------------------------------------
python3 - <<EOF || fail "worker code failed to import"
import sys
sys.path.insert(0, "$WORKER_DIR")
import agent.config, agent.main
import deployments.termux_runtime, deployments.manifest, deployments.pipeline
import executor.handlers
ok, errs = deployments.manifest.validate_manifest(
    {"name": "smoke", "runtime": "termux",
     "service": {"command": "python app.py", "port": 8000}})
assert ok, errs
print("worker imports OK; termux manifest validates OK")
EOF

# -- 6. registration -----------------------------------------------------------
if [ -s "$ENV_FILE" ] && grep -qE "^WORKER_HOST_TOKEN=[^[:space:]]" "$ENV_FILE"; then
  log "worker.env already has credentials; skipping registration"
else
  log "registering this phone with the control plane"
  read -r -p "Control plane URL [https://termux.novamail.store]: " CP_URL
  CP_URL="${CP_URL:-https://termux.novamail.store}"
  read -r -p "Host name [termux-phone]: " HOST_NAME
  HOST_NAME="${HOST_NAME:-termux-phone}"
  read -r -s -p "Provisioning token: " PROV_TOKEN; echo
  [ -n "$PROV_TOKEN" ] || fail "provisioning token is required"

  WORKER_VERSION="$(grep -oP 'worker_version:\s*str\s*=\s*"\K[^"]+' \
    "$WORKER_DIR/agent/config.py" 2>/dev/null || echo "0.1.0")"

  REG_JSON="$(curl -sf -m 30 -X POST "$CP_URL/v1/hosts/register" \
    -H "Authorization: Bearer $PROV_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$HOST_NAME\",\"host_type\":\"termux-android-host\",\"capabilities\":[\"termux\"],\"worker_version\":\"$WORKER_VERSION\"}")" \
    || fail "host registration failed (HTTP error); check the URL and token"

  read -r HOST_ID HOST_TOKEN <<<"$(printf '%s' "$REG_JSON" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); h=d.get("host") or {}; print(h.get("id") or d.get("id") or "", d.get("host_token") or d.get("token") or "")')"
  [ -n "$HOST_ID" ] && [ -n "$HOST_TOKEN" ] \
    || fail "registration returned empty host id/token: $REG_JSON"

  cat > "$ENV_FILE" <<EOF
# Termux-AGT worker config — generated by termux/setup-termux.sh
WORKER_CONTROL_PLANE_URL=$CP_URL
WORKER_HOST_NAME=$HOST_NAME
WORKER_HOST_ID=$HOST_ID
WORKER_HOST_TOKEN=$HOST_TOKEN
WORKER_TERMUX=true
WORKER_CAPABILITIES=termux
WORKER_POLL_WAIT=25
WORKER_HEARTBEAT_INTERVAL=30
WORKER_WORK_DIR=$AGENT_HOME
WORKER_APPS_DIR=$HOME/agent-apps
WORKER_WORKER_VERSION=$WORKER_VERSION
EOF
  chmod 600 "$ENV_FILE"
  log "host registered as '$HOST_NAME' (id $HOST_ID)"
fi

# -- 7. boot entry --------------------------------------------------------------
cp "$REPO_DIR/termux/boot/termux-agt-boot.sh" "$HOME/.termux/boot/termux-agt.sh"
chmod +x "$HOME/.termux/boot/termux-agt.sh"
log "boot entry installed (~/.termux/boot/termux-agt.sh — needs the Termux:Boot app)"

# -- 8. wake lock -----------------------------------------------------------------
if command -v termux-wake-lock >/dev/null; then
  termux-wake-lock 2>/dev/null || true
  log "wake lock acquired (CPU stays on while Termux runs)"
fi

# -- 9. manual steps ----------------------------------------------------------------
echo
echo "================================================================"
echo " Phone-side setup is done. Two manual steps on the phone:"
echo "  1. Android Settings > Apps > Termux > Battery > Unrestricted"
echo "     (otherwise Android kills the worker in the background)"
echo "  2. Install Termux:Boot (F-Droid) so the worker starts on reboot"
echo "     Termux:API (F-Droid) is needed for the wake lock."
echo
echo " Your apps will be reachable at <phone-ip>:<port> — use the"
echo " Tailscale IP if the phone has Tailscale, else the Wi-Fi IP"
echo " (see it with: ip addr show wlan0)."
echo "================================================================"
echo
read -r -p "Start the worker now? [Y/n]: " START
if [[ "${START:-Y}" =~ ^[Yy]?$ ]]; then
  log "starting supervisor (logs: $AGENT_HOME/logs/supervisor.log)"
  # shellcheck disable=SC2094
  nohup bash "$SUP_DIR/termux-supervisor.sh" >>"$AGENT_HOME/logs/supervisor.log" 2>&1 &
  disown || true
  sleep 3
  if pgrep -f "agent/main.py" >/dev/null 2>&1; then
    log "worker is running. Watch it: tail -f $AGENT_HOME/logs/supervisor.log"
  else
    log "worker did not stay up; see $AGENT_HOME/logs/supervisor.log"
  fi
else
  log "not started. Start later with: bash $SUP_DIR/termux-supervisor.sh"
fi
