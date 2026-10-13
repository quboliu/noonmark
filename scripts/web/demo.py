#!/usr/bin/env python3
"""一年领域重放、真实 Web 演示及浏览器验收；所有状态属于当前 demo run。"""

import getpass
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request


def roots():
    if os.environ.get("NOONMARK_PROFILE") != "demo":
        raise RuntimeError("DEMO_PROFILE_REQUIRED")
    source = Path(os.environ["NOONMARK_SOURCE_ROOT"])
    work = Path(os.environ["NOONMARK_WORK_ROOT"])
    run = Path(os.environ["NOONMARK_RUN_ROOT"])
    if run != run.resolve() or run != work / "runs/demo" / os.environ["NOONMARK_RUN_ID"]:
        raise RuntimeError("DEMO_RUN_INVALID")
    subprocess.run([str(source / "scripts/web/check-workspace")], check=True)
    return source, work, run


def verified_build(source, work):
    build = Path(os.environ["NOONMARK_DEMO_BUILD_ROOT"])
    if not build.is_absolute() or build != build.resolve() or work / "builds" not in build.parents:
        raise RuntimeError("DEMO_BUILD_UNMANAGED")
    manifest_path = build / "manifest.json"
    if manifest_path.is_symlink() or manifest_path.stat().st_uid != os.getuid():
        raise RuntimeError("DEMO_BUILD_MANIFEST_INVALID")
    manifest = json.loads(manifest_path.read_text())
    source_hash = subprocess.check_output(["python3", "-B", str(source / "scripts/web/workspace.py"), "hash"], text=True).strip()
    if manifest["source_hash"] != source_hash or source_hash != os.environ["NOONMARK_SOURCE_HASH"]:
        raise RuntimeError("DEMO_BUILD_SOURCE_CHANGED")
    artifacts = manifest.get("artifacts", {})
    if "bin/noonmark" not in artifacts or "web/index.html" not in artifacts:
        raise RuntimeError("DEMO_BUILD_INCOMPLETE")
    for name, digest in artifacts.items():
        relative = Path(name)
        path = build / relative
        if relative.is_absolute() or ".." in relative.parts or path.is_symlink() or path != path.resolve() or build not in path.parents:
            raise RuntimeError("DEMO_BUILD_ARTIFACT_INVALID")
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("DEMO_BUILD_ARTIFACT_CHANGED")
    for path in (build / "web").rglob("*"):
        if path.is_symlink() or path.is_file() and path.relative_to(build).as_posix() not in artifacts:
            raise RuntimeError("DEMO_BUILD_UNDECLARED_ASSET")
    if not os.access(build / "bin/noonmark", os.X_OK):
        raise RuntimeError("DEMO_BINARY_NOT_EXECUTABLE")
    return build, source_hash


def instance_evidence(data):
    with sqlite3.connect((data / "state.sqlite").as_uri() + "?mode=ro", uri=True) as connection:
        connection.execute("BEGIN")
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("DEMO_DATABASE_INTEGRITY_FAILED")
        instance_id, sequence = connection.execute("SELECT instance_id,sequence FROM instance_state WHERE id=1").fetchone()
        counts = {table: connection.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]
                  for table in ("chains", "traces", "subtasks", "ideas", "command_receipts", "change_batches")}
        locked = connection.execute("SELECT COUNT(*) FROM days WHERE locked_at!=''").fetchone()[0]
        if counts["change_batches"] != sequence or locked != 364:
            raise RuntimeError("DEMO_COMMIT_EVIDENCE_MISMATCH")
    return {"instance_id": instance_id, "sequence": sequence, "counts": counts, "locked_days": locked}


def write_report(path, report):
    with path.open("x", encoding="utf-8") as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write("\n")


