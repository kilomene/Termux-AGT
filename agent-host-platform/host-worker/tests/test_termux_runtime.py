"""Tests for the termux process backend (Termux-AGT, Android phone hosts).

Covers: manifest validation for runtime=termux, command splitting (argv,
never a shell), process start/stop/liveness, the HTTP-200 healthcheck
gate, supervisor restart semantics, crash-loop flagging, boot
reconciliation, and the deploy-pipeline backend gating.

Nothing here is Android-specific: the backend is portable and the tests
run on plain Linux.
"""
import json
import os
import sys
import threading
import time
from pathlib import Path

import pytest

from deployments import termux_runtime
from deployments import crashloop as crashloop_mod
from deployments import manifest as manifest_mod
from deployments import pipeline as pipeline_mod
from deployments import reconcile as reconcile_mod
from deployments.state import DeploymentStore

# A tiny app that reads $PORT and answers 200 on /health (anything else 404).
APP_PY = """\
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(os.environ.get("PORT", "18099"))

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", port), H).serve_forever()
"""


@pytest.fixture()
def workdir(tmp_path):
    (tmp_path / "deployments").mkdir()
    return tmp_path


@pytest.fixture()
def store(workdir):
    return DeploymentStore(str(workdir))


@pytest.fixture()
def appdir(tmp_path):
    d = tmp_path / "app"
    d.mkdir()
    (d / "app.py").write_text(APP_PY)
    return str(d)


def _free_port() -> int:
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# ---------------------------------------------------------------------------
# manifest validation
# ---------------------------------------------------------------------------

class TestTermuxManifest:
    def test_termux_valid_with_command(self):
        ok, errs = manifest_mod.validate_manifest(
            {"name": "p", "runtime": "termux",
             "service": {"command": "python app.py", "port": 8000,
                         "healthcheck": "/health"}})
        assert ok, errs

    def test_termux_requires_command(self):
        ok, errs = manifest_mod.validate_manifest(
            {"name": "p", "runtime": "termux", "service": {"port": 8000}})
        assert not ok
        assert any("service.command" in e for e in errs)

    def test_termux_rejects_blank_command(self):
        ok, errs = manifest_mod.validate_manifest(
            {"name": "p", "runtime": "termux",
             "service": {"command": "   "}})
        assert not ok

    def test_termux_rejects_gigantic_command(self):
        ok, errs = manifest_mod.validate_manifest(
            {"name": "p", "runtime": "termux",
             "service": {"command": "x" * (manifest_mod.MAX_COMMAND_CHARS + 1)}})
        assert not ok

    def test_docker_runtimes_still_validate(self):
        for runtime in ("docker", "docker-compose", "static"):
            ok, errs = manifest_mod.validate_manifest(
                {"name": "p", "runtime": runtime})
            assert ok, (runtime, errs)

    def test_unknown_runtime_rejected(self):
        ok, errs = manifest_mod.validate_manifest(
            {"name": "p", "runtime": "lxc"})
        assert not ok


# ---------------------------------------------------------------------------
# command splitting — argv, never a shell
# ---------------------------------------------------------------------------

class TestSplitCommand:
    def test_simple(self):
        assert termux_runtime.split_command("python app.py") == ["python", "app.py"]

    def test_quoted_args(self):
        assert termux_runtime.split_command('python -c "print(1)"') == [
            "python", "-c", "print(1)"]

    def test_shell_metachars_stay_literal(self):
        # The whole point: no shell is ever invoked, so these are inert argv.
        argv = termux_runtime.split_command("python app.py; rm -rf /")
        assert argv == ["python", "app.py;", "rm", "-rf", "/"]

    def test_empty_rejected(self):
        with pytest.raises(termux_runtime.TermuxError):
            termux_runtime.split_command("   ")

    def test_too_long_rejected(self):
        with pytest.raises(termux_runtime.TermuxError):
            termux_runtime.split_command("x" * (termux_runtime.MAX_COMMAND_CHARS + 1))


# ---------------------------------------------------------------------------
# process lifecycle
# ---------------------------------------------------------------------------

