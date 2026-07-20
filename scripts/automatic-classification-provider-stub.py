#!/usr/bin/env python3
"""Deterministic loopback OpenAI-compatible provider for Noonmark App E2E.

Outcome sequences repeat their final status after they are exhausted. This makes
``--post-outcomes 429,503`` deterministic for any unexpected extra request: the
third and later requests keep receiving 503 instead of silently succeeding.
Assistant-content sequences use the same rule, so ``malformed,valid`` yields one
HTTP 200 response with malformed classification JSON followed by valid replies.
"""

import argparse
import json
import os
import pathlib
import signal
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import List, Optional, Tuple


MODEL = "noonmark-e2e-automatic-classification"
API_KEY = "noonmark-e2e-local-provider-key"
CATEGORY_NAME = "E2E 自动分组"
LABEL_NAMES = ("E2E 自动标签", "E2E 本地验证")
SUPPORTED_OUTCOMES = frozenset({200, 401, 429, 503})
SUPPORTED_CONTENT_OUTCOMES = frozenset({"valid", "malformed"})
GATE_TIMEOUT_SECONDS = 60


def atomic_write(path: pathlib.Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def parse_outcomes(value: str) -> List[int]:
    try:
        outcomes = [int(item.strip()) for item in value.split(",")]
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "outcomes must be a comma-separated status sequence"
        ) from error
    if not outcomes or any(
        outcome not in SUPPORTED_OUTCOMES for outcome in outcomes
    ):
        supported = ", ".join(str(outcome) for outcome in sorted(SUPPORTED_OUTCOMES))
        raise argparse.ArgumentTypeError(
            f"outcomes must contain only supported statuses: {supported}"
        )
    return outcomes


def parse_content_outcomes(value: str) -> List[str]:
    outcomes = [item.strip() for item in value.split(",")]
    if not outcomes or any(
        outcome not in SUPPORTED_CONTENT_OUTCOMES for outcome in outcomes
    ):
        supported = ", ".join(sorted(SUPPORTED_CONTENT_OUTCOMES))
        raise argparse.ArgumentTypeError(
            f"content outcomes must contain only supported values: {supported}"
        )
    return outcomes


