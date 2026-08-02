.PHONY: reset-dev-data generate-app-icon verify-app-icon build build-app run-app run-demo-app test-demo-fixture package-dmg verify-dmg test-dmg-install release-private-dmg test test-unit test-integration test-system test-deterministic-sim test-e2e test-runtime-profile-isolation test-failure-case-gates test-tencent-ime-input-contract test-tencent-ime-input-matrix test-tencent-ime-termination-persistence test-ai-provider-live test-cloudkit-sync-live test-all lint format format-check check

reset-dev-data:
	@test -n "$(RESET_PROFILE)" || \
		(echo "RESET_PROFILE must explicitly name a nonproduction profile" >&2; exit 1)
	scripts/reset-dev-data "$(RESET_PROFILE)"

generate-app-icon:
	scripts/generate-app-icon

verify-app-icon:
	scripts/test-app-icon

build:
	scripts/test-app-icon
	swift build

build-app:
	scripts/build-mac-app debug development

run-app:
	scripts/run-mac-app

run-demo-app:
	scripts/run-demo-app

test-demo-fixture:
	scripts/test-interactive-demo-fixture

package-dmg:
	scripts/package-dmg

verify-dmg:
	scripts/verify-dmg

test-dmg-install:
	scripts/test-dmg-install

release-private-dmg:
	scripts/release-private-dmg

test:
	scripts/reset-dev-data audit
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

test-runtime-profile-isolation:
	scripts/test-runtime-profile-isolation

test-failure-case-gates:
	scripts/test-failure-case-gates

test-tencent-ime-input-contract:
	scripts/test-tencent-ime-input-contract

test-tencent-ime-input-matrix:
	scripts/test-tencent-ime-input-matrix

test-tencent-ime-termination-persistence:
	scripts/test-tencent-ime-termination-persistence

test-ai-provider-live:
	scripts/test-ai-provider-live

test-cloudkit-sync-live:
	scripts/test-cloudkit-sync-live

test-all:
	scripts/test-all

lint:
	scripts/test-diagnostic-logging-guard
	scripts/check-diagnostic-logging
	swiftlint lint --quiet

format:
	scripts/format

format-check:
	scripts/format --lint

check:
	scripts/check
