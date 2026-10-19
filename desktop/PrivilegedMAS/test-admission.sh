#!/bin/bash
# Rootless production admission fixtures. Never runs MAS or registers a service.
set -euo pipefail
cd "$(dirname "$0")"
out="$(mktemp -d /private/tmp/macseed-admission-tests.XXXXXX)"
trap 'rm -rf "$out"' EXIT
xcrun swiftc -module-cache-path "$out/cache" -swift-version 5 -parse-as-library -D LIFETIME_TESTING \
  Service/Contract.swift Shared/Trust.swift Shared/Journal.swift Shared/OperationLifetime.swift \
  Shared/Recovery.swift Shared/MASInventory.swift Tests/AdmissionTests.swift -o "$out/AdmissionTests"
"$out/AdmissionTests"
