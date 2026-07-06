.PHONY: build build-app package-dmg verify-dmg test-dmg-install test test-unit test-integration test-system test-deterministic-sim test-e2e render-prototype-screenshots test-visual-regression test-ai-provider-live test-all lint format format-check check

build:
	swift build

build-app:
	scripts/build-mac-app

package-dmg:
	scripts/package-dmg

verify-dmg:
	scripts/verify-dmg

test-dmg-install:
	scripts/test-dmg-install

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

render-prototype-screenshots:
	scripts/render-prototype-screenshots

test-visual-regression:
	scripts/test-visual-regression

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
