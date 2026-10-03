#!/bin/bash
# Development descriptor only. Stage 17 supplies a bundled relative descriptor.
set -euo pipefail
if [[ $# -ne 1 ]]; then echo 'Usage: prepare-runtime.sh RESOURCE_DIRECTORY' >&2; exit 2; fi
cd "$(dirname "$0")"
core_root="$(cd ../.. && pwd -P)"
python_runtime="$(xcrun --find python3)"
resource_directory="$1"
mkdir -p "$resource_directory"
descriptor="$resource_directory/CoreRuntime.plist"
/usr/bin/plutil -create xml1 "$descriptor"
/usr/bin/plutil -insert Version -integer 1 "$descriptor"
/usr/bin/plutil -insert Mode -string development "$descriptor"
/usr/bin/plutil -insert CoreRoot -string "$core_root" "$descriptor"
/usr/bin/plutil -insert PythonExecutable -string "$python_runtime" "$descriptor"