def build_response_content(payload: object) -> str:
    if not isinstance(payload, dict):
        raise ValueError("request payload must be an object")
    messages = payload.get("messages")
    if not isinstance(messages, list) or len(messages) != 2:
        raise ValueError("request messages are invalid")
    user_message = messages[1]
    if not isinstance(user_message, dict) or not isinstance(
        user_message.get("content"), str
    ):
        raise ValueError("user prompt is invalid")
    prompt = json.loads(user_message["content"])
    if not isinstance(prompt, dict) or not isinstance(prompt.get("catalog"), dict):
        raise ValueError("classification catalog is invalid")
    catalog = prompt["catalog"]
    categories = catalog.get("categories")
    labels = catalog.get("labels")
    if not isinstance(categories, list) or not isinstance(labels, list):
        raise ValueError("classification catalog items are invalid")

    def choice(items: List[object], name: str) -> object:
        for item in items:
            if not isinstance(item, dict):
                raise ValueError("classification catalog item is invalid")
            handle = item.get("handle")
            display_name = item.get("displayName")
            if not isinstance(handle, str) or not isinstance(display_name, str):
                raise ValueError("classification catalog item fields are invalid")
            if display_name == name:
                return {"action": "reuse", "handle": handle}
        return {"action": "create", "name": name}

    return json.dumps(
        {
            "category": choice(categories, CATEGORY_NAME),
            "labels": [choice(labels, name) for name in LABEL_NAMES],
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


class ProviderHandler(BaseHTTPRequestHandler):
    server_version = "NoonmarkE2EProvider/1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/v1/models" or not self._authorized():
            self._send_error(404, "route_not_found")
            return
        _, outcome = self.server.record_health_request()
        if outcome != 200:
            self._send_error(outcome, "health_outcome")
            return
        self._send_json({"data": [{"id": MODEL}]})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/chat/completions" or not self._authorized():
            self._send_error(404, "route_not_found")
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_error(400, "invalid_content_length")
            return
        if content_length <= 0 or content_length > 1_048_576:
            self._send_error(400, "invalid_content_length")
            return
        try:
            payload = json.loads(self.rfile.read(content_length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_error(400, "invalid_json")
            return
        if (
            payload.get("model") != MODEL
            or payload.get("response_format") != {"type": "json_object"}
            or not isinstance(payload.get("messages"), list)
            or len(payload["messages"]) != 2
        ):
            self._send_error(422, "invalid_classification_contract")
            return
        try:
            response_content = build_response_content(payload)
        except (TypeError, ValueError, json.JSONDecodeError):
            self._send_error(422, "invalid_classification_catalog")
            return
        request_number, outcome, content_outcome = self.server.record_post_request()
        if self.server.request_received_path is not None:
            atomic_write(
                self.server.request_received_path,
                str(request_number),
            )
        if self.server.response_gate_directory is not None:
            atomic_write(
                self.server.response_gate_directory
                / f"request-{request_number}.received",
                str(request_number),
            )
        if self.server.response_gate_path is not None:
            if not self._wait_for_gate(self.server.response_gate_path):
                self._send_error(504, "global_response_gate_timeout")
                return
        if self.server.response_gate_directory is not None:
            release_path = (
                self.server.response_gate_directory
                / f"response-{request_number}.release"
            )
            if not self._wait_for_gate(release_path):
                self._send_error(504, "per_request_response_gate_timeout")
                return
        if outcome != 200:
            self._send_error(outcome, "post_outcome")
            return
        if content_outcome == "malformed":
            response_content = "{"
        self._send_json(
            {
                "choices": [
                    {
                        "message": {
                            "role": "assistant",
                            "content": response_content,
                        }
                    }
                ]
            }
        )

    def _wait_for_gate(self, path: pathlib.Path) -> bool:
        deadline = time.monotonic() + GATE_TIMEOUT_SECONDS
        while not path.exists():
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.01)
        return True

    def _authorized(self) -> bool:
        return self.headers.get("Authorization") == f"Bearer {API_KEY}"

    def _send_error(self, status: int, code: str) -> None:
        self._send_json(
            {
                "error": {
                    "message": "deterministic E2E provider rejected the request",
                    "type": "e2e_provider_error",
                    "code": code,
                }
            },
            status,
        )

    def _send_json(self, payload: object, status: int = 200) -> None:
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        )
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            return


class ProviderServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        count_path: pathlib.Path,
        request_received_path: Optional[pathlib.Path],
        response_gate_path: Optional[pathlib.Path],
        response_gate_directory: Optional[pathlib.Path],
        post_outcomes: List[int],
        post_content_outcomes: List[str],
        health_outcomes: List[int],
        health_count_path: Optional[pathlib.Path],
    ):
        super().__init__(("127.0.0.1", 0), ProviderHandler)
        self.count_path = count_path
        self.request_received_path = request_received_path
        self.response_gate_path = response_gate_path
        self.response_gate_directory = response_gate_directory
        self.post_outcomes = post_outcomes
        self.post_content_outcomes = post_content_outcomes
        self.health_outcomes = health_outcomes
        self.health_count_path = health_count_path
        self.request_count = 0
        self.health_count = 0
        self.count_lock = threading.Lock()

    def record_post_request(self) -> Tuple[int, int, str]:
        with self.count_lock:
            self.request_count += 1
            request_number = self.request_count
            outcome = self.post_outcomes[
                min(request_number - 1, len(self.post_outcomes) - 1)
            ]
            content_outcome = self.post_content_outcomes[
                min(request_number - 1, len(self.post_content_outcomes) - 1)
            ]
            atomic_write(self.count_path, str(request_number))
            return request_number, outcome, content_outcome

    def record_health_request(self) -> Tuple[int, int]:
        with self.count_lock:
            self.health_count += 1
            request_number = self.health_count
            outcome = self.health_outcomes[
                min(request_number - 1, len(self.health_outcomes) - 1)
            ]
            if self.health_count_path is not None:
                atomic_write(self.health_count_path, str(request_number))
            return request_number, outcome


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True, type=pathlib.Path)
    parser.add_argument("--count-file", required=True, type=pathlib.Path)
    parser.add_argument("--request-received-file", type=pathlib.Path)
    parser.add_argument("--response-gate-file", type=pathlib.Path)
    parser.add_argument(
        "--response-gate-directory",
        type=pathlib.Path,
        help=(
            "write request-N.received and wait for response-N.release for each "
            "valid classification request"
        ),
    )
    parser.add_argument(
        "--post-outcomes",
        type=parse_outcomes,
        default=[200],
        help=(
            "comma-separated 200/401/429/503 sequence; the final status repeats "
            "after exhaustion"
        ),
    )
    parser.add_argument(
        "--post-content-outcomes",
        type=parse_content_outcomes,
        default=["valid"],
        help=(
            "comma-separated valid/malformed assistant-content sequence for "
            "HTTP 200 responses; the final value repeats after exhaustion"
        ),
    )
    parser.add_argument(
        "--health-outcomes",
        type=parse_outcomes,
        default=[200],
        help=(
            "comma-separated 200/401/429/503 sequence for GET /v1/models; the "
            "final status repeats after exhaustion"
        ),
    )
    parser.add_argument("--health-count-file", type=pathlib.Path)
    arguments = parser.parse_args()
    if arguments.response_gate_directory is not None:
        arguments.response_gate_directory.mkdir(parents=True, exist_ok=True)
    server = ProviderServer(
        arguments.count_file,
        arguments.request_received_file,
        arguments.response_gate_file,
        arguments.response_gate_directory,
        arguments.post_outcomes,
        arguments.post_content_outcomes,
        arguments.health_outcomes,
        arguments.health_count_file,
    )
    atomic_write(arguments.count_file, "0")
    if arguments.health_count_file is not None:
        atomic_write(arguments.health_count_file, "0")
    atomic_write(arguments.ready_file, str(server.server_address[1]))

    def stop(_signal: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever(poll_interval=0.05)
    server.server_close()


if __name__ == "__main__":
    main()
