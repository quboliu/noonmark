.PHONY: build build-app package-dmg test test-unit test-integration test-system test-deterministic-sim test-e2e test-all lint format format-check check

build:
	swift build

build-app:
	scripts/build-mac-app

package-dmg:
	scripts/package-dmg

test:
	swift test

test-unit:
	scripts/test-unit

test-integration:
	scripts/test-integration

test-system:
	scripts/test-system

test-deterministic-sim:
	scripts/test-deterministic-sim

test-e2e:
	scripts/test-e2e

test-all:
	scripts/test-all

lint:
	swiftlint lint --quiet

format:
	scripts/format

format-check:
	scripts/format --lint

check:
	scripts/check
