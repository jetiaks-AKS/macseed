#!/bin/bash
source "${SCRIPT_ROOT}/modules/migration/package.sh"
migration_main() {
    if [[ $# -eq 1 && "$1" == list ]]; then
        migration_run list
    elif [[ $# -eq 3 && "$1" == export && "$2" == --output && "$3" == /* ]]; then
        migration_run export "$3"
    elif [[ $# -eq 3 && "$1" == capture-export && "$2" == --output && "$3" == /* ]]; then
        migration_run capture-export "$3"
    elif [[ $# -eq 3 && "$1" == import && "$2" == --input && "$3" == /* ]]; then
        migration_run import "$3"
    elif [[ $# -eq 7 && "$1" == import && "$2" == --input && "$3" == /* &&
            "$4" == --internal-evidence && "$5" == /* && "$6" == --attempt &&
            "$7" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        migration_run import "$3" "$4" "$5" "$6" "$7"
    elif [[ $# -eq 11 && "$1" == import && "$2" == --input && "$3" == /* &&
            "$4" == --internal-evidence && "$5" == /* && "$6" == --attempt &&
            "$7" =~ ^[a-zA-Z0-9_-]+$ && "$8" == --application-channel-fd &&
            "$9" =~ ^[0-9]+$ && "${10}" == --operation-id &&
            "${11}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        migration_run import "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
    elif [[ $# -eq 1 && "$1" == application-list ]]; then
        migration_run application-list
    elif [[ $# -eq 9 && "$1" == application-export && "$2" == --output && "$3" == /* &&
            "$4" == --selection && "$5" == /* && "$6" == --application-channel-fd &&
            "$7" =~ ^[0-9]+$ && "$8" == --operation-id && "$9" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        migration_run application-export "$3" "$5" "$6" "$7" "$8" "$9"
    else
        printf 'Usage: %s {list|export --output /absolute/path/file.age|import --input /absolute/path/file.age}\n' "$0" >&2
        return 2
    fi
}
