.PHONY: reset-dev-data generate-app-icon verify-app-icon build build-app run-app package-dmg verify-dmg test-dmg-install test test-unit test-integration test-system test-deterministic-sim test-e2e test-ai-provider-live test-all lint format format-check check

reset-dev-data:
	scripts/reset-dev-data

generate-app-icon:
	scripts/generate-app-icon

verify-app-icon:
	scripts/test-app-icon

build:
	scripts/test-app-icon
	scripts/reset-dev-data
	swift build

build-app:
	scripts/build-mac-app

run-app:
	scripts/run-mac-app

package-dmg:
	scripts/package-dmg

verify-dmg:
	scripts/verify-dmg

test-dmg-install:
	scripts/test-dmg-install

test:
	scripts/reset-dev-data
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

test-ai-provider-live:
	scripts/test-ai-provider-live

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
