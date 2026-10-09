#!/usr/bin/env bash
# ============================================================================
# Termux-AGT — control-plane installer (one command, zero prompts)
#
# Installs the Termux-AGT control plane on a Debian/Ubuntu persistent host
# (the Grok VM) with NO systemd: control-plane API (Node) + cloudflared
# tunnel, supervised by supervisord, with a cron @reboot hook.
#
# This is Termux-AGT's OWN system — separate from uaht.novamail.store:
#   - own Supabase project (DATABASE_URL in /etc/termux-agt/control-plane.env)
#   - own Cloudflare tunnel (/etc/termux-agt/tunnel.token)
#   - own public hostname: https://termux.novamail.store
#   - own ports/dirs: internal 3100, /opt/termux-agt, /etc/termux-agt
#
# The PHONE is the host (termux worker); this machine runs only the control
# plane. No Docker here, no host-worker here.
#
# FULLY NON-INTERACTIVE: secrets are read from /etc/termux-agt/ and NEVER
# written into the repo, logs, or chat. If a required secret file is missing
# the script fails loudly naming the exact source — it does not prompt.
#
# Outbound-only design: nothing here opens an inbound port and nothing uses
# Tailscale. The host dials out (control plane -> Supabase, cloudflared ->
# Cloudflare edge).
#
# Usage (on the host, as the box user — NOT root):
#   git clone https://github.com/kilomene/Termux-AGT.git
#   cd Termux-AGT
#   bash install-termux-cp.sh
#
# Idempotent: safe to re-run after a host update/reboot wiped the runtime.
# ============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# 0. Preconditions (fail fast, fail precisely)
# --------------------------------------------------------------------------
if [ "$(uname -s)" != "Linux" ]; then
  echo "FATAL: this installer runs on Linux only (got $(uname -s))." >&2
  exit 1
fi
if [ "$(id -un)" = "root" ]; then
  echo "FATAL: run as the box user, not root (the script uses sudo itself)." >&2
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "FATAL: the box user needs passwordless sudo for apt setup." >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$REPO_DIR/agent-host-platform/control-plane/api"
[ -d "$API_DIR" ] || { echo "FATAL: expected repo dir missing: $API_DIR (run from the Termux-AGT checkout)." >&2; exit 1; }

SUPERVISORD_BIN="$HOME/.local/bin/supervisord"
SUPERVISORCTL_BIN="$HOME/.local/bin/supervisorctl"
# Base directory for all Termux-AGT runtime state. Single variable —
# no hardcoded /opt/termux-agt paths below this line.
TAGT_BASE="/opt/termux-agt"
SUPERVISOR_CONF="$TAGT_BASE/supervisor/supervisord.conf"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CLOUDFLARED_YML="$TAGT_BASE/supervisor/cloudflared.yml"
# Internal port for THIS control plane. uaht uses 3000; we use 3100 so both
# can live on the same host without colliding.
TAGT_PORT="3100"
TAGT_PUBLIC_URL="https://termux.novamail.store"

# --------------------------------------------------------------------------
# 1. Secrets: tunnel token + control-plane env must exist.
#    Never prompts, never invents, never stores secrets in the repo.
# --------------------------------------------------------------------------
echo "[install] 0. normalizing /etc/termux-agt ownership"
sudo mkdir -p /etc/termux-agt
sudo chown -R "$(id -un):$(id -gn)" /etc/termux-agt
chmod 700 /etc/termux-agt

echo "[install] 1. checking required secrets in /etc/termux-agt/"
for f in /etc/termux-agt/tunnel.token /etc/termux-agt/control-plane.env; do
  if [ ! -s "$f" ]; then
    echo "FATAL: required secret file missing or empty: $f" >&2
    echo "       tunnel.token: Cloudflare dashboard -> Zero Trust -> Tunnels -> termux-agt" >&2
    echo "       control-plane.env: DATABASE_URL from the termux-agt Supabase project" >&2
    echo "         (Database settings -> connection string, DIRECT port 5432);" >&2
    echo "         DATA_ENCRYPTION_KEY and UAHT_PROVISIONING_TOKEN are fresh" >&2
    echo "         'openssl rand -hex 32' values." >&2
    echo "       This script never prompts for secrets and never stores them in the repo." >&2
    exit 1
  fi
