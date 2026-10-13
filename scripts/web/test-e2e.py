#!/usr/bin/env python3
"""真实隔离容器 → 浏览器 → 重启 → 加密恢复；仅操作本轮 UUID 资源。"""

import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import sqlite3
import ssl
import subprocess
import time
import urllib.request


def execute(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def wait_for_removal(container_id, timeout=30):
    """--rm 在 stop 返回后异步完成；以实际删除为重用端口／名称的屏障。"""
    deadline = time.monotonic() + timeout
    while True:
        remaining = subprocess.check_output(
            ["docker", "container", "ls", "-aq", "--no-trunc", "--filter", "id=" + container_id],
            text=True,
        ).strip()
        if not remaining:
            return
        if remaining != container_id:
            raise RuntimeError("unexpected container identity during removal")
        if time.monotonic() >= deadline:
            raise RuntimeError("owned container removal did not complete")
        time.sleep(0.1)


def main():
    if os.environ.get("CS_TEST_STACK") != "1" or os.environ.get("NOONMARK_PROFILE") != "e2e":
        raise RuntimeError("isolated e2e profile required")
    scope = os.environ.get("NOONMARK_E2E_SCOPE", "full")
    if scope not in {"full", "focus", "parity"}:
        raise RuntimeError("unknown E2E scope")
    source = Path(os.environ["NOONMARK_SOURCE_ROOT"])
    work = Path(os.environ["NOONMARK_WORK_ROOT"])
    run = Path(os.environ["NOONMARK_RUN_ROOT"])
    build = Path(os.environ["NOONMARK_E2E_BUILD_ROOT"])
    if build != build.resolve() or work / "builds" not in build.parents:
        raise RuntimeError("unmanaged image build")
    manifest = json.loads((build / "manifest.json").read_text())
    source_hash = subprocess.check_output(["python3", "-B", str(source / "scripts/web/workspace.py"), "hash"], text=True).strip()
    if manifest["source_hash"] != source_hash:
        raise RuntimeError("image source differs; rebuild before E2E")
    image = (build / "image.txt").read_text().strip()
    metadata = json.loads(subprocess.check_output(["docker", "image", "inspect", image]))[0]
    if metadata["Config"]["Labels"].get("app.noonmark.source-hash") != source_hash:
        raise RuntimeError("image label differs from source")
    if metadata["Config"].get("User") not in {"65532", "65532:65532"}:
        raise RuntimeError("image must default to non-root")

    options = json.loads(subprocess.check_output(["docker", "info", "--format", "{{json .SecurityOptions}}"], text=True))
    rootless = "name=rootless" in options
    # rootless UID 0 映射为宿主普通用户；rootful daemon 使用宿主非 root UID。
    if not rootless and os.getuid() == 0:
        raise RuntimeError("rootful E2E must run as an ordinary host user")
    user = "0:0" if rootless else f"{os.getuid()}:{os.getgid()}"
    password = secrets.token_urlsafe(24)
    passphrase = secrets.token_urlsafe(24)
    fixture = run / "objects/tls"
    fixture.mkdir(mode=0o700)
    execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
             "-keyout", str(fixture / "key.pem"), "-out", str(fixture / "cert.pem"),
             "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    origin = f"https://127.0.0.1:{port}"
    tls = ssl.create_default_context(cafile=str(fixture / "cert.pem"))
    name = "noonmark-e2e-" + os.environ["NOONMARK_RUN_ID"]
    network = name + "-network"
    base = ["docker", "run", "--rm", "--read-only", "--user", user, "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m,mode=1777",
            "--mount", f"type=bind,src={run / 'databases'},dst=/data"]
    execute(base + ["--network", "none", "-i", image, "init", "--data-dir", "/data/instance",
                    "--timezone", "Asia/Singapore", "--password-stdin"], input=(password + "\n").encode())
    execute(["docker", "network", "create", "--label", "app.noonmark.test-run=" + os.environ["NOONMARK_RUN_ID"], network], stdout=subprocess.DEVNULL)
    active = False
    container_id = None
    stages = []

    def start(dataset):
        nonlocal active, container_id
        result = execute(base + ["-d", "--name", name, "--network", network, "--no-healthcheck",
                       "--label", "app.noonmark.test-run=" + os.environ["NOONMARK_RUN_ID"],
                       "-p", f"127.0.0.1:{port}:8080", "--mount", f"type=bind,src={fixture},dst=/tls,readonly",
                       image, "serve", "--data-dir", "/data/" + dataset, "--listen", "0.0.0.0:8080",
                       "--public-origin", origin, "--tls-cert", "/tls/cert.pem", "--tls-key", "/tls/key.pem"], stdout=subprocess.PIPE, text=True)
        container_id = result.stdout.strip()
        active = True
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(origin + "/healthz", context=tls, timeout=2) as response:
                    if response.status == 200:
                        return
            except (OSError, urllib.error.URLError):
                time.sleep(0.2)
        raise RuntimeError("container did not become healthy")

    def stop(stage):
        nonlocal active
        if active:
            with (run / "logs" / (stage + ".log")).open("wb") as log:
                execute(["docker", "logs", container_id], stdout=log, stderr=subprocess.STDOUT)
            execute(["docker", "stop", "--time", "15", container_id], stdout=subprocess.DEVNULL)
            wait_for_removal(container_id)
            active = False

    def browser(spec, stage):
        environment = dict(os.environ, NOONMARK_E2E_URL=origin, NOONMARK_E2E_PASSWORD=password,
                           NOONMARK_E2E_BACKUP_PASSPHRASE=passphrase, NOONMARK_E2E_STAGE=stage,
                           TMPDIR=os.environ["NOONMARK_BROWSER_TMPDIR"])
        if not environment.get("CI") and shutil.which("chromium"):
            environment["NOONMARK_CHROMIUM_EXECUTABLE"] = shutil.which("chromium")
        execute([str(source / "apps/web/node_modules/.bin/playwright"), "test", spec], cwd=source / "apps/web", env=environment)
        stages.append(stage)

    def evidence(dataset):
        database = run / "databases" / dataset / "state.sqlite"
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
            if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("SQLite integrity failure")
            epoch, sequence = connection.execute("SELECT instance_epoch,sequence FROM instance_state WHERE id=1").fetchone()
            hashes, counts = {}, {}
            for table in ("days", "chains", "definitions", "traces", "subtasks", "ideas", "command_receipts", "change_batches"):
                rows = sorted(connection.execute("SELECT * FROM " + table).fetchall(), key=repr)
                counts[table] = len(rows)
                hashes[table] = hashlib.sha256(repr(rows).encode()).hexdigest()
            sessions = connection.execute("SELECT count(*) FROM sessions").fetchone()[0]
        return {"epoch": epoch, "sequence": sequence, "hashes": hashes, "counts": counts, "sessions": sessions}

    try:
        start("instance")
        if scope in {"focus", "parity"}:
            browser("native-ui.spec.ts" if scope == "parity" else "focus.spec.ts", scope)
            stop(scope)
            print("Real browser gate passed; evidence:", run / ("reports/playwright-" + scope + ".json"))
            return
        browser("self-hosted.spec.ts", "browser")
        stop("browser")
        original = evidence("instance")
        if original["counts"]["chains"] < 1 or original["counts"]["ideas"] < 1:
            raise RuntimeError("browser did not persist domain facts")
        start("instance")
        browser("recovery.spec.ts", "restart")
        stop("restart")
        after_restart = evidence("instance")
        if original["hashes"] != after_restart["hashes"]:
            raise RuntimeError("restart changed committed facts")
        exports = run / "reports/e2e-downloads"
        backup = exports / "instance.noonmarkbackup"
        if not backup.is_file() or backup.stat().st_size < 100:
            raise RuntimeError("real browser backup download missing")
        execute(base + ["--network", "none", "--mount", f"type=bind,src={exports},dst=/backup,readonly",
                        "-i", image, "restore", "--data-dir", "/data/restored", "--input", "/backup/instance.noonmarkbackup",
                        "--password-stdin"], input=(passphrase + "\n").encode())
        restored = evidence("restored")
        if original["hashes"] != restored["hashes"] or original["sequence"] != restored["sequence"]:
            raise RuntimeError("restored facts differ from browser backup")
        if original["epoch"] == restored["epoch"] or restored["sessions"] != 0:
            raise RuntimeError("restore did not fence prior sessions and commands")
        execute(base + ["--network", "none", image, "doctor", "--data-dir", "/data/restored"])
        start("restored")
        browser("recovery.spec.ts", "restored")
        stop("restored")
        stages.append("encrypted-restore-and-sqlite-reconciliation")
        report = {"status": "passed", "source_hash": source_hash, "image_id": metadata["Id"],
                  "stages": stages, "domain_counts": original["counts"], "sequence": original["sequence"],
                  "image_default_uid": 65532, "runtime_user": user, "rootless_daemon": rootless,
                  "production_app_executed": False}
        (run / "reports/e2e.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Container/browser/restart/restore gates passed; evidence:", run / "reports/e2e.json")
    finally:
        stop("final")
        execute(["docker", "network", "rm", network], stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
