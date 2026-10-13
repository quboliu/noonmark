#!/usr/bin/env python3
"""对本轮外置目录真实验证 fsync、跨进程 flock 与 SQLite WAL crash recovery。"""

import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import sqlite3
import subprocess
import sys


def wait_ready(child):
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    try:
        if not selector.select(timeout=15) or child.stdout.readline() != b"ready\n":
            raise RuntimeError("child process did not reach the persistence checkpoint")
    finally:
        selector.close()


def crash_write(database, commit):
    program = """
import signal, sqlite3, sys
connection = sqlite3.connect(sys.argv[1])
connection.execute('PRAGMA synchronous=FULL')
connection.execute('INSERT INTO facts VALUES (1)')
if sys.argv[2] == 'commit':
    connection.commit()
print('ready', flush=True)
signal.pause()
"""
    child = subprocess.Popen([sys.executable, "-B", "-c", program, str(database), "commit" if commit else "pending"], stdout=subprocess.PIPE)
    try:
        wait_ready(child)
        child.kill()
        if child.wait(timeout=15) != -signal.SIGKILL:
            raise RuntimeError("writer was not terminated with SIGKILL")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=15)


def main():
    run = Path(os.environ["NOONMARK_RUN_ROOT"])
    root = run / "databases/filesystem"
    root.mkdir(mode=0o700, exist_ok=False)
    with (root / "writer.lock").open("x") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        program = """
import fcntl, sys
with open(sys.argv[1], 'r') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(0)
    sys.exit(1)
"""
        subprocess.run([sys.executable, "-B", "-c", program, str(root / "writer.lock")], check=True, timeout=15)
    directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    database = root / "probe.sqlite"
    with sqlite3.connect(database) as connection:
        if connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] != "wal":
            raise RuntimeError("WAL was not enabled")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("CREATE TABLE facts (id INTEGER PRIMARY KEY)")
    crash_write(database, False)
    with sqlite3.connect(database) as connection:
        if connection.execute("SELECT count(*) FROM facts").fetchone()[0] != 0:
            raise RuntimeError("uncommitted crash write survived")
    crash_write(database, True)
    with sqlite3.connect(database) as connection:
        if connection.execute("SELECT count(*) FROM facts").fetchone()[0] != 1:
            raise RuntimeError("acknowledged write did not survive crash")
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("database integrity failed")
    filesystem = subprocess.check_output(["findmnt", "--noheadings", "--output", "FSTYPE", "--target", str(root)], text=True).strip()
    result = {"verdict": "passed", "filesystem": filesystem, "cross_process_flock": True,
              "directory_fsync": True, "wal_uncommitted_crash_rollback": True, "wal_committed_crash_durability": True,
              "scope": "host filesystem probe; application-driver and hardware power-loss guarantees require separate gates"}
    (run / "reports/filesystem.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
