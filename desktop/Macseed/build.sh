#!/bin/bash
# Local development build without distribution signing from the same sources as the Xcode target.
set -euo pipefail
cd "$(dirname "$0")"
configuration="${1:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo 'Usage: ./build.sh [Debug|Release] [--test]' >&2; exit 2 ;; esac
if [[ $# -gt 2 || ( $# -eq 2 && "$2" != --test ) ]]; then
    echo 'Usage: ./build.sh [Debug|Release] [--test]' >&2
    exit 2
fi
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
architecture="$(uname -m)"
output_dir="$PWD/build/$configuration"
mkdir -p "$output_dir/module-cache" "$output_dir/Macseed.app/Contents/MacOS"
compiler_options=(-sdk "$sdk_path" -target "$architecture-apple-macosx14.0" -swift-version 5
    -module-cache-path "$output_dir/module-cache")
if [[ "$configuration" == Debug ]]; then compiler_options+=(-D DEBUG -Onone -g); else compiler_options+=(-O); fi
xcrun swiftc "${compiler_options[@]}" -parse-as-library Sources/*.swift -o "$output_dir/Macseed.app/Contents/MacOS/Macseed"
cp Info.plist "$output_dir/Macseed.app/Contents/Info.plist"
./prepare-runtime.sh "$output_dir/Macseed.app/Contents/Resources"
/usr/bin/plutil -lint "$output_dir/Macseed.app/Contents/Info.plist"
if [[ "${2:-}" == --test ]]; then
    presentation_sources=()
    for source_file in Sources/*.swift; do
        if [[ "$source_file" != Sources/MacseedApp.swift ]]; then presentation_sources+=("$source_file"); fi
    done
    xcrun swiftc "${compiler_options[@]}" -parse-as-library "${presentation_sources[@]}" Tests/PresentationTests.swift \
        -o "$output_dir/PresentationTests"
    "$output_dir/PresentationTests"
    xcrun swiftc "${compiler_options[@]}" -parse-as-library Sources/Core*.swift Tests/CoreRuntimeTests.swift \
        -o "$output_dir/CoreRuntimeTests"
    "$output_dir/CoreRuntimeTests" "$(cd ../.. && pwd -P)" "$(xcrun --find python3)"
    xcrun swiftc "${compiler_options[@]}" -parse-as-library "${presentation_sources[@]}" Tests/EnvironmentStatusTests.swift \
        -o "$output_dir/EnvironmentStatusTests"
    "$output_dir/EnvironmentStatusTests" "$(cd ../.. && pwd -P)" "$(xcrun --find python3)"
    xcrun swiftc "${compiler_options[@]}" -parse-as-library "${presentation_sources[@]}" Tests/CaptureTests.swift \
        -o "$output_dir/CaptureTests"
    "$output_dir/CaptureTests" "$(cd ../.. && pwd -P)" "$(xcrun --find python3)"
    if [[ "$configuration" == Release ]]; then
        if /usr/bin/strings "$output_dir/Macseed.app/Contents/MacOS/Macseed" | /usr/bin/grep -E 'Demo States|Next Sample Event|Personal SSH key|SampleProvider' >/dev/null; then
            echo 'FAIL: sample UI/provider leaked into Release' >&2
            exit 1
        fi
        echo 'PASS: Release excludes sample provider and demo controls'
    fi
fi
printf 'Built %s\n' "$output_dir/Macseed.app"