class TestProcessLifecycle:
    def test_start_stop_is_alive(self, tmp_path, appdir):
        log = str(tmp_path / "app.log")
        proc = termux_runtime.start_process(
            [sys.executable, "app.py"], appdir, {"PORT": "18091"}, log)
        try:
            assert termux_runtime.is_alive(proc.pid)
        finally:
            assert termux_runtime.stop_process(proc.pid) is True
            assert not termux_runtime.is_alive(proc.pid)

    def test_stop_process_dead_pid(self):
        assert termux_runtime.stop_process(999999999) is True

    def test_is_alive_dead_pid(self):
        assert termux_runtime.is_alive(999999999) is False

    def test_wait_healthy_true(self, tmp_path, appdir):
        port = _free_port()
        log = str(tmp_path / "app.log")
        proc = termux_runtime.start_process(
            [sys.executable, "app.py"], appdir, {"PORT": str(port)}, log)
        try:
            assert termux_runtime.wait_healthy(port, "/health",
                                               timeout_secs=15) is True
        finally:
            termux_runtime.stop_process(proc.pid)

    def test_wait_healthy_wrong_path_false(self, tmp_path, appdir):
        port = _free_port()
        log = str(tmp_path / "app.log")
        proc = termux_runtime.start_process(
            [sys.executable, "app.py"], appdir, {"PORT": str(port)}, log)
        try:
            # /nope answers 404; the gate requires 200.
            assert termux_runtime.wait_healthy(port, "/nope",
                                               timeout_secs=4,
                                               interval_secs=1) is False
        finally:
            termux_runtime.stop_process(proc.pid)

    def test_wait_healthy_closed_port_false(self):
        assert termux_runtime.wait_healthy(_free_port(), "/",
                                           timeout_secs=3,
                                           interval_secs=1) is False

    def test_stdout_goes_to_log(self, tmp_path):
        log = str(tmp_path / "app.log")
        proc = termux_runtime.start_process(
            [sys.executable, "-c", "print('hello-log-line')"],
            str(tmp_path), {}, log)
        proc.wait(timeout=10)
        termux_runtime.stop_process(proc.pid)
        assert "hello-log-line" in Path(log).read_text()


# ---------------------------------------------------------------------------
# supervision
# ---------------------------------------------------------------------------

class TestSupervisor:
    def test_no_restart_policy_stays_down(self, tmp_path, store):
        did = "test-no-restart"
        store.save({"deployment_id": did, "status": "running"})
        sup = termux_runtime.Supervisor(
            store, did, [sys.executable, "-c", "import sys; sys.exit(3)"],
            str(tmp_path), {}, str(tmp_path / "app.log"),
            restart_policy="no")
        termux_runtime.register_supervisor(did, sup)
        try:
            sup.start()
            sup.join(timeout=15)
            assert not sup.is_alive()
            state = store.load(did)
            assert len(state.get("restart_log") or []) >= 1
        finally:
            termux_runtime.drop_supervisor(did, sup)

    def test_always_restart_policy_restarts(self, tmp_path, store):
        did = "test-always-restart"
        store.save({"deployment_id": did, "status": "running"})
        sup = termux_runtime.Supervisor(
            store, did, [sys.executable, "-c", "import sys; sys.exit(1)"],
            str(tmp_path), {}, str(tmp_path / "app.log"),
            restart_policy="always")
        termux_runtime.register_supervisor(did, sup)
        try:
            sup.start()
            deadline = time.time() + 15
            while time.time() < deadline:
                state = store.load(did) or {}
                if len(state.get("restart_log") or []) >= 3:
                    break
                time.sleep(0.2)
            state = store.load(did)
            assert len(state.get("restart_log") or []) >= 3
        finally:
            sup.please_stop(timeout=5)
            termux_runtime.drop_supervisor(did, sup)

    def test_adopt_process_takes_over_live_process(self, tmp_path, store,
                                                   appdir):
        did = "test-adopt"
        port = _free_port()
        log = str(tmp_path / "app.log")
        proc = termux_runtime.start_process(
            [sys.executable, "app.py"], appdir, {"PORT": str(port)}, log)
        store.save({"deployment_id": did, "status": "running"})
        try:
            assert termux_runtime.wait_healthy(port, "/health",
                                               timeout_secs=15)
            sup = termux_runtime.adopt_process(
                store, did, proc, [sys.executable, "app.py"], appdir,
                {"PORT": str(port)}, log, "unless-stopped")
            try:
                assert sup.alive()
                assert termux_runtime.get_supervisor(did) is sup
                assert store.load(did)["pid"] == proc.pid
            finally:
                sup.please_stop(timeout=5)
                termux_runtime.drop_supervisor(did, sup)
        finally:
            termux_runtime.stop_process(proc.pid)

    def test_ensure_supervised_starts_dead_deployment(self, tmp_path, store,
                                                      appdir):
        did = "test-ensure"
        port = _free_port()
        state = {
            "deployment_id": did,
            "status": "running",
            "command": [sys.executable, "app.py"],
            "command_str": "python app.py",
            "app_dir": appdir,
            "env": {"PORT": str(port)},
            "log_path": str(tmp_path / "app.log"),
            "restart": "unless-stopped",
            "host_port": port,
            "healthcheck_path": "/health",
        }
        store.save(state)
        sup = termux_runtime.ensure_supervised(store, state)
        try:
            assert termux_runtime.wait_healthy(port, "/health",
                                               timeout_secs=15)
            assert sup.alive()
        finally:
            sup.please_stop(timeout=5)
            termux_runtime.drop_supervisor(did, sup)


