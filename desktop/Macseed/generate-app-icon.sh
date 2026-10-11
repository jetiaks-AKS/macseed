#!/bin/bash
# Export the same vector mark used in UI; keep temporary artifacts under ignored build/.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/Branding/module-cache
sources=()
for source in Sources/*.swift; do
    if [[ "$source" != Sources/MacseedApp.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
    -module-cache-path "$PWD/build/Branding/module-cache" -parse-as-library "${sources[@]}" tools/GenerateAppIcon.swift -o build/Branding/GenerateAppIcon
build/Branding/GenerateAppIcon
iconutil -c icns build/Branding/Macseed.iconset -o Resources/Macseed.icns
