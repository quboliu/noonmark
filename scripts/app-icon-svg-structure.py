#!/usr/bin/env python3

"""Fail-closed structural checks for Noonmark's canonical AppIcon SVG."""

from __future__ import annotations

import argparse
import math
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


MAX_FILE_BYTES = 2_000_000
MAX_PATHS = 5_000
MAX_PATH_DATA_CHARACTERS = 1_500_000
MAX_PATH_COMMANDS = 50_000
MAX_SINGLE_PATH_CHARACTERS = 100_000

PATH_TOKEN_PATTERN = re.compile(
    r"[A-Za-z]|[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"
)


class SVGStructureError(ValueError):
    """The canonical SVG violates a structural AppIcon contract."""


@dataclass(frozen=True)
class SVGStructureMetrics:
    file_bytes: int
    path_count: int
    path_data_characters: int
    path_command_count: int
    maximum_path_characters: int
    unit_square_count: int


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def path_tokens(path_data: str) -> list[str] | None:
    tokens: list[str] = []
    cursor = 0
    for match in PATH_TOKEN_PATTERN.finditer(path_data):
        separator = path_data[cursor : match.start()]
        if separator.strip(" ,\t\r\n"):
            return None
        tokens.append(match.group(0))
        cursor = match.end()

    if path_data[cursor:].strip(" ,\t\r\n"):
        return None
    return tokens


def is_command(token: str) -> bool:
    return len(token) == 1 and token.isalpha()


def semantic_path_command_count(path_data: str) -> int:
    """Count explicit and implicit SVG path operations."""

    tokens = path_tokens(path_data)
    if not tokens:
        raise SVGStructureError("canonical SVG contains invalid path data")

    parameter_counts = {
        "M": 2,
        "L": 2,
        "H": 1,
        "V": 1,
        "C": 6,
        "S": 4,
        "Q": 4,
        "T": 2,
        "A": 7,
    }
    command: str | None = None
    operation_count = 0
    index = 0

    while index < len(tokens):
        token = tokens[index]
        if is_command(token):
            operation = token.upper()
            if operation == "Z":
                operation_count += 1
                command = None
                index += 1
                continue
            if operation not in parameter_counts:
                raise SVGStructureError(
                    f"canonical SVG contains unsupported path command: {token}"
                )
            command = token
            index += 1
        elif command is None:
            raise SVGStructureError(
                "canonical SVG path parameters lack an active command"
            )

        if command is None:
            continue
        parameter_count = parameter_counts[command.upper()]
        group = tokens[index : index + parameter_count]
        if len(group) != parameter_count or any(is_command(item) for item in group):
            raise SVGStructureError(
                f"canonical SVG path command {command} has incomplete parameters"
            )
        try:
            for item in group:
                float(item)
        except ValueError as error:
            raise SVGStructureError(
                "canonical SVG contains a nonnumeric path parameter"
            ) from error

        index += parameter_count
        operation_count += 1
        if command == "M":
            command = "L"
        elif command == "m":
            command = "l"

    return operation_count