def password_from_user(args):
    if args == ["--password-stdin"]:
        data = sys.stdin.buffer.readline(1027)
        if len(data) > 1026:
            raise RuntimeError("PASSWORD_INVALID")
        password = data.decode("utf-8").removesuffix("\n").removesuffix("\r")
    elif not args and sys.stdin.isatty():
        password = getpass.getpass("设置本轮演示密码（至少 12 个字符）：")
    else:
        raise RuntimeError("PASSWORD_STDIN_FLAG_REQUIRED")
    if len(password) < 12 or len(password.encode("utf-8")) > 1024:
        raise RuntimeError("PASSWORD_INVALID")
    return password


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in {"verify-build", "interactive", "test"}:
        raise RuntimeError("DEMO_COMMAND_INVALID")
    source, work, run = roots()
    build, source_hash = verified_build(source, work)
    if mode == "verify-build":
        return
    if mode == "test" and os.environ.get("CS_TEST_STACK") != "1":
        raise RuntimeError("ISOLATED_TEST_STACK_REQUIRED")
    password = secrets.token_urlsafe(24) if mode == "test" else password_from_user(sys.argv[2:])
    data = run / "databases/instance"
    executable = build / "bin/noonmark"
    print("正在通过真实领域命令重放一年记录；完成回读前不启动服务。", flush=True)
    result = subprocess.run([str(executable), "demo", "--data-dir", str(data), "--timezone",
                             os.environ.get("NOONMARK_OWNER_TIMEZONE", "Asia/Singapore"), "--password-stdin"],
                            input=(password + "\n").encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=360)
    if result.returncode != 0:
        # 二进制只输出 typed code；不复制可能被外部替换的任意 stderr 到报告。
        raise RuntimeError("DEMO_GENERATION_FAILED")
    report = json.loads(result.stdout)
    if report.get("status") != "ready" or not report.get("reopened") or report.get("days") != 365:
        raise RuntimeError("DEMO_NOT_READY")
    before = instance_evidence(data)
    if str(before["sequence"]) != report["sequence"]:
        raise RuntimeError("DEMO_REPORT_SEQUENCE_MISMATCH")
    write_report(run / "reports/demo.json", report)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    origin = f"http://127.0.0.1:{port}"
    server = None
    previous_term = signal.getsignal(signal.SIGTERM)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        with (run / "logs/demo-server.log").open("xb") as log:
            server = subprocess.Popen([str(executable), "serve", "--data-dir", str(data), "--web-dir", str(build / "web"),
                                       "--listen", f"127.0.0.1:{port}", "--public-origin", origin],
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 30
            while True:
                if server.poll() is not None:
                    raise RuntimeError("DEMO_SERVER_EXITED")
                try:
                    with urllib.request.urlopen(origin + "/healthz", timeout=2) as response:
                        if response.status == 200:
                            break
                except (OSError, urllib.error.URLError):
                    if time.monotonic() >= deadline:
                        raise RuntimeError("DEMO_SERVER_NOT_READY")
                    time.sleep(0.2)
            if mode == "interactive":
                print("一年演示已就绪：" + origin, flush=True)
                print("使用刚才设置的密码登录；按 Ctrl-C 停止本轮服务。", flush=True)
                if server.wait() != 0:
                    raise RuntimeError("DEMO_SERVER_EXITED")
            else:
                environment = dict(os.environ, NOONMARK_E2E_URL=origin, NOONMARK_E2E_PASSWORD=password,
                                   NOONMARK_E2E_BACKUP_PASSPHRASE=secrets.token_urlsafe(24),
                                   NOONMARK_E2E_STAGE="demo", NOONMARK_DEMO_INSTANCE_ID=before["instance_id"])
                environment["TMPDIR"] = os.environ["NOONMARK_BROWSER_TMPDIR"]
                if not environment.get("CI") and shutil.which("chromium"):
                    environment["NOONMARK_CHROMIUM_EXECUTABLE"] = shutil.which("chromium")
                subprocess.run([str(source / "apps/web/node_modules/.bin/playwright"), "test", "demo.spec.ts"],
                               cwd=source / "apps/web", env=environment, check=True, timeout=300)
                after = instance_evidence(data)
                if after["sequence"] <= before["sequence"] or after["counts"]["chains"] <= before["counts"]["chains"]:
                    raise RuntimeError("DEMO_BROWSER_DID_NOT_COMMIT")
                write_report(run / "reports/demo-browser.json", {"status":"passed", "source_hash":source_hash,
                             "year_days":365, "initial_sequence":before["sequence"], "final_sequence":after["sequence"],
                             "counts":after["counts"], "locked_days":after["locked_days"], "production_app_executed":False})
                print("一年演示的真实浏览器与 SQLite 回读门禁通过。", flush=True)
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("本轮演示已停止。", file=sys.stderr)
        sys.exit(130)
