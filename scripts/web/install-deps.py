#!/usr/bin/env python3
"""只在受检外置沙盒执行锁定依赖安装。"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace import REPO, check, private_dir, root


def main():
    os.umask(0o077)
    work = root()
    check(work)
    package = REPO / "apps/web"
    manifests = {name: (package / name).read_bytes() for name in ["package.json", "package-lock.json"]}
    digest = hashlib.sha256()
    for data in manifests.values():
        digest.update(data)
    digest.update(subprocess.check_output(["node", "--version"]))
    digest.update(subprocess.check_output(["npm", "--version"]))
    digest.update((platform.system() + platform.machine()).encode())
    target = work / "deps/npm" / digest.hexdigest()
    private_dir(target)
    lock_path = work / "deps/npm/install.lock"
    if lock_path.is_symlink():
        raise RuntimeError("dependency lock must not be a symlink")
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        complete = target / "installed.json"
        if complete.is_symlink() or (target / "node_modules").is_symlink():
            raise RuntimeError("dependency content must not redirect outside its sandbox")
        if not complete.exists():
            for name, data in manifests.items():
                destination = target / name
                if destination.is_symlink():
                    raise RuntimeError("dependency manifest must not be a symlink")
                destination.write_bytes(data)
            subprocess.run(["npm", "ci", "--ignore-scripts"], cwd=target, check=True)
            complete.write_text(json.dumps({"manifest_hash": digest.hexdigest()}) + "\n")
        elif json.loads(complete.read_text())["manifest_hash"] != digest.hexdigest():
            raise RuntimeError("dependency completion marker does not match the lockfile")
        link = package / "node_modules"
        if link.is_symlink():
            if work / "deps/npm" not in link.resolve().parents:
                raise RuntimeError("refusing to replace an unmanaged dependency link")
            if link.resolve() == target / "node_modules":
                return
            link.unlink()
        elif link.exists():
            raise RuntimeError("refusing to replace a real node_modules directory")
        link.symlink_to(target / "node_modules", target_is_directory=True)


if __name__ == "__main__":
    main()