def is_unit_square_path(path_data: str) -> bool:
    """Recognize an axis-aligned 1×1 polygon despite SVG command spelling."""

    tokens = path_tokens(path_data)
    if not tokens:
        return False

    supported_commands = set("MmLlHhVvZz")
    points: list[tuple[float, float]] = []
    current = (0.0, 0.0)
    start: tuple[float, float] | None = None
    command: str | None = None
    index = 0

    while index < len(tokens):
        token = tokens[index]
        if is_command(token):
            if token not in supported_commands:
                return False
            command = token
            index += 1
            if command in "Zz":
                if start is None:
                    return False
                current = start
                points.append(current)
                command = None
                continue

        if command is None or index >= len(tokens) or is_command(tokens[index]):
            return False

        relative = command.islower()
        operation = command.upper()

        try:
            if operation in {"M", "L"}:
                if index + 1 >= len(tokens) or is_command(tokens[index + 1]):
                    return False
                x = float(tokens[index])
                y = float(tokens[index + 1])
                index += 2
                if relative:
                    x += current[0]
                    y += current[1]
                current = (x, y)
                if operation == "M":
                    if start is not None:
                        return False
                    start = current
                    command = "l" if relative else "L"
                points.append(current)
            elif operation == "H":
                x = float(tokens[index])
                index += 1
                if relative:
                    x += current[0]
                current = (x, current[1])
                points.append(current)
            elif operation == "V":
                y = float(tokens[index])
                index += 1
                if relative:
                    y += current[1]
                current = (current[0], y)
                points.append(current)
            else:
                return False
        except ValueError:
            return False

    if len(points) < 4:
        return False

    vertices = list(points)
    while len(vertices) > 1 and vertices[-1] == vertices[0]:
        vertices.pop()
    compact_vertices: list[tuple[float, float]] = []
    for point in vertices:
        if not compact_vertices or point != compact_vertices[-1]:
            compact_vertices.append(point)

    if len(compact_vertices) != 4:
        return False

    xs = [point[0] for point in compact_vertices]
    ys = [point[1] for point in compact_vertices]
    minimum_x, maximum_x = min(xs), max(xs)
    minimum_y, maximum_y = min(ys), max(ys)
    if not math.isclose(maximum_x - minimum_x, 1.0, abs_tol=1e-9):
        return False
    if not math.isclose(maximum_y - minimum_y, 1.0, abs_tol=1e-9):
        return False

    corners = {
        (minimum_x, minimum_y),
        (maximum_x, minimum_y),
        (maximum_x, maximum_y),
        (minimum_x, maximum_y),
    }
    if set(compact_vertices) != corners:
        return False

    twice_area = 0.0
    for point, next_point in zip(
        compact_vertices,
        compact_vertices[1:] + compact_vertices[:1],
    ):
        if point[0] != next_point[0] and point[1] != next_point[1]:
            return False
        twice_area += point[0] * next_point[1] - next_point[0] * point[1]
    return math.isclose(abs(twice_area) / 2, 1.0, abs_tol=1e-9)


def inspect_svg_bytes(data: bytes) -> SVGStructureMetrics:
    if len(data) > MAX_FILE_BYTES:
        raise SVGStructureError(
            f"canonical SVG is too large: {len(data)} > {MAX_FILE_BYTES} bytes"
        )

    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise SVGStructureError(f"canonical SVG is not valid XML: {error}") from error

    if local_name(root.tag) != "svg":
        raise SVGStructureError("canonical SVG root element must be <svg>")

    try:
        view_box = [float(value) for value in root.attrib["viewBox"].split()]
    except (KeyError, ValueError) as error:
        raise SVGStructureError(
            "canonical SVG must declare a numeric viewBox"
        ) from error
    if view_box != [0.0, 0.0, 1024.0, 1024.0]:
        raise SVGStructureError(
            "canonical SVG must use viewBox=\"0 0 1024 1024\""
        )

    elements = list(root.iter())
    if any(local_name(element.tag) == "image" for element in elements):
        raise SVGStructureError("canonical SVG must not embed raster images")

    paths = [
        element for element in elements if local_name(element.tag) == "path"
    ]
    if len(paths) > MAX_PATHS:
        raise SVGStructureError(
            f"canonical SVG has raster-like path explosion: "
            f"{len(paths)} > {MAX_PATHS} paths"
        )

    path_data = [path.attrib.get("d", "") for path in paths]
    if any(not data.strip() for data in path_data):
        raise SVGStructureError("every canonical SVG path must have path data")

    path_data_characters = sum(len(data) for data in path_data)
    if path_data_characters > MAX_PATH_DATA_CHARACTERS:
        raise SVGStructureError(
            "canonical SVG path data is too large: "
            f"{path_data_characters} > {MAX_PATH_DATA_CHARACTERS} characters"
        )

    maximum_path_characters = max((len(data) for data in path_data), default=0)
    if maximum_path_characters > MAX_SINGLE_PATH_CHARACTERS:
        raise SVGStructureError(
            "canonical SVG contains an excessively complex single path: "
            f"{maximum_path_characters} > {MAX_SINGLE_PATH_CHARACTERS} characters"
        )

    path_command_count = sum(
        semantic_path_command_count(data) for data in path_data
    )
    if path_command_count > MAX_PATH_COMMANDS:
        raise SVGStructureError(
            "canonical SVG has excessive path command complexity: "
            f"{path_command_count} > {MAX_PATH_COMMANDS} commands"
        )

    unit_square_count = sum(is_unit_square_path(data) for data in path_data)
    if unit_square_count:
        raise SVGStructureError(
            "canonical SVG contains raster-like unit-square pixel paths: "
            f"{unit_square_count}"
        )

    return SVGStructureMetrics(
        file_bytes=len(data),
        path_count=len(paths),
        path_data_characters=path_data_characters,
        path_command_count=path_command_count,
        maximum_path_characters=maximum_path_characters,
        unit_square_count=unit_square_count,
    )