# ---------------------------------------------------------------------------
# crash-loop detection on restart_log
# ---------------------------------------------------------------------------

class FakeCtx:
    def __init__(self, store, docker=None):
        self.deployment_store = store
        self.docker = docker


class TestCrashLoop:
    def test_flags_after_threshold(self, store):
        did = "test-crashloop"
        now = time.time()
        store.save({
            "deployment_id": did, "project_name": "p",
            "runtime": "termux", "status": "running",
            "restart_log": [now - 10, now - 20, now - 30, now - 40, now - 50],
        })
        issues = crashloop_mod.evaluate(
            FakeCtx(store), threshold=5, window_s=300)
        state = store.load(did)
        assert state["crash_loop"] is True
        assert state["status"] == "crash_loop"
        assert any(i.get("deployment_id") == did for i in issues)

    def test_below_threshold_no_flag(self, store):
        did = "test-no-crashloop"
        now = time.time()
        store.save({
            "deployment_id": did, "project_name": "p",
            "runtime": "termux", "status": "running",
            "restart_log": [now - 10, now - 20],
        })
        issues = crashloop_mod.evaluate(
            FakeCtx(store), threshold=5, window_s=300)
        assert store.load(did).get("crash_loop") is not True
        assert issues == []

    def test_stale_restarts_ignored(self, store):
        did = "test-stale"
        now = time.time()
        store.save({
            "deployment_id": did, "project_name": "p",
            "runtime": "termux", "status": "running",
            # 5 restarts, but all outside the 300s window
            "restart_log": [now - 400, now - 500, now - 600, now - 700,
                            now - 800],
        })
        issues = crashloop_mod.evaluate(
            FakeCtx(store), threshold=5, window_s=300)
        assert store.load(did).get("crash_loop") is not True
        assert issues == []


# ---------------------------------------------------------------------------
# boot reconciliation
# ---------------------------------------------------------------------------

class TestReconcile:
    def test_restarts_dead_termux_deployment(self, store, appdir, tmp_path):
        did = "test-reconcile-restart"
        port = _free_port()
        store.save({
            "deployment_id": did, "project_name": "p",
            "runtime": "termux", "status": "running",
            "command": [sys.executable, "app.py"],
            "command_str": "python app.py",
            "app_dir": appdir,
            "env": {"PORT": str(port)},
            "log_path": str(tmp_path / "app.log"),
            "restart": "unless-stopped",
            "host_port": port,
            "healthcheck_path": "/health",
            "pid": 999999999,  # dead
        })
        try:
            summary = reconcile_mod.reconcile(FakeCtx(store))
            assert summary["reconciled"] == 1
            assert termux_runtime.wait_healthy(port, "/health",
                                               timeout_secs=15)
        finally:
            termux_runtime.stop_supervised(did)

    def test_secrets_deployment_marked_degraded(self, store, appdir,
                                                tmp_path):
        did = "test-reconcile-degraded"
        store.save({
            "deployment_id": did, "project_name": "p",
            "runtime": "termux", "status": "running",
            "command": [sys.executable, "app.py"],
            "app_dir": appdir, "env": {},
            "had_secrets": True,
            "pid": 999999999,
        })
        summary = reconcile_mod.reconcile(FakeCtx(store))
        state = store.load(did)
        assert state["status"] == "degraded"
        assert termux_runtime.get_supervisor(did) is None
        assert summary["missing"] == 1


