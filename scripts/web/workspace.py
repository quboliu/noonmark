#!/usr/bin/env python3
"""外置构建根、独占运行目录及源码产物守卫。"""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import uuid

REPO = Path(__file__).resolve().parents[2]
DEFAULT_WORK_ROOT = Path("/share/broker/noonmark-build")
PROFILES = {"development", "e2e", "demo", "audit", "release-validation"}
ARTIFACT_DIRS = {"node_modules", ".vite", "dist", "coverage", "playwright-report", "test-results", ".build", ".swiftpm", "DerivedData", "artifacts", "__pycache__"}
BROWSER_TMP_MAX_BYTES = 48


def fail(message):
    raise RuntimeError(message)


def private_dir(path):
    if any(item.is_symlink() for item in [path, *path.parents]):
        fail("external directory is a symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        fail("external directory is not owned by the current user")
    if stat.S_IMODE(info.st_mode) & 0o077:
        fail("external directory requires mode 0700")


def root():
    link = REPO / ".work"
    raw = os.environ.get("NOONMARK_WORK_ROOT")
    if not raw:
        raw = str(DEFAULT_WORK_ROOT)
    path = Path(raw)
    if not path.is_absolute() or path != path.resolve():
        fail("NOONMARK_WORK_ROOT must be an absolute canonical path")
    if path == REPO or path in REPO.parents or REPO in path.parents:
        fail("source checkout and external root overlap")
    if path == Path.home() or len(path.parts) < 4:
        fail("external root must be a dedicated project directory")
    if link.is_symlink():
        if link.resolve() != path:
            fail(".work points to a different external root")
    elif link.exists():
        fail(".work must be a symlink, never a real directory")
    private_dir(path)
    if not link.is_symlink():
        link.symlink_to(path, target_is_directory=True)
    return path


def source_hash():
    names = subprocess.check_output(["git", "-C", str(REPO), "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).split(b"\0")
    digest = hashlib.sha256()
    for name in sorted(set(names)):
        if not name:
            continue
        path = REPO / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(path.read_bytes())
        else:
            digest.update(b"deleted")
        digest.update(b"\0")
    return digest.hexdigest()


def check(work):
    for base, directories, files in os.walk(REPO, followlinks=False):
        parent = Path(base)
        if parent == REPO:
            directories[:] = [name for name in directories if name not in {".git", ".work"}]
        for name in list(directories):
            path = parent / name
            if name == "node_modules" and path.is_symlink() and path == REPO / "apps/web/node_modules":
                target = path.resolve()
                if not target.is_dir() or work / "deps/npm" not in target.parents or target.name != "node_modules":
                    fail("node_modules link is outside the managed dependency sandbox")
                directories.remove(name)
            elif name in ARTIFACT_DIRS:
                fail("generated directory in source checkout: " + str(path.relative_to(REPO)))
        for name in files:
            if name.endswith((".db", ".db-wal", ".db-shm", ".sqlite", ".sqlite3", ".tsbuildinfo", ".pyc")):
                fail("generated file in source checkout: " + str((parent / name).relative_to(REPO)))


def check_environment(work):
    if not os.environ.get("NOONMARK_RUN_ROOT"):
        return
    path_keys = ["NOONMARK_RUN_ROOT", "NOONMARK_BUILD_ROOT", "GOCACHE", "GOMODCACHE", "GOPATH", "GOBIN", "GOTMPDIR", "TMPDIR",
                 "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "DOCKER_CONFIG", "npm_config_cache", "PLAYWRIGHT_BROWSERS_PATH",
                 "NOONMARK_WEB_DIST", "NOONMARK_VITE_CACHE", "NOONMARK_TSBUILDINFO", "NOONMARK_BROWSER_TMPDIR"]
    for key in path_keys:
        path = Path(os.environ.get(key, ""))
        if not path.is_absolute() or path != path.resolve() or work not in path.parents:
            fail(key + " is not a canonical output path below the external root")
    run = Path(os.environ["NOONMARK_RUN_ROOT"])
    manifest_path = run / "ownership.json"
    if manifest_path.is_symlink():
        fail("ownership manifest must not be a symlink")
    manifest = json.loads(manifest_path.read_text())
    profile, run_id = manifest["profile"], manifest["run_id"]
    if profile not in PROFILES or str(uuid.UUID(run_id)) != run_id or run != work / "runs" / profile / run_id:
        fail("runtime ownership identity does not match its directory")
    if manifest["owner_uid"] != os.getuid() or run.stat().st_uid != os.getuid() or stat.S_IMODE(run.stat().st_mode) != 0o700:
        fail("runtime ownership or permissions do not match")
    if os.environ.get("NOONMARK_PROFILE") != profile or os.environ.get("NOONMARK_RUN_ID") != run_id:
        fail("runtime environment identity differs from its manifest")
    if os.environ.get("NOONMARK_SOURCE_HASH") != manifest["source_hash"]:
        fail("runtime source hash differs from its manifest")
    if Path(os.environ["NOONMARK_BUILD_ROOT"]) != work / "builds" / manifest["source_hash"] / run_id:
        fail("build root differs from the owned run")
    if any(Path(os.environ[key]) != run / "tmp" for key in ["TMPDIR", "GOTMPDIR"]):
        fail("temporary directory differs from the owned run")
    if os.environ.get("GOENV") != "off" or os.environ.get("GOTOOLCHAIN") != "local":
        fail("Go configuration must use the pinned local toolchain")
    check_browser_temp(work, Path(os.environ["NOONMARK_BROWSER_TMPDIR"]), manifest)


def allocate_browser_temp(work, manifest):
    # Chromium 在 TMPDIR 内创建 AF_UNIX SingletonSocket；完整 run 路径超过 sun_path 上限。
    browser_tmp = work / "t" / uuid.uuid4().hex[:8]
    if len(os.fsencode(browser_tmp)) > BROWSER_TMP_MAX_BYTES:
        fail("external root is too long for browser sockets; choose a shorter canonical NOONMARK_WORK_ROOT")
    private_dir(work / "t")
    browser_tmp.mkdir(mode=0o700, exist_ok=False)
    ownership = dict(manifest, purpose="browser_tmp", browser_tmp_id=browser_tmp.name)
    with (browser_tmp / "ownership.json").open("x", encoding="utf-8") as output:
        json.dump(ownership, output, indent=2)
        output.write("\n")
    return browser_tmp


def check_browser_temp(work, browser_tmp, manifest):
    if (browser_tmp != browser_tmp.resolve() or browser_tmp.parent != work / "t"
            or not re.fullmatch("[0-9a-f]{8}", browser_tmp.name)
            or len(os.fsencode(browser_tmp)) > BROWSER_TMP_MAX_BYTES):
        fail("browser temporary directory is unmanaged or too long")
    info = browser_tmp.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        fail("browser temporary directory ownership or permissions differ")
    ownership_file = browser_tmp / "ownership.json"
    if ownership_file.is_symlink():
        fail("browser ownership manifest must not be a symlink")
    ownership = json.loads(ownership_file.read_text())
    if ownership.get("purpose") != "browser_tmp" or ownership.get("browser_tmp_id") != browser_tmp.name:
        fail("browser temporary directory manifest identity differs")
    if manifest.get("browser_tmp_id") != browser_tmp.name:
        fail("browser temporary directory is not assigned to this run")
    for key in ["profile", "run_id", "source_hash", "owner_uid"]:
        if ownership.get(key) != manifest[key]:
            fail("browser temporary directory is owned by another run")


def initialize(profile):
    if profile not in PROFILES:
        fail("unknown or forbidden web profile")
    work = root()
    check(work)
    for subdir in ["cache", "deps", "builds", "runs", "demo", "config", "cache/xdg", "config/xdg"]:
        private_dir(work / subdir)
    # Go telemetry uses the platform config directory; never mutate the user's setting.
    config = work / "config/xdg"
    telemetry = config / "go/telemetry"
    private_dir(telemetry)
    mode = telemetry / "mode"
    if mode.is_symlink():
        fail("telemetry mode must not be a symlink")
    mode.write_text("off\n", encoding="utf-8")
    tool_env = dict(os.environ, XDG_CONFIG_HOME=str(config), GOENV="off", GOTOOLCHAIN="local")
    goversion = subprocess.check_output(["go", "env", "GOVERSION"], env=tool_env, text=True).strip()
    nodeversion = subprocess.check_output(["node", "--version"], text=True).strip()
    toolchain = goversion + "-" + platform.system().lower() + "-" + platform.machine()
    run_id = str(uuid.uuid4())
    source = source_hash()
    lockfile = REPO / "apps/web/package-lock.json"
    web_lock_hash = hashlib.sha256(lockfile.read_bytes()).hexdigest() if lockfile.exists() else "unresolved"
    private_dir(work / "runs" / profile)
    run = work / "runs" / profile / run_id
    run.mkdir(mode=0o700, exist_ok=False)
    build_parent = work / "builds" / source
    private_dir(build_parent)
    build = build_parent / run_id
    build.mkdir(mode=0o700, exist_ok=False)
    for subdir in ["tmp", "databases", "objects", "browser", "logs", "reports", "coverage", "exports"]:
        private_dir(run / subdir)
    values = {
        "NOONMARK_SOURCE_ROOT": str(REPO), "NOONMARK_WORK_ROOT": str(work),
        "NOONMARK_RUN_ROOT": str(run), "NOONMARK_BUILD_ROOT": str(build),
        "NOONMARK_RUN_ID": run_id, "NOONMARK_PROFILE": profile, "NOONMARK_SOURCE_HASH": source,
        "GOCACHE": str(work / "cache/go" / toolchain), "GOMODCACHE": str(work / "deps/go" / toolchain),
        "GOPATH": str(work / "deps/gopath" / toolchain), "GOBIN": str(work / "deps/bin" / toolchain),
        "GOTMPDIR": str(run / "tmp"), "TMPDIR": str(run / "tmp"),
        "XDG_CONFIG_HOME": str(config), "XDG_CACHE_HOME": str(work / "cache/xdg"),
        "DOCKER_CONFIG": str(work / "config/docker"),
        "GOENV": "off", "GOTOOLCHAIN": "local", "PYTHONDONTWRITEBYTECODE": "1",
        "npm_config_cache": str(work / "cache/npm" / nodeversion), "npm_config_update_notifier": "false",
        "npm_config_audit": "false", "npm_config_fund": "false",
        "PLAYWRIGHT_BROWSERS_PATH": str(work / "deps/playwright"),
        "NOONMARK_WEB_DIST": str(build / "web"), "NOONMARK_VITE_CACHE": str(work / "cache/vite" / nodeversion / web_lock_hash),
        "NOONMARK_TSBUILDINFO": str(run / "tmp/web.tsbuildinfo"),
    }
    # 保留当前本机 daemon 的 socket；外置 DOCKER_CONFIG 不继承用户 context metadata。
    if shutil.which("docker"):
        docker_endpoint = os.environ.get("DOCKER_HOST", "")
        if not docker_endpoint:
            docker_endpoint = subprocess.check_output(
                ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], text=True
            ).strip()
        if not docker_endpoint.startswith("unix://"):
            fail("web build/test requires a local Unix Docker endpoint")
        values["DOCKER_HOST"] = docker_endpoint
        values["DOCKER_CONTEXT"] = ""
    for key in ["GOCACHE", "GOMODCACHE", "GOPATH", "GOBIN", "DOCKER_CONFIG", "npm_config_cache", "PLAYWRIGHT_BROWSERS_PATH", "NOONMARK_VITE_CACHE"]:
        private_dir(Path(values[key]))
    manifest = {"profile": profile, "run_id": run_id, "source_hash": source,
                "owner_uid": os.getuid(), "go": goversion, "node": nodeversion, "architecture": platform.machine()}
    browser_tmp = allocate_browser_temp(work, manifest)
    manifest["browser_tmp_id"] = browser_tmp.name
    values["NOONMARK_BROWSER_TMPDIR"] = str(browser_tmp)
    for path in [run / "ownership.json", build / "manifest.json"]:
        with path.open("x", encoding="utf-8") as output:
            json.dump(manifest, output, ensure_ascii=False, indent=2)
            output.write("\n")
    for key, value in values.items():
        print("export " + key + "=" + shlex.quote(value))


def main():
    os.umask(0o077)
    action = sys.argv[1] if len(sys.argv) > 1 else "check"
    if action == "init" and len(sys.argv) == 3:
        initialize(sys.argv[2])
    elif action == "check":
        work = root()
        check(work)
        check_environment(work)
        print("workspace: source-only guard passed")
    elif action == "hash":
        print(source_hash())
    else:
        fail("usage: workspace.py check | hash | init <profile>")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("workspace: " + str(error), file=sys.stderr)
        sys.exit(1)