def run_self_test() -> None:
    valid_svg = b"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
      <path d="M 10 10 C 20 20 30 30 40 40 Z"/>
    </svg>
    """
    metrics = inspect_svg_bytes(valid_svg)
    assert metrics.path_count == 1

    newline_paths = "".join(
        '<path\n d="M0 0 C1 0 1 1 0 1Z"/>' for _ in range(MAX_PATHS + 1)
    )
    try:
        inspect_svg_bytes(
            (
                '<svg xmlns="http://www.w3.org/2000/svg" '
                'viewBox="0 0 1024 1024">'
                f"{newline_paths}</svg>"
            ).encode()
        )
    except SVGStructureError as error:
        assert "path explosion" in str(error)
    else:
        raise AssertionError("newline-formatted path explosion was not rejected")

    for unit_square in (
        "M0,0 L1,0 L1,1 L0,1 Z",
        "M0 0H1V1H0Z",
        "m0 0h1v1h-1z",
        "M0 0H1V1H0V0Z",
        "M0 0H1V1H0",
    ):
        fixture = (
            '<svg xmlns="http://www.w3.org/2000/svg" '
            'viewBox="0 0 1024 1024">'
            f'<path d="{unit_square}"/></svg>'
        ).encode()
        try:
            inspect_svg_bytes(fixture)
        except SVGStructureError as error:
            assert "unit-square" in str(error)
        else:
            raise AssertionError(
                f"unit-square spelling was not rejected: {unit_square}"
            )

    implicit_segments = " ".join(["0 0"] * 20_000)
    command_explosion = (
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'viewBox="0 0 1024 1024">'
        + "".join(
            f'<path d="M0 0 {implicit_segments}"/>' for _ in range(3)
        )
        + "</svg>"
    ).encode()
    try:
        inspect_svg_bytes(command_explosion)
    except SVGStructureError as error:
        assert "command complexity" in str(error)
    else:
        raise AssertionError(
            "implicit path command explosion was not rejected"
        )

    print("AppIcon SVG structural validator self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("svg", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()

    if arguments.self_test:
        run_self_test()
        return 0
    if arguments.svg is None:
        parser.error("provide an SVG path or --self-test")

    try:
        metrics = inspect_svg_bytes(arguments.svg.read_bytes())
    except (OSError, SVGStructureError) as error:
        print(error, file=sys.stderr)
        return 1

    print(
        "AppIcon SVG structure: "
        f"bytes={metrics.file_bytes} "
        f"paths={metrics.path_count} "
        f"path_data={metrics.path_data_characters} "
        f"commands={metrics.path_command_count} "
        f"max_path={metrics.maximum_path_characters} "
        f"unit_squares={metrics.unit_square_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
