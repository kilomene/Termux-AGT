# Termux-AGT — your Android phone as a deployment host

Termux-AGT turns an Android phone running [Termux](https://termux.dev) into a
first-class deployment host: the phone runs the Python host worker, claims
deploy tasks from the control plane, and runs apps as supervised native
processes. Termux-AGT is its own complete system — **not** part of
uaht.novamail.store:

| Piece | Termux-AGT | Universal-AGT |
|---|---|---|
| Control plane | `https://termux.novamail.store` | `https://uaht.novamail.store` |
| Database | own Supabase project (`termux-agt`) | own Supabase project |
| Edge / tunnel | own Cloudflare tunnel | own Cloudflare tunnel |
| Hosts | Android phone(s) via Termux | Linux VM(s) via Docker |

The phone is just a host — it dials out to `https://termux.novamail.store`,
claims tasks, and serves its apps from the phone's own IP address.

There is no Docker on Android, so the phone runs the **`termux` execution
backend**: apps are supervised OS processes, not containers. Everything else
— heartbeats, task claiming, artifact verification, healthcheck gating,
rollback, crash-loop detection, self-updates — is the same worker.

## How it fits together

```
agent ──deploy (runtime=termux)──▶ control plane ──task──▶ phone worker (Termux)
                                                            │  shlex-split service.command
                                                            │  supervised process, $PORT injected
                                                            ▼
                                              app answers 127.0.0.1:<port>/ with 200
                                                            │
user/agent ────────────────────────── http://<phone-ip>:<port>/ ◀──┘
```

The worker is **outbound-only**: it dials out to the control plane over HTTPS
and never listens inbound. Deployed apps listen on `127.0.0.1` ports *on the
phone*; you reach them at the phone's IP (Tailscale IP is the easy stable
choice; the Wi-Fi/LAN IP works too).

## Phone prerequisites

1. **Termux from F-Droid** (or the GitHub releases) — NOT the Play Store
   build, which is years out of date and broken.
2. **Termux:API** (F-Droid) — needed for the wake lock that keeps the CPU on.
3. **Termux:Boot** (F-Droid, optional but recommended) — starts the worker
   when the phone reboots.
4. Android 7+ (arm64 recommended). The phone should stay on Wi-Fi and ideally
   on a charger — it is now a server.

## Control plane install (on the VM, one time)

Termux-AGT's control plane is its own production system — separate Supabase
database, separate Cloudflare tunnel, separate domain. On the Debian/Ubuntu
host (the Grok VM), as the `box` user:

```bash
git clone https://github.com/kilomene/Termux-AGT
cd Termux-AGT
bash install-termux-cp.sh
```