done
check_key() { # $1=file $2=key
  if ! grep -qE "^${2}=[^[:space:]]" "$1"; then
    echo "FATAL: $2 is missing or empty in $1" >&2; exit 1
  fi
}
check_key /etc/termux-agt/control-plane.env DATABASE_URL
check_key /etc/termux-agt/control-plane.env DATA_ENCRYPTION_KEY
check_key /etc/termux-agt/control-plane.env UAHT_PROVISIONING_TOKEN
for f in /etc/termux-agt/tunnel.token /etc/termux-agt/control-plane.env; do
  sudo chmod 600 "$f"; sudo chown "$(id -un):$(id -gn)" "$f"
done
echo "       core secrets present."

# --------------------------------------------------------------------------
# 2. System dependencies (apt). No docker — the phone is the host.
# --------------------------------------------------------------------------
echo "[install] 2. installing system packages"
sudo apt-get update -qq || echo "       warning: apt update failed, continuing with cached lists"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  nodejs npm curl cron sudo ca-certificates \
  >/dev/null || echo "       warning: apt install had errors, verifying tools"
for cmd in node npm curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "FATAL: required command missing after apt install: $cmd" >&2; exit 1; }
done
node --version

# --------------------------------------------------------------------------
# 3. supervisord (user install)
# --------------------------------------------------------------------------
echo "[install] 3. installing supervisord"
if [ ! -x "$SUPERVISORD_BIN" ]; then
  python3 -m pip install --user --quiet --break-system-packages supervisor
fi
"$SUPERVISORD_BIN" --version

# --------------------------------------------------------------------------
# 4. cloudflared binary (reuse the existing one if present)
# --------------------------------------------------------------------------
echo "[install] 4. ensuring cloudflared"
if [ ! -x "$CLOUDFLARED_BIN" ]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) CF_ARCH="amd64" ;; aarch64|arm64) CF_ARCH="arm64" ;;
    *) echo "FATAL: unsupported arch for cloudflared: $ARCH" >&2; exit 1 ;;
  esac
  # Pinned version — "latest" has broken us before. Bump deliberately.
  CLOUDFLARED_VERSION="2026.10.0"
  curl -fsSL -o /tmp/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CF_ARCH}"
  sudo install -m 0755 /tmp/cloudflared "$CLOUDFLARED_BIN"
  rm -f /tmp/cloudflared
fi
"$CLOUDFLARED_BIN" --version

# --------------------------------------------------------------------------
# 5. Layout
# --------------------------------------------------------------------------
echo "[install] 5. creating $TAGT_BASE layout"
sudo mkdir -p $TAGT_BASE/supervisor $TAGT_BASE/logs
sudo chown -R "$(id -un):$(id -gn)" $TAGT_BASE

# --------------------------------------------------------------------------
# 6. supervisord.conf (generated; secrets stay in /etc/termux-agt, never here)
# --------------------------------------------------------------------------
echo "[install] 6. writing supervisord.conf"
cat > "$SUPERVISOR_CONF" <<EOF
; Generated by Termux-AGT install-termux-cp.sh — do not hand-edit.
; Secrets live in /etc/termux-agt/ and are loaded at process start, never here.
[unix_http_server]
file=$TAGT_BASE/supervisor/supervisor.sock
chmod=0700

[supervisord]
logfile=$TAGT_BASE/supervisor/supervisord.log
pidfile=$TAGT_BASE/supervisor/supervisord.pid
childlogdir=$TAGT_BASE/supervisor
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$TAGT_BASE/supervisor/supervisor.sock

[program:control-plane]
directory=$API_DIR
command=/bin/bash -c 'set -a; source /etc/termux-agt/control-plane.env; set +a; PORT=$TAGT_PORT exec /usr/bin/node dist/index.js'
user=$(id -un)
autostart=true
autorestart=true
startsecs=10
stdout_logfile=$TAGT_BASE/supervisor/control-plane.log
stderr_logfile=$TAGT_BASE/supervisor/control-plane.err.log