# ---------------------------------------------------------------------------
# end-to-end: full deploy() through the termux backend
# ---------------------------------------------------------------------------

class FakeE2EApi:
    """Serves one tarball artifact; no project secrets."""
    def __init__(self, tarball: str):
        self._tarball = tarball

    def download_artifact(self, artifact_id, dest_path, expected_size=None):
        import shutil
        shutil.copyfile(self._tarball, dest_path)
        return dest_path


def _make_tarball(appdir: str, dest: str) -> str:
    import hashlib
    import tarfile
    with tarfile.open(dest, "w:gz") as tf:
        tf.add(os.path.join(appdir, "app.py"), arcname="app.py")
    h = hashlib.sha256()
    with open(dest, "rb") as fh:
        h.update(fh.read())
    return "sha256:" + h.hexdigest()


class TestEndToEndDeploy:
    def test_full_deploy_lifecycle(self, tmp_path, store, appdir):
        from executor import handlers
        tarball = str(tmp_path / "artifact.tar.gz")
        checksum = _make_tarball(appdir, tarball)
        workdir = str(tmp_path / "work")
        os.makedirs(workdir)
        e2e_store = DeploymentStore(workdir)
        ctx = FakePipelineCtx(e2e_store, workdir, termux=True)
        ctx.api = FakeE2EApi(tarball)

        task = {
            "id": "task-e2e",
            "type": "deploy",
            "payload": {
                "project_id": "proj-e2e",
                "project_name": "e2e-app",
                "version": "1.0.0",
                "deployment_id": "dep-e2e-1",
                "artifact_id": "art-e2e-1",
                "artifact_checksum": checksum,
                "manifest": {
                    "name": "e2e-app",
                    "runtime": "termux",
                    "service": {"command": f"{sys.executable} app.py",
                                "healthcheck": "/health"},
                    "restart": "unless-stopped",
                },
            },
        }
        result = pipeline_mod.deploy(ctx, task)
        assert result["status"] == "running"
        assert result["health_status"] == "healthy"
        port = int(list(result["ports"])[0])

        try:
            # The app really answers on the deployed port.
            assert termux_runtime.wait_healthy(port, "/health",
                                               timeout_secs=10)
            state = e2e_store.load("dep-e2e-1")
            assert state["runtime"] == "termux"
            assert state["status"] == "running"
            assert termux_runtime.is_alive(int(state["pid"]))

            # logs handler tails app.log
            logs = handlers.handle_logs(
                ctx, {"id": "t", "payload": {"deployment_id": "dep-e2e-1"}})
            assert isinstance(logs["logs"], str)

            # status handler sees a live process
            st = handlers.handle_status(
                ctx, {"id": "t", "payload": {"deployment_id": "dep-e2e-1"}})
            assert st["process_alive"] is True

            # stop / start cycle
            handlers.handle_stop(
                ctx, {"id": "t", "payload": {"deployment_id": "dep-e2e-1"}})
            assert e2e_store.load("dep-e2e-1")["status"] == "stopped"
            handlers.handle_start(
                ctx, {"id": "t", "payload": {"deployment_id": "dep-e2e-1"}})
            assert e2e_store.load("dep-e2e-1")["status"] == "running"
            assert termux_runtime.wait_healthy(port, "/health",
                                               timeout_secs=15)

            # remove
            handlers.handle_remove(
                ctx, {"id": "t", "payload": {"deployment_id": "dep-e2e-1"}})
            assert e2e_store.load("dep-e2e-1")["status"] == "removed"
        finally:
            termux_runtime.stop_supervised("dep-e2e-1")

    def test_failed_healthcheck_keeps_previous_serving(self, tmp_path, store,
                                                       appdir):
        from executor import handlers
        tarball = str(tmp_path / "artifact.tar.gz")
        checksum = _make_tarball(appdir, tarball)
        workdir = str(tmp_path / "work")
        os.makedirs(workdir)
        e2e_store = DeploymentStore(workdir)
        ctx = FakePipelineCtx(e2e_store, workdir, termux=True)
        ctx.api = FakeE2EApi(tarball)

        def deploy_task(dep_id, command):
            return {
                "id": "task-" + dep_id,
                "type": "deploy",
                "payload": {
                    "project_id": "proj-rb",
                    "project_name": "rb-app",
                    "version": "1.0.0",
                    "deployment_id": dep_id,
                    "artifact_id": "art-rb-1",
                    "artifact_checksum": checksum,
                    "manifest": {
                        "name": "rb-app",
                        "runtime": "termux",
                        "service": {"command": command,
                                    "healthcheck": "/health"},
                    },
                    "healthcheck_timeout": 6,
                },
            }

        # good generation first
        r1 = pipeline_mod.deploy(
            ctx, deploy_task("dep-rb-1", f"{sys.executable} app.py"))
        assert r1["status"] == "running"
        port1 = int(list(r1["ports"])[0])
        try:
            # bad generation: exits immediately, never healthy
            with pytest.raises(pipeline_mod.DeployError):
                pipeline_mod.deploy(
                    ctx, deploy_task(
                        "dep-rb-2",
                        f"{sys.executable} -c 'import sys; sys.exit(1)'"))
            # previous generation still serving
            assert termux_runtime.wait_healthy(port1, "/health",
                                               timeout_secs=10)
            assert e2e_store.load("dep-rb-1")["status"] == "running"
            assert e2e_store.load("dep-rb-2")["status"] == "failed"
        finally:
            termux_runtime.stop_supervised("dep-rb-1")
            termux_runtime.stop_supervised("dep-rb-2")


