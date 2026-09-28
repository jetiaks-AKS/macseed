#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

find bootstrap.sh modules scripts -type f -name '*.sh' -print0 |
    xargs -0 shellcheck --severity=warning
