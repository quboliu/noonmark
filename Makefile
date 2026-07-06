.PHONY: build test lint format format-check check

build:
	swift build

test:
	swift test

lint:
	swiftlint lint --quiet

format:
	scripts/format

format-check:
	scripts/format --lint

check:
	scripts/check