# ---------------------------------------------------------------------------
# deploy-pipeline backend gating
# ---------------------------------------------------------------------------

class FakeConfig:
    def __init__(self, work_dir, termux=True):
        self.work_dir = work_dir
        self.apps_dir = os.path.join(work_dir, "apps")
        self.termux = termux
        self.host_name = "test-phone"
        self.host_token = "tok"
        self.host_id = "hid"
        self.control_plane_url = "https://example.invalid"
        self.capabilities = ["termux"]


class FakeLogStore:
    def append_deployment(self, deployment_id, line):
        pass


class FakeApi:
    pass


class FakePipelineCtx:
    def __init__(self, store, work_dir, termux=True):
        self.deployment_store = store
        self.config = FakeConfig(work_dir, termux=termux)
        self.log_store = FakeLogStore()
        self.api = FakeApi()
        self.docker = None
        self.scrub = lambda text: text  # dispatcher installs the real one
        self._lines = []

    def log(self, task_id, line):
        self._lines.append(line)


def _deploy_task(manifest):
    return {
        "id": "task-1",
        "type": "deploy",
        "payload": {
            "project_id": "proj-1",
            "project_name": "p",
            "version": "1",
            "deployment_id": "dep-gate-1",
            "manifest": manifest,
        },
    }


class TestPipelineGating:
    def test_termux_host_rejects_docker_runtime(self, store, tmp_path):
        ctx = FakePipelineCtx(store, str(tmp_path), termux=True)
        task = _deploy_task({"name": "p", "runtime": "docker"})
        with pytest.raises(pipeline_mod.DeployError) as exc:
            pipeline_mod.deploy(ctx, task)
        assert "termux" in str(exc.value).lower()

    def test_non_termux_host_rejects_termux_runtime(self, store, tmp_path):
        ctx = FakePipelineCtx(store, str(tmp_path), termux=False)
        task = _deploy_task({
            "name": "p", "runtime": "termux",
            "service": {"command": "python app.py"}})
        with pytest.raises(pipeline_mod.DeployError) as exc:
            pipeline_mod.deploy(ctx, task)
        assert "termux-backend host" in str(exc.value)

    def test_termux_host_rejects_compose_runtime(self, store, tmp_path):
        ctx = FakePipelineCtx(store, str(tmp_path), termux=True)
        task = _deploy_task({"name": "p", "runtime": "docker-compose"})
        with pytest.raises(pipeline_mod.DeployError):
            pipeline_mod.deploy(ctx, task)
