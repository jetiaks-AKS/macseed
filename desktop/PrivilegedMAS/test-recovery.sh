#!/bin/bash
# Rootless recovery fixtures only. No service registration, MAS or real cancellation.
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d /private/tmp/macseed-recovery-tests.XXXXXX)"
trap 'rm -rf "$out"' EXIT
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$out/cache" -swift-version 5 -parse-as-library -D LIFETIME_TESTING \
  Service/Contract.swift Shared/Trust.swift Shared/Journal.swift Shared/OperationLifetime.swift Shared/Recovery.swift \
  Tests/RecoveryTests.swift -o "$out/RecoveryTests"
"$out/RecoveryTests"
