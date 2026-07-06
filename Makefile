.PHONY: build build-app test lint format format-check check

build:
	swift build

build-app:
	scripts/build-mac-app

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
