"""Termux process backend: run apps as supervised native processes.

Docker does not exist on Android, so the ``termux`` manifest runtime skips
the image build entirely. The app is a supervised OS process:

  * argv comes from manifest ``service.command``, split with shlex —
    an argv list, NEVER a shell (policy §6 holds: shell=True appears
    nowhere in this codebase);
  * cwd is the extracted artifact dir (``<work_dir>/deployments/<id>/source``);
  * env is manifest env + the auto-injected ``PORT`` + task secrets
    (secrets live in the process env only — never in state.json);
  * stdout/stderr stream to ``<work_dir>/deployments/<id>/app.log``;
  * a per-deployment supervisor thread restarts the process on unexpected
    exit per the manifest ``restart`` policy and records restart timestamps
    in ``state["restart_log"]`` for deployments.crashloop;
  * the 120s HTTP-200 healthcheck gate (deploy rule #1) is identical to the
    docker path: the app must answer ``GET http://127.0.0.1:<port>/`` (or
    the manifest healthcheck path) with 200 inside the window.

Security posture — stated plainly, not buried: there is NO container
boundary here. The app runs as the same OS user as the worker, with the
same privileges. Treat ``runtime=termux`` deploys with exactly the trust
you place in the deploying agent itself. On a phone this is the
deploying agent's own code running on the owner's device — that is the
intended use, and the reason the backend exists.

Portability: nothing here is Android-specific beyond the absence of
Docker. The backend runs anywhere (it is exercised by the unit tests on
plain Linux); on Termux it is simply the only backend available.
"""
from __future__ import annotations

import logging
import os
import shlex
import signal
import subprocess
import threading
import time
from pathlib import Path

from health import checker as health_checker

LOG = logging.getLogger("agent-host-worker.termux")

# Longest accepted service.command (mirrors manifest.MAX_COMMAND_CHARS).
MAX_COMMAND_CHARS = 5000
# Seconds to wait for SIGTERM before SIGKILL on stop.
STOP_GRACE_SECS = 10
# Cap on restart timestamps kept per deployment for crash-loop accounting.
RESTART_LOG_CAP = 50
# How long the supervisor waits before restarting a crashed process, so a
# instantly-dying app does not hot-spin the CPU.
RESTART_COOLDOWN_SECS = 2


class TermuxError(Exception):
    """Fatal termux-backend failure; the dispatcher reports the task failed."""


def split_command(command: str) -> list[str]:
    """Split a manifest service.command into an argv list (no shell).

    Raises TermuxError on empty/unparseable input. shlex never invokes a
    shell: metacharacters (``;``, ``&&``, backticks, ``$()``) become literal
    argv elements, which is exactly why this is safe to run.
    """
    if not isinstance(command, str) or not command.strip():
        raise TermuxError("service.command must be a non-empty string")
    if len(command) > MAX_COMMAND_CHARS:
        raise TermuxError(
            f"service.command longer than {MAX_COMMAND_CHARS} characters; refusing")
    try:
        argv = shlex.split(command, posix=True)
    except ValueError as exc:
        raise TermuxError(f"service.command could not be parsed: {exc}") from exc
    if not argv:
        raise TermuxError("service.command parsed to an empty argv; refusing")
    if not argv[0]:
        raise TermuxError("service.command has an empty program name; refusing")
    return argv


def _proc_state(pid: int) -> str | None:
    """Single-letter state from /proc/<pid>/stat, or None if unreadable."""
    try:
        with open(f"/proc/{int(pid)}/stat", "r", encoding="utf-8") as fh:
            # comm may contain spaces/parens; the state is the token after
            # the last ")".
            stat = fh.read().rsplit(")", 1)[-1].split()
            return stat[0] if stat else None
    except (OSError, ValueError, IndexError):
        return None


def is_alive(pid: int) -> bool:
    """True if pid is a live (non-zombie) process. Never raises.

    A zombie (state Z) answers ``kill(pid, 0)`` successfully but is
    already dead — it must not count as alive, or stop/supervise loops
    would wait on a corpse forever. /proc is checked first (present on
    Linux and Android); the kill(pid, 0) probe is the fallback.
    """
    state = _proc_state(pid)
    if state is not None:
        return state != "Z"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by someone else
    except OSError:
        return False
    return True


def _pgid_of(pid: int) -> int | None:
    try:
        return os.getpgid(pid)
    except OSError:
        return None


