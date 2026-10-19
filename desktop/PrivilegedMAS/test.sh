#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ $# -eq 1 && -d "$1" ]] || { echo 'Usage: test.sh BUILT_MACSEED_APP' >&2; exit 64; }
app="$1"
output="$(mktemp -d /private/tmp/macseed-mas-production-tests.XXXXXX)"
trap 'rm -rf "$output"' EXIT
options=(-sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -parse-as-library -module-cache-path "$output/cache")
xcrun swiftc "${options[@]}" Shared/MASServiceProtocol.swift Service/Contract.swift Shared/Trust.swift Shared/Journal.swift Shared/OperationLifetime.swift Shared/MASInventory.swift Tests/PolicyTests.swift -o "$output/PolicyTests"
"$output/PolicyTests" "$app"
# Native lifetime tests use only a harmless compiled fixture, never MAS.
xcrun clang Tests/LegacyFixtures/LifetimeFixture.c -o "$output/LifetimeFixture"
# PoC configuration retains its own fixed allowlist; shared lifecycle is identical.
xcrun swiftc "${options[@]}" -D LIFETIME_TESTING Tests/LegacyFixtures/Contract.swift Shared/Trust.swift Shared/Journal.swift Shared/OperationLifetime.swift Tests/LegacyFixtures/LifetimeTests.swift -o "$output/LifetimeTests"
"$output/LifetimeTests" "$output/LifetimeFixture"

xcrun swiftc "${options[@]}" -D LIFETIME_TESTING Tests/LegacyFixtures/Contract.swift Shared/Trust.swift Shared/Journal.swift Shared/OperationLifetime.swift Tests/LegacyFixtures/UserVerification.swift Tests/LegacyFixtures/ControlledTests.swift -o "$output/ControlledTests"
"$output/ControlledTests" "$output/LifetimeFixture"

# The focused recovery runner is also part of the existing production MAS suite.
bash test-recovery.sh

# Current production multi-attempt admission and migration contracts.
bash test-admission.sh