[program:cloudflared]
command=/bin/bash -c 'exec env TUNNEL_TRANSPORT_PROTOCOL=http2 $CLOUDFLARED_BIN tunnel --config $CLOUDFLARED_YML --no-autoupdate run --token \\$(cat /etc/termux-agt/tunnel.token)'
user=$(id -un)
autostart=true
autorestart=true
startsecs=10
stdout_logfile=$TAGT_BASE/supervisor/cloudflared.log
stderr_logfile=$TAGT_BASE/supervisor/cloudflared.err.log

[program:cloudflared-2]
command=/bin/bash -c 'exec env TUNNEL_TRANSPORT_PROTOCOL=http2 $CLOUDFLARED_BIN tunnel --config $TAGT_BASE/supervisor/cloudflared-2.yml --no-autoupdate run --token \\$(cat /etc/termux-agt/tunnel.token)'
user=$(id -un)
autostart=true
autorestart=true
startsecs=10
stdout_logfile=$TAGT_BASE/supervisor/cloudflared-2.log
stderr_logfile=$TAGT_BASE/supervisor/cloudflared-2.err.log

[program:watchdog]
command=/usr/bin/python3 $TAGT_BASE/watchdog.py
user=$(id -un)
environment=TAGT_BASE="$TAGT_BASE",TAGT_PUBLIC_URL="$TAGT_PUBLIC_URL/v1/health",TAGT_PORT="$TAGT_PORT"
autostart=true
autorestart=true
startsecs=10
stdout_logfile=$TAGT_BASE/supervisor/watchdog.log
stderr_logfile=$TAGT_BASE/supervisor/watchdog.err.log
EOF
chmod 600 "$SUPERVISOR_CONF"

# Hardened cloudflared config: retries + aggressive heartbeat.
# Ingress rules live in the Cloudflare dashboard for this token tunnel
# (public hostname termux.novamail.store -> http://127.0.0.1:3100).
cat > "$CLOUDFLARED_YML" << 'CLOUDFLARED_YML_EOF'
# cloudflared tunnel client config for the Termux-AGT control plane.
no-autoupdate: true
protocol: http2
retries: 10
heartbeat-interval: 5s
heartbeat-count: 5
CLOUDFLARED_YML_EOF
cp "$CLOUDFLARED_YML" "$TAGT_BASE/supervisor/cloudflared-2.yml"

# Aggressive TCP keepalive: prevents provider NAT/firewall from killing
# idle tunnel connections (default 7200s is far too long).
echo 600 > /proc/sys/net/ipv4/tcp_keepalive_time
echo 30 > /proc/sys/net/ipv4/tcp_keepalive_intvl
echo 5 > /proc/sys/net/ipv4/tcp_keepalive_probes
grep -q 'tcp_keepalive_time' /etc/sysctl.conf 2>/dev/null || cat >> /etc/sysctl.conf << 'SYSCTL_EOF'
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
SYSCTL_EOF

# --------------------------------------------------------------------------
# 7. Watchdog: 5-second heartbeat + self-healing (adapted for Termux-AGT)
# --------------------------------------------------------------------------
echo "[install] 7. writing watchdog"
cat > $TAGT_BASE/watchdog.py << 'WATCHDOG_PY_EOF'
#!/usr/bin/env python3
"""Termux-AGT watchdog — 5-second heartbeat + self-healing.

Every 5 seconds:
  1. Pings the public health endpoint THROUGH the tunnel (keepalive).
  2. Checks all supervisord services are RUNNING (restarts any that died).
  3. Verifies the control-plane answers locally.

Failure policy: 3 consecutive failures of any check triggers a targeted
restart of the failed component. All actions are logged.
"""
import json
import logging
import os
import subprocess
import sys
import time
import urllib.request

