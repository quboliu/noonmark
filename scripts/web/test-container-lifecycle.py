#!/usr/bin/env python3
"""验证 Docker stop 与异步删除之间的协调边界；真实路径由 test-e2e 覆盖。"""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("e2e_runtime", Path(__file__).with_name("test-e2e.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RemovalBarrier(unittest.TestCase):
    def test_does_not_reuse_name_until_daemon_reports_actual_removal(self):
        with patch.object(runtime.subprocess, "check_output", side_effect=["owned-id\n", "owned-id\n", ""]) as probe, patch.object(runtime.time, "sleep"):
            runtime.wait_for_removal("owned-id")
        self.assertEqual(probe.call_count, 3)
        self.assertEqual(probe.call_args.args[0][-1], "id=owned-id")

    def test_daemon_failure_is_not_absence(self):
        with patch.object(runtime.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, ["docker"])):
            with self.assertRaises(subprocess.CalledProcessError):
                runtime.wait_for_removal("owned-id")

    def test_stuck_removal_and_foreign_identity_fail_closed(self):
        with patch.object(runtime.subprocess, "check_output", return_value="owned-id\n"):
            with self.assertRaisesRegex(RuntimeError, "did not complete"):
                runtime.wait_for_removal("owned-id", timeout=0)
        with patch.object(runtime.subprocess, "check_output", return_value="foreign-id\n"):
            with self.assertRaisesRegex(RuntimeError, "identity"):
                runtime.wait_for_removal("owned-id")


if __name__ == "__main__":
    unittest.main()
