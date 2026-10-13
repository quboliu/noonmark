#!/usr/bin/env python3
"""验证拒绝危险路径，并证明异常退出不会在源码留下产物。"""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workspace


class WorkspaceTests(unittest.TestCase):
    def test_unknown_profiles_have_no_effects(self):
        for profile in ["production", "", "../audit", "/tmp", "E2E"]:
            with self.assertRaisesRegex(RuntimeError, "forbidden"):
                workspace.initialize(profile)

    def test_symlink_intermediate_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / "target").mkdir()
            (base / "link").symlink_to(base / "target", target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                workspace.private_dir(base / "link/child")
            self.assertFalse((base / "target/child").exists())

    def test_root_overlap_is_rejected_before_writes(self):
        original = os.environ.get("NOONMARK_WORK_ROOT")
        try:
            for root in [workspace.REPO, workspace.REPO / "build", workspace.REPO.parent]:
                os.environ["NOONMARK_WORK_ROOT"] = str(root)
                with self.assertRaisesRegex(RuntimeError, "overlap"):
                    workspace.root()
        finally:
            if original is None:
                os.environ.pop("NOONMARK_WORK_ROOT", None)
            else:
                os.environ["NOONMARK_WORK_ROOT"] = original

    def test_redirected_default_link_is_rejected(self):
        original_repo = workspace.REPO
        original_default = workspace.DEFAULT_WORK_ROOT
        original_root = os.environ.pop("NOONMARK_WORK_ROOT", None)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                workspace.REPO = Path(temporary) / "source"
                workspace.REPO.mkdir()
                workspace.DEFAULT_WORK_ROOT = Path(temporary) / "external"
                (workspace.REPO / ".work").symlink_to(Path(temporary))
                with self.assertRaisesRegex(RuntimeError, "different external root"):
                    workspace.root()
        finally:
            workspace.REPO = original_repo
            workspace.DEFAULT_WORK_ROOT = original_default
            if original_root is not None:
                os.environ["NOONMARK_WORK_ROOT"] = original_root

    def test_runs_are_unique_and_exit_status_is_preserved(self):
        script = workspace.REPO / "scripts/web/run"
        roots = []
        for status in [0, 23, 128 + signal.SIGTERM]:
            action = "exit " + str(status) if status != 128 + signal.SIGTERM else "kill -TERM $$"
            command = 'printf "%s\\n" "$NOONMARK_RUN_ROOT"; printf fixture > "$TMPDIR/owned-fixture"; ' + action
            result = subprocess.run([str(script), "audit", "bash", "-c", command], capture_output=True, text=True)
            self.assertEqual(result.returncode, status, result.stderr)
            run = Path(result.stdout.splitlines()[0])
            roots.append(run)
            self.assertTrue((run / "tmp/owned-fixture").is_file())
            manifest = json.loads((run / "ownership.json").read_text())
            self.assertEqual(manifest["profile"], "audit")
            self.assertEqual(manifest["run_id"], run.name)
            self.assertEqual(manifest["owner_uid"], os.getuid())
            workspace.check(workspace.root())
        self.assertEqual(len(set(roots)), 3)

    def test_readonly_mount_rejects_source_write(self):
        source = workspace.REPO / "apps/web/package.json"
        code = """
import errno, os, sys
try:
    descriptor = os.open(sys.argv[1], os.O_WRONLY)
except OSError as error:
    assert error.errno == errno.EROFS, error
else:
    os.close(descriptor)
    raise RuntimeError('source is writable')
"""
        subprocess.run([str(workspace.REPO / "scripts/web/readonly-exec"), sys.executable, "-B", "-c", code, str(source)], check=True)

    def test_output_environment_cannot_escape(self):
        original = os.environ["TMPDIR"]
        try:
            os.environ["TMPDIR"] = str(workspace.REPO)
            with self.assertRaisesRegex(RuntimeError, "TMPDIR"):
                workspace.check_environment(workspace.root())
        finally:
            os.environ["TMPDIR"] = original

    def test_dependency_links_and_ignored_artifacts_are_checked(self):
        original_repo = workspace.REPO
        try:
            with tempfile.TemporaryDirectory() as temporary:
                workspace.REPO = Path(temporary) / "source"
                web = workspace.REPO / "apps/web"
                web.mkdir(parents=True)
                work = Path(temporary) / "external"
                managed = work / "deps/npm/fixture/node_modules"
                managed.mkdir(parents=True)
                link = web / "node_modules"
                link.symlink_to(managed)
                workspace.check(work)
                link.unlink()
                link.symlink_to(Path(temporary))
                with self.assertRaisesRegex(RuntimeError, "outside"):
                    workspace.check(work)
                link.unlink()
                (web / "dist").mkdir()
                (workspace.REPO / ".gitignore").write_text("dist/\n")
                with self.assertRaisesRegex(RuntimeError, "generated directory"):
                    workspace.check(work)
        finally:
            workspace.REPO = original_repo

    def test_browser_socket_uses_owned_short_path(self):
        work = workspace.root()
        run = Path(os.environ["NOONMARK_RUN_ROOT"])
        short = Path(os.environ["NOONMARK_BROWSER_TMPDIR"])
        manifest = json.loads((run / "ownership.json").read_text())
        workspace.check_browser_temp(work, short, manifest)
        self.assertEqual(os.environ["TMPDIR"], str(run / "tmp"))
        self.assertLessEqual(len(os.fsencode(short)), 48)
        with tempfile.TemporaryDirectory(prefix="org.chromium.Chromium.", dir=short) as chromium:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(Path(chromium) / "SingletonSocket"))

    def test_browser_tmp_rejects_unmanaged_and_other_run(self):
        work = workspace.root()
        run = Path(os.environ["NOONMARK_RUN_ROOT"])
        short = Path(os.environ["NOONMARK_BROWSER_TMPDIR"])
        manifest = json.loads((run / "ownership.json").read_text())
        with self.assertRaisesRegex(RuntimeError, "unmanaged"):
            workspace.check_browser_temp(work, run / "tmp", manifest)
        with self.assertRaisesRegex(RuntimeError, "another run"):
            workspace.check_browser_temp(work, short, dict(manifest, run_id="00000000-0000-4000-8000-000000000000"))
        with self.assertRaisesRegex(RuntimeError, "not assigned"):
            workspace.check_browser_temp(work, short, dict(manifest, browser_tmp_id="00000000"))

    def test_long_browser_root_fails_before_creation(self):
        work = workspace.root() / ("oversized-" + "x" * 50)
        with self.assertRaisesRegex(RuntimeError, "too long"):
            workspace.allocate_browser_temp(work, {})
        self.assertFalse(work.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
