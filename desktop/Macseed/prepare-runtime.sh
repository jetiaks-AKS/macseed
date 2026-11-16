#!/bin/bash
# Development Core/Python descriptor and pinned nested native helpers.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then echo 'Usage: prepare-runtime.sh RESOURCE_DIRECTORY [arm64|x86_64]' >&2; exit 2; fi
cd "$(dirname "$0")"
core_root="$(cd ../.. && pwd -P)"
python_runtime="$(xcrun --find python3)"
resource_directory="$1"
architecture="${2:-$(uname -m)}"
"$python_runtime" -B ./prepare-age.py "$resource_directory" "$architecture"
parser_build_result="$("$python_runtime" -B ../../scripts/build-shell-parser.py --resources "$resource_directory" --arch "$architecture")"
if [[ ! "$parser_build_result" =~ ^Prepared\ dormant\ Shell\ parser\;\ manifest_sha256=([0-9a-f]{64})$ ]]; then
    echo 'Invalid Shell parser build result' >&2; exit 2
fi
parser_manifest_sha256="${BASH_REMATCH[1]}"
printf '%s\n' "$parser_build_result"
mkdir -p "$resource_directory"
descriptor="$resource_directory/CoreRuntime.plist"
/usr/bin/plutil -create xml1 "$descriptor"
/usr/bin/plutil -insert Version -integer 1 "$descriptor"
/usr/bin/plutil -insert Mode -string development "$descriptor"
/usr/bin/plutil -insert CoreRoot -string "$core_root" "$descriptor"
/usr/bin/plutil -insert PythonExecutable -string "$python_runtime" "$descriptor"
/usr/bin/plutil -insert ShellParserManifestSHA256 -string "$parser_manifest_sha256" "$descriptor"