Before running it, two secret files must exist (the script fails loudly with
the exact source if they're missing — it never prompts):

- `/etc/termux-agt/tunnel.token` — Cloudflare dashboard → Zero Trust →
  Tunnels → `termux-agt` (its own tunnel; DNS `termux.novamail.store`
  CNAMEs to it, proxied)
- `/etc/termux-agt/control-plane.env` — with `DATABASE_URL` (the
  `termux-agt` Supabase project, **direct** connection port 5432),
  `DATA_ENCRYPTION_KEY` and `UAHT_PROVISIONING_TOKEN` (fresh
  `openssl rand -hex 32` values)

The installer puts the API on internal port **3100** (uaht keeps 3000, so both
systems can share the host), supervises it plus dual cloudflared plus a
5-second watchdog, and installs a cron `@reboot` hook. Verify from anywhere:
`curl https://termux.novamail.store/v1/health`.

## Install (on the phone, inside Termux)

```bash
pkg install -y git
git clone https://github.com/kilomene/Termux-AGT
cd Termux-AGT
bash termux/setup-termux.sh
```

The installer asks for three things:

| Prompt | What it is |
|---|---|
| Control plane URL | `https://termux.novamail.store` (default) |
| Host name | e.g. `termux-phone` (default) |
| Provisioning token | the Termux-AGT control-plane provisioning token (from `/etc/termux-agt/control-plane.env` on the VM — never the uaht one) |

It registers the phone as `host_type=termux-android-host` with
`capabilities=["termux"]`, writes `~/agent-host/config/worker.env`
(mode 600), installs the boot entry and the supervisor, takes a wake lock,
and offers to start the worker immediately.

Two manual Android steps the installer cannot do for you:

1. **Settings → Apps → Termux → Battery → Unrestricted.** Otherwise Android
   kills the worker in the background and your "server" randomly dies.
2. Open the **Termux:Boot** app once after installing it (it needs one manual
   launch to register its boot receiver).

Check it's alive: `tail -f ~/agent-host/logs/supervisor.log`, and on the
control plane the host should report heartbeats with `capabilities: ["termux"]`.

## Deploying to the phone

Write `agent.deploy.json` with the **`termux` runtime**:

```json
{
  "name": "hello-phone",
  "runtime": "termux",
  "service": {
    "command": "python app.py",
    "port": 8000,
    "healthcheck": "/"
  },
  "restart": "unless-stopped"
}
```

Rules for the command:

- It is split with `shlex` into an argv list — **never a shell**. `;`, `&&`,
  backticks and `$()` become literal arguments, not execution.
- It runs with the extracted artifact directory as its working directory.
- The worker injects **`$PORT`** (the reserved host port) into the
  environment — your app **must listen on `$PORT`** (12-factor style).
  `service.port` is the app's *internal* default; the actual port the app
  gets is `$PORT`.
- Manifest `env` plus task secrets become process environment. Secrets are
  process-env only — never written to disk.
- Deploy rule #1 still holds: the app must answer
  `GET http://127.0.0.1:<port><healthcheck>` with **200 within 120s**, or the
  deploy fails and the previous generation keeps serving.

Minimal `app.py`:

```python
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(os.environ.get("PORT", "8000"))

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"hello from the phone")
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", port), H).serve_forever()
```

Node works the same (`command": "node server.js"` — the installer ships
nodejs). Static sites: `"command": "python3 -m http.server $PORT"` won't
expand `$PORT` (no shell!) — write a two-line launcher script instead, or
have the app read `os.environ["PORT"]` itself.

### Routing the deploy to the phone

The control plane's scheduler maps `runtime=termux` → required capability
`termux`, so auto-scheduling lands termux apps on the phone automatically —
no `host_id` pinning needed. (This mapping is part of Termux-AGT's own
control plane, which is built from this repo.)

## Reaching your apps

```
http://<phone-ip>:<port>/
```

- **Tailscale IP** (e.g. `100.x.x.x`): stable, reachable from anywhere your
  tailnet reaches. Recommended.
- **Wi-Fi IP**: `ip addr show wlan0 | grep inet` in Termux. Works on the LAN.
- The port is the one in the deploy result (`ports` map), not `service.port`.

## Lifecycle

All the usual task types work for termux deployments: `deploy`, `restart`,
`stop`, `start`, `remove`, `rollback`, `logs` (tails `app.log`), `status`,
`healthcheck`, `environment-update`, `system-info`.

- **Restarts**: the supervisor restarts crashed apps per the manifest
  `restart` policy (`no` / `always` / `unless-stopped` / `on-failure`,
  default `unless-stopped`). Restarts are recorded for crash-loop detection;
  a crash-looping app is stopped and flagged, never hot-spun.
- **Reboot**: on worker boot, desired-running deployments are restarted
  under supervision. **Exception — read this:** secrets are never persisted
  to disk, so a deployment that ran *with secrets* cannot be faithfully
  restored after the phone reboots. It is marked `degraded` and left
  stopped; redeploy to restore it. (This is the one place the phone backend
  differs from Docker, where the daemon keeps the container with its env.)
- **Updates**: the control plane can advertise worker updates; the phone
  worker downloads, verifies, swings to the new release and exits, and the
  supervisor boots the new version (systemd-free path).

## Security posture — read before deploying

There is **no container boundary** on this backend. A `runtime=termux` app
runs as the same OS user as the worker, with the worker's privileges, on
your phone. Treat termux deploys with exactly the trust you place in the
deploying agent itself — which, in this system, is your own agent fleet
running your own code. Do not deploy third-party artifacts to the phone.

Additionally, on a shared (non-termux) host the worker **refuses**
`runtime=termux` outright — the process backend never executes agent code
outside a termux host.

## Limitations (v1)

- Only `runtime=termux` deploys run on the phone. `docker`, `docker-compose`
  and `static` are rejected with a clear error (there is no Docker on Android).
- No public ingress provider yet (no cloudflared tunnel supervision on the
  phone) — apps are reached directly at `<phone-ip>:<port>`. The phone's IP
  being directly reachable is the point.
- Aggressive OEM skins (looking at you, MIUI/HyperOS) can still kill Termux
  despite the Unrestricted battery setting — check the supervisor log if the
  host goes quiet.
- Python on the phone must be ≥ 3.12 (the installer enforces it).

## Files in this repo

| Path | What |
|---|---|
| `termux/setup-termux.sh` | the installer (run on the phone) |
| `termux/supervisor/termux-supervisor.sh` | keep-alive supervisor (wake lock, restarts, crash backoff) |
| `termux/boot/termux-agt-boot.sh` | Termux:Boot entry (copied to `~/.termux/boot/`) |
| `termux/worker.env.example` | config reference |
| `termux/TERMUX.md` | this guide |
| `agent-host-platform/host-worker/deployments/termux_runtime.py` | the process backend |
| `agent-host-platform/host-worker/tests/test_termux_runtime.py` | backend unit tests |