def start_process(argv: list[str], cwd: str, env: dict,
                  log_path: str) -> subprocess.Popen:
    """Start the app detached in its own process group.

    ``start_new_session=True`` puts the app in a fresh session/process
    group so stop_process() can SIGTERM the whole group (the app plus any
    children it spawned) without touching the worker. stdout/stderr append
    to log_path.
    """
    if not argv:
        raise TermuxError("cannot start an empty argv")
    log_file = open(log_path, "a", encoding="utf-8", errors="replace")
    try:
        proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env={str(k): str(v) for k, v in env.items()},
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except Exception:
        log_file.close()
        raise
    # The child inherited the fd; the parent's copy can close — the file
    # stays open in the child.
    log_file.close()
    return proc


def stop_process(pid: int, timeout: int = STOP_GRACE_SECS) -> bool:
    """SIGTERM the process group, SIGKILL after ``timeout``. Never raises.

    Returns True when nothing with that pid remains afterwards.
    """
    pgid = _pgid_of(pid)
    if pgid is None:
        return True
    try:
        os.killpg(pgid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.monotonic() + max(1, timeout)
    while time.monotonic() < deadline:
        if not is_alive(pid):
            return True
        time.sleep(0.2)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        pass
    time.sleep(0.5)
    # Reap the zombie if it is our own child: a reaped-but-unwaited child
    # lingers as a zombie and would otherwise read as "still alive".
    try:
        os.waitpid(pid, os.WNOHANG)
    except (ChildProcessError, OSError):
        pass
    return not is_alive(pid)


def wait_healthy(host_port: int, path: str = "/",
                 timeout_secs: int = 120, interval_secs: int = 2,
                 log=None) -> bool:
    """Deploy rule #1: HTTP 200 on the healthcheck path within the window."""
    return health_checker.wait_for_healthcheck(
        int(host_port), path, timeout_secs=timeout_secs,
        interval_secs=interval_secs, log=log)


# ---------------------------------------------------------------------------
# Supervision
# ---------------------------------------------------------------------------

class Supervisor(threading.Thread):
    """Restart a deployment's process on unexpected exit.

    One supervisor per running deployment, tracked in the module-level
    registry so lifecycle handlers and boot reconciliation can find it.
    Restart timestamps are appended to ``state["restart_log"]`` (via the
    store) so deployments.crashloop can observe them exactly like docker
    restart counts.

    The supervisor stops when:
      * ``please_stop()`` is called (ordered stop/start/remove/redeploy), or
      * the manifest restart policy is ``no`` and the process exits.
    """

    def __init__(self, store, deployment_id: str, argv: list[str],
                 app_dir: str, env: dict, log_path: str,
                 restart_policy: str = "unless-stopped"):
        super().__init__(daemon=True,
                         name=f"termux-sup-{deployment_id[:8]}")
        self._store = store
        self._deployment_id = deployment_id
        self._argv = list(argv)
        self._app_dir = app_dir
        self._env = dict(env)
        self._log_path = log_path
        self._restart_policy = restart_policy or "unless-stopped"
        self._stop_event = threading.Event()
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()

    # -- introspection ----------------------------------------------------
    @property
    def pid(self) -> int | None:
        with self._lock:
            return self._proc.pid if self._proc is not None else None

    def alive(self) -> bool:
        pid = self.pid
        return pid is not None and is_alive(pid)

    def please_stop(self, timeout: int = STOP_GRACE_SECS) -> None:
        """Ordered stop: do not restart; terminate the current process."""
        self._stop_event.set()
        pid = self.pid
        if pid is not None:
            stop_process(pid, timeout=timeout)
        self.join(timeout=timeout + 5)

    # -- main loop ---------------------------------------------------------
    def run(self) -> None:
        while not self._stop_event.is_set():
            try:
                proc = start_process(self._argv, self._app_dir, self._env,
                                     self._log_path)
            except Exception as exc:
                LOG.error("supervisor %s: start failed: %s",
                          self._deployment_id[:8], exc)
                self._record_restart()
                if self._stop_event.wait(RESTART_COOLDOWN_SECS):
                    return
                continue
            with self._lock:
                self._proc = proc
            self._note_pid(proc.pid)
            rc = proc.wait()  # blocks until the app exits
            with self._lock:
                self._proc = None
            if self._stop_event.is_set():
                return  # ordered stop: stay down
            LOG.warning("supervisor %s: process exited rc=%s (policy=%s)",
                        self._deployment_id[:8], rc, self._restart_policy)
            self._record_restart()
            if self._restart_policy == "no":
                return
            if self._restart_policy == "on-failure" and rc == 0:
                return
            # "always" / "unless-stopped": cool down, then restart.
            if self._stop_event.wait(RESTART_COOLDOWN_SECS):
                return

    # -- bookkeeping --------------------------------------------------------
    def _note_pid(self, pid: int) -> None:
        try:
            state = self._store.load(self._deployment_id) or {}
            state["pid"] = pid
            state["last_start_ts"] = time.time()
            self._store.save(state)
        except Exception as exc:
            LOG.error("supervisor %s: could not persist pid: %s",
                      self._deployment_id[:8], exc)

    def _record_restart(self) -> None:
        try:
            state = self._store.load(self._deployment_id) or {}
            log = list(state.get("restart_log") or [])
            log.append(time.time())
            state["restart_log"] = log[-RESTART_LOG_CAP:]
            self._store.save(state)
        except Exception as exc:
            LOG.error("supervisor %s: could not record restart: %s",
                      self._deployment_id[:8], exc)


# Module-level registry: deployment_id -> Supervisor. Guards concurrent
# dispatches (spec §42) and lets handlers find the live supervisor without
# scanning threads.
_REGISTRY: dict[str, Supervisor] = {}
_REGISTRY_LOCK = threading.Lock()


def register_supervisor(deployment_id: str, supervisor: Supervisor) -> None:
    with _REGISTRY_LOCK:
        old = _REGISTRY.get(deployment_id)
        _REGISTRY[deployment_id] = supervisor
    if old is not None and old is not supervisor:
        try:
            old.please_stop()
        except Exception:
            pass


def get_supervisor(deployment_id: str) -> Supervisor | None:
    with _REGISTRY_LOCK:
        return _REGISTRY.get(deployment_id)


def drop_supervisor(deployment_id: str,
                    supervisor: Supervisor | None = None) -> None:
    with _REGISTRY_LOCK:
        cur = _REGISTRY.get(deployment_id)
        if cur is not None and (supervisor is None or cur is supervisor):
            del _REGISTRY[deployment_id]


def supervised_pid(deployment_id: str) -> int | None:
    sup = get_supervisor(deployment_id)
    return sup.pid if sup is not None else None


def ensure_supervised(store, state: dict, log=None) -> Supervisor:
    """Start (or adopt) supervision for a termux deployment from its state.

    Used by boot reconciliation and the start handler: rebuilds the argv,
    env (non-secret; secrets are never persisted — see had_secrets), app
    dir and restart policy from the stored state and registers a fresh
    supervisor. If the recorded pid is still alive (worker restarted but
    the app survived as an orphan), the old process is stopped first so
    exactly one instance runs under supervision.
    """
    deployment_id = state["deployment_id"]
    old_pid = state.get("pid")
    if old_pid and is_alive(int(old_pid)):
        # Adopt, don't duplicate: stop the orphan so the supervisor owns
        # the single instance from here on.
        if log:
            log(f"stopping orphaned process {old_pid} before supervising")
        stop_process(int(old_pid))
    argv = state.get("command")
    if not argv:
        argv = split_command(state.get("command_str", ""))
    app_dir = state.get("app_dir") or ""
    env = dict(state.get("env") or {})
    log_path = str(Path(store.root).parent / "deployments" /
                   deployment_id / "app.log")
    # Back-compat: states written before log_path existed.
    log_path = state.get("log_path") or log_path
    sup = Supervisor(
        store, deployment_id, argv, app_dir, env, log_path,
        restart_policy=state.get("restart") or "unless-stopped",
    )
    register_supervisor(deployment_id, sup)
    sup.start()
    return sup


def adopt_process(store, deployment_id: str, proc: subprocess.Popen,
                  argv: list[str], app_dir: str, env: dict, log_path: str,
                  restart_policy: str = "unless-stopped") -> Supervisor:
    """Put an already-running process under supervision.

    Used by the deploy pipeline right after the new process passes its
    healthcheck: the supervisor takes over the live Popen (no restart —
    the process is already healthy) and restarts it per policy only if it
    later exits unexpectedly.
    """
    old = get_supervisor(deployment_id)
    if old is not None:
        try:
            old.please_stop()
        except Exception:
            pass
    sup = Supervisor(store, deployment_id, list(argv), app_dir, dict(env),
                     log_path, restart_policy=restart_policy)
    with sup._lock:
        sup._proc = proc
    sup._note_pid(proc.pid)
    register_supervisor(deployment_id, sup)
    sup.start()
    return sup


def stop_supervised(deployment_id: str, timeout: int = STOP_GRACE_SECS) -> bool:
    """Ordered stop of a deployment's supervisor + process. Never raises."""
    sup = get_supervisor(deployment_id)
    if sup is None:
        return True
    try:
        sup.please_stop(timeout=timeout)
    except Exception as exc:
        LOG.error("stop_supervised %s: %s", deployment_id[:8], exc)
        return False
    finally:
        drop_supervisor(deployment_id, sup)
    return True