PUBLIC_URL = os.environ.get("TAGT_PUBLIC_URL", "https://termux.novamail.store/v1/health")
TAGT_BASE = os.environ.get("TAGT_BASE", "/opt/termux-agt")
TAGT_PORT = os.environ.get("TAGT_PORT", "3100")
SUPERVISOR_CONF = f"{TAGT_BASE}/supervisor/supervisord.conf"
SUPERVISORCTL = os.path.join(os.environ.get("HOME", "/home/box"), ".local/bin/supervisorctl")
INTERVAL = 5
FAIL_THRESHOLD = 3
EXPECTED_SERVICES = ["cloudflared", "cloudflared-2", "control-plane"]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s watchdog: %(message)s",
    handlers=[
        logging.FileHandler(f"{TAGT_BASE}/supervisor/watchdog.log"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger()

def run(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:
        return -1, "", str(e)

def supervisor_status():
    rc, out, _ = run([SUPERVISORCTL, "-c", SUPERVISOR_CONF, "status"])
    states = {}
    if rc == 0:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                states[parts[0]] = parts[1]
    return states

def restart_service(name):
    log.warning("restarting service: %s", name)
    run([SUPERVISORCTL, "-c", SUPERVISOR_CONF, "restart", name], timeout=30)

def check_public_tunnel():
    try:
        req = urllib.request.Request(PUBLIC_URL, headers={"User-Agent": "tagt-watchdog/1.0"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            return bool(json.loads(resp.read().decode()).get("ok"))
    except Exception as e:
        log.debug("public ping failed: %s", e)
        return False

def check_local_health():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{TAGT_PORT}/v1/health", timeout=10) as resp:
            return bool(json.loads(resp.read().decode()).get("ok"))
    except Exception:
        return False

def main():
    log.info("watchdog starting — 5s interval, fail threshold %d", FAIL_THRESHOLD)
    fails = {"tunnel": 0, "services": 0, "health": 0}
    while True:
        try:
            if check_public_tunnel():
                fails["tunnel"] = 0
            else:
                fails["tunnel"] += 1
                log.warning("public tunnel ping failed (%d/%d)", fails["tunnel"], FAIL_THRESHOLD)
                if fails["tunnel"] >= FAIL_THRESHOLD:
                    log.error("tunnel dark — restarting cloudflared")
                    restart_service("cloudflared")
                    fails["tunnel"] = 0
                    time.sleep(10)
            states = supervisor_status()
            dead = [s for s in EXPECTED_SERVICES if states.get(s) != "RUNNING"]
            if not dead:
                fails["services"] = 0
            else:
                fails["services"] += 1
                log.warning("services not RUNNING: %s (%d/%d)", dead, fails["services"], FAIL_THRESHOLD)
                if fails["services"] >= FAIL_THRESHOLD:
                    for s in dead:
                        restart_service(s)
                    fails["services"] = 0
                    time.sleep(10)
            if check_local_health():
                fails["health"] = 0
            else:
                fails["health"] += 1
                log.warning("control-plane local health failed (%d/%d)", fails["health"], FAIL_THRESHOLD)
                if fails["health"] >= FAIL_THRESHOLD:
                    restart_service("control-plane")
                    fails["health"] = 0
                    time.sleep(10)
        except Exception:
            log.exception("watchdog loop error")
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
WATCHDOG_PY_EOF
chmod +x $TAGT_BASE/watchdog.py

# --------------------------------------------------------------------------
# 8. Build the control-plane API
# --------------------------------------------------------------------------
echo "[install] 8. building control plane"
cd "$API_DIR"
npm ci --no-audit --no-fund >/dev/null 2>&1 || npm install --no-audit --no-fund >/dev/null
npm run build
[ -f "$API_DIR/dist/index.js" ] || { echo "FATAL: build did not produce dist/index.js" >&2; exit 1; }

# --------------------------------------------------------------------------
# 9. cron @reboot hook + tunnel watchdog
# --------------------------------------------------------------------------
echo "[install] 9. installing cron @reboot hook"
CRON_LINE="@reboot $SUPERVISORD_BIN -c $SUPERVISOR_CONF"
CRON_TMP="$(mktemp)"
( crontab -l 2>/dev/null || true ) | grep -v -F "supervisord -c $SUPERVISOR_CONF" > "$CRON_TMP" || true
echo "$CRON_LINE" >> "$CRON_TMP"
if crontab "$CRON_TMP" 2>/dev/null; then
  echo "       @reboot hook installed."
else
  echo "       warning: crontab install failed, @reboot hook not installed"
fi
rm -f "$CRON_TMP"

cat > $TAGT_BASE/tunnel-watchdog.sh << WATCHDOG_EOF
#!/bin/bash
PUBLIC_URL="$TAGT_PUBLIC_URL/v1/health"
FAIL_FILE="/tmp/tagt-tunnel-watchdog.failcount"
if curl -s -m 20 "\$PUBLIC_URL" | grep -q '"ok":true'; then
  echo 0 > "\$FAIL_FILE"
  exit 0
fi
COUNT=\$(cat "\$FAIL_FILE" 2>/dev/null || echo 0)
COUNT=\$((COUNT + 1))
echo \$COUNT > "\$FAIL_FILE"
if [ \$COUNT -ge 3 ]; then
  echo "\$(date): tunnel down 15m, restarting cloudflared" >> $TAGT_BASE/supervisor/cloudflared-watchdog.log
  "$HOME/.local/bin/supervisorctl" -c $SUPERVISOR_CONF restart cloudflared
  echo 0 > "\$FAIL_FILE"
fi
WATCHDOG_EOF
chmod +x $TAGT_BASE/tunnel-watchdog.sh
( crontab -l 2>/dev/null | grep -v 'tagt-tunnel-watchdog'; echo "*/5 * * * * $TAGT_BASE/tunnel-watchdog.sh >> $TAGT_BASE/supervisor/cloudflared-watchdog.log 2>&1" ) | crontab - 2>/dev/null && echo "       tunnel watchdog installed (every 5m)." || echo "       warning: watchdog cron install failed"
sudo service cron start 2>/dev/null || sudo systemctl start cron 2>/dev/null || true

# --------------------------------------------------------------------------
# 10. (Re)start supervisord and verify
# --------------------------------------------------------------------------
echo "[install] 10. starting supervisord"
"$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONF" shutdown 2>/dev/null || true
sleep 2
for pid in $(pgrep -f "supervisord -c $SUPERVISOR_CONF" 2>/dev/null); do
  if [ "$pid" != "$$" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 15); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
  fi
done
sleep 2
rm -f $TAGT_BASE/supervisor/supervisor.sock
sleep 2
"$SUPERVISORD_BIN" -c "$SUPERVISOR_CONF"
for i in $(seq 1 15); do
  [ -S $TAGT_BASE/supervisor/supervisor.sock ] && break
  [ "$i" = "15" ] && { echo "FATAL: supervisord did not create its socket (see $TAGT_BASE/supervisor/supervisord.log)." >&2; exit 1; }
  sleep 2
done
sleep 5

echo "[install] 11. verifying services"
for i in $(seq 1 12); do
  "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONF" status
  NOT_RUNNING="$("$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONF" status | grep -v RUNNING || true)"
  [ -z "$NOT_RUNNING" ] && break
  [ "$i" = "12" ] && {
    echo "FATAL: not all services are RUNNING:" >&2
    echo "$NOT_RUNNING" >&2
    exit 1
  }
  echo "       waiting for services to start (attempt $i/12)..."
  sleep 5
done

for i in $(seq 1 12); do
  curl -sf -m 5 http://127.0.0.1:$TAGT_PORT/v1/health >/dev/null 2>&1 && break
  sleep 5
done
HEALTH="$(curl -sf -m 10 http://127.0.0.1:$TAGT_PORT/v1/health || true)"
if [ -z "$HEALTH" ]; then
  echo "FATAL: control plane health check failed (see $TAGT_BASE/supervisor/control-plane.err.log)." >&2
  exit 1
fi
echo "       control plane health: $HEALTH"

for i in $(seq 1 12); do
  grep -q "Registered tunnel connection" $TAGT_BASE/supervisor/cloudflared.err.log 2>/dev/null && break
  sleep 5
done
if grep -q "Registered tunnel connection" $TAGT_BASE/supervisor/cloudflared.err.log 2>/dev/null; then
  echo "       cloudflared: tunnel registered with Cloudflare edge."
else
  echo "FATAL: cloudflared did not register the tunnel (see $TAGT_BASE/supervisor/cloudflared.err.log)." >&2
  exit 1
fi

echo ""
echo "OK: Termux-AGT control plane is up."
echo "    Verify public HTTPS from anywhere: curl $TAGT_PUBLIC_URL/v1/health"
echo "    Phone worker: point setup-termux.sh at $TAGT_PUBLIC_URL"
