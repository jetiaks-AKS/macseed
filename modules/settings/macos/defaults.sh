#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/../../core/application-interface/observation.sh" || return 2

# ==========================================
# macOS Defaults Executor
# ==========================================

DEFAULTS_OBSERVED_PRESENT=false
DEFAULTS_OBSERVED_VALUE=""
DEFAULTS_PREVIEW_CHANGED=false

source modules/settings/macos/records.sh

# Never inherit a snapshot. Each read-only category owns one private batch;
# Apply's per-record pre-check and post-check continue to read fresh state.
MACOS_OBSERVED_RECORDS=''
macos_observe_config() {
    MACOS_OBSERVED_RECORDS=''
    [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]] || return 0
    case "$2" in finder|dock|windows|keyboard|trackpad) ;; *) return 0 ;; esac
    local output result
    output="$(mktemp)" || return 2
    application_observe local bash modules/settings/macos/defaults.sh --observe-config "$1" "$2" "$output" >/dev/null
    result=$?
    if [[ $result -eq 0 ]]; then
        MACOS_OBSERVED_RECORDS="$(cat "$output")" || result=2
    fi
    rm -f "$output" || return 2
    return "$result"
}

defaults_native_type() {
    case "$1" in
        bool) echo "Type is boolean" ;;
        int) echo "Type is integer" ;;
        float) echo "Type is float" ;;
        string) echo "Type is string" ;;
        *) return 2 ;;
    esac
}

normalize_defaults_integer() {
    local value="$1"
    local sign=""

    [[ "$value" =~ ^-?[0-9]+$ ]] || return 2

    if [[ "$value" == -* ]]; then
        sign="-"
        value="${value#-}"
    fi

    while [[ ${#value} -gt 1 && "$value" == 0* ]]; do
        value="${value#0}"
    done

    [[ "$value" != 0 ]] || sign=""
    printf '%s%s\n' "$sign" "$value"
}

normalize_defaults_float() {
    local value="$1"
    [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 2
    local negative=false
    if [[ "$value" == -* ]]; then negative=true; value="${value#-}"; fi
    local whole="${value%%.*}" fraction=""
    [[ "$value" != *.* ]] || fraction="${value#*.}"
    whole="$(normalize_defaults_integer "$whole")" || return 2
    while [[ "$fraction" == *0 && -n "$fraction" ]]; do fraction="${fraction%0}"; done
    if [[ "$negative" == true && ( "$whole" != 0 || -n "$fraction" ) ]]; then whole="-$whole"; fi
    printf '%s%s\n' "$whole" "${fraction:+.$fraction}"
}

defaults_values_match() {
    local type="$1"
    local expected="$2"
    local actual="$3"

    case "$type" in
        bool)
            case "$expected" in
                1|true) expected=true ;;
                0|false) expected=false ;;
                *) return 2 ;;
            esac
            case "$actual" in
                1|true) actual=true ;;
                0|false) actual=false ;;
                *) return 2 ;;
            esac
            ;;
        int)
            expected="$(normalize_defaults_integer "$expected")" || return 2
            actual="$(normalize_defaults_integer "$actual")" || return 2
            ;;
        float)
            expected="$(normalize_defaults_float "$expected")" || return 2
            actual="$(normalize_defaults_float "$actual")" || return 2
            ;;
        string)
            [[ "$actual" != *$'\n'* ]] || return 2
            ;;
        *) return 2 ;;
    esac

    [[ "$actual" == "$expected" ]]
}

check_defaults_record() {
    local domain="$1"
    local key="$2"
    local type="$3"
    local expected="$4"
    local expected_native_type native_type actual

    DEFAULTS_OBSERVED_PRESENT=false
    DEFAULTS_OBSERVED_VALUE=""
    DEFAULTS_OBSERVATION_KIND=unknown

    if [[ -n "${MACOS_OBSERVED_RECORDS:-}" ]]; then
        local observed_domain observed_key observed_type observed_expected observed_result observed_kind observed_present observed_value
        while IFS='|' read -r observed_domain observed_key observed_type observed_expected observed_result observed_kind observed_present observed_value; do
            if [[ "$observed_domain" == "$domain" && "$observed_key" == "$key" &&
                  "$observed_type" == "$type" && "$observed_expected" == "$expected" ]]; then
                [[ "$observed_result" == 0 || "$observed_result" == 1 || "$observed_result" == 2 ]] || return 2
                case "$observed_kind" in unknown|absent|different|matching) ;; *) return 2 ;; esac
                [[ "$observed_present" == true || "$observed_present" == false ]] || return 2
                [[ "$observed_value" != *'|'* ]] || return 2
                DEFAULTS_OBSERVED_PRESENT="$observed_present"
                DEFAULTS_OBSERVED_VALUE="$observed_value"
                DEFAULTS_OBSERVATION_KIND="$observed_kind"
                return "$observed_result"
            fi
        done <<< "$MACOS_OBSERVED_RECORDS"
        return 2
    fi

    expected_native_type="$(defaults_native_type "$type")" || return 2

    native_type="$(LC_ALL=C application_observe local-diagnostic defaults read-type "$domain" "$key" 2>&1)"
    local type_result=$?

    if [[ $type_result -ne 0 ]]; then
        if macos_defaults_key_absent "$type_result" "$native_type" "$domain" "$key"; then
            DEFAULTS_OBSERVATION_KIND=absent
            return 1
        fi
        error "Failed to inspect macOS preference: $domain $key"
        return 2
    fi

    if [[ "$type" == float || ( "$type" == int && "$domain" == com.apple.dock &&
          ( "$key" == tilesize || "$key" == largesize ) ) ]]; then
        if [[ "$native_type" != 'Type is float' && "$native_type" != 'Type is integer' ]]; then
            DEFAULTS_OBSERVATION_KIND=different
            error "Incompatible macOS preference type: $domain $key"
            return 2
        fi
    elif [[ "$native_type" != "$expected_native_type" ]]; then
        DEFAULTS_OBSERVATION_KIND=different
        error "Incompatible macOS preference type: $domain $key"
        return 2
    fi

    if ! macos_read_scalar "$domain" "$key"; then
        error "Failed to read macOS preference: $domain $key"
        return 2
    fi

    actual="$MACOS_DEFAULTS_VALUE"

    DEFAULTS_OBSERVED_PRESENT=true
    DEFAULTS_OBSERVED_VALUE="$actual"

    if [[ "$type" == int && "$domain" == com.apple.dock &&
          ( "$key" == tilesize || "$key" == largesize ) ]]; then
        defaults_values_match float "$expected" "$actual"
    else
        defaults_values_match "$type" "$expected" "$actual"
    fi
    local comparison_result=$?

    if [[ $comparison_result -eq 2 ]]; then
        error "Invalid observed macOS preference value: $domain $key"
    fi

    [[ $comparison_result -ne 1 ]] || DEFAULTS_OBSERVATION_KIND=different
    return "$comparison_result"
}

defaults_preview_display_value() {
    local type="$1"
    local value="$2"

    case "$type" in
        bool)
            case "$value" in
                1|true) printf 'true\n' ;;
                0|false) printf 'false\n' ;;
                *) return 2 ;;
            esac
            ;;
        int)
            normalize_defaults_integer "$value"
            ;;
        float)
            normalize_defaults_float "$value"
            ;;
        string)
            [[ "$value" != *[[:cntrl:]]* ]] || return 2
            printf '%s\n' "$value"
            ;;
        *)
            return 2
            ;;
    esac
}

preview_defaults_config() {
    local config_file="$1"
    local MACOS_OBSERVED_RECORDS=''
    local domain key type desired
    local record_result preview_result=0
    local current_display desired_display

    validate_defaults_config "$config_file" "${2:-}" || return 2
    macos_observe_config "$config_file" "${2:-}" || return 2
    DEFAULTS_PREVIEW_CHANGED=false

    while IFS='|' read -r domain key type desired || [[ -n "$domain$key$type$desired" ]]; do
        [[ -z "${domain// /}" ]] && continue

        check_defaults_record "$domain" "$key" "$type" "$desired"
        record_result=$?
        case $record_result in
            0) preview_record "macos-${2:-settings}" "$domain/$key" none satisfied ;;
            1) preview_record "macos-${2:-settings}" "$domain/$key" set_preference planned ;;
            *) preview_record "macos-${2:-settings}" "$domain/$key" set_preference blocked observation_failed ;;
        esac

        if [[ $record_result -eq 2 ]]; then preview_result=2; continue; fi
        [[ $record_result -ne 0 ]] || continue

        # Shared state is read by another sourced module.
        # shellcheck disable=SC2034
        DEFAULTS_PREVIEW_CHANGED=true

        if [[ "$domain" == com.apple.WindowManager && "$key" == HideDesktop ]]; then
            case "$desired" in
                1|true) preview_action "Would hide Desktop items" ;;
                0|false) preview_action "Would show Desktop items" ;;
            esac
            continue
        fi

        desired_display="$(defaults_preview_display_value "$type" "$desired")" || {
            preview_action "Would change macOS setting: $domain/$key"
            continue
        }

        if [[ "$DEFAULTS_OBSERVED_PRESENT" == false ]]; then
            preview_action "Would change macOS setting: $domain/$key (absent -> $desired_display)"
            continue
        fi

        current_display="$(defaults_preview_display_value "$type" "$DEFAULTS_OBSERVED_VALUE")" || {
            preview_action "Would change macOS setting: $domain/$key"
            continue
        }
        preview_action "Would change macOS setting: $domain/$key ($current_display -> $desired_display)"
    done < "$config_file"

    return "$preview_result"
}

check_defaults_config() {
    local config_file="$1"
    local MACOS_OBSERVED_RECORDS=''
    local configured=true
    local record_result
    local domain key type expected

    validate_defaults_config "$config_file" "${2:-}" || return 2
    macos_observe_config "$config_file" "${2:-}" || return 2

    while IFS='|' read -r domain key type expected || [[ -n "$domain$key$type$expected" ]]; do
        [[ -z "${domain// /}" ]] && continue

        check_defaults_record "$domain" "$key" "$type" "$expected"
        record_result=$?

        [[ $record_result -eq 2 ]] && return 2
        [[ $record_result -eq 0 ]] || configured=false
    done < "$config_file"

    [[ "$configured" == true ]]
}

# Single checked write shared by category files and resolved Screenshot paths.
apply_defaults_record() {
    local domain="$1" key="$2" type="$3" value="$4"
    local record_result write_value="$4"
    DEFAULTS_RECORD_CHANGED=false
    check_defaults_record "$domain" "$key" "$type" "$value"
    record_result=$?
    [[ $record_result -ne 2 ]] || return 2
    [[ $record_result -ne 0 ]] || return 0

    if [[ "$type" == bool ]]; then
        case "$value" in
            1) write_value=true ;;
            0) write_value=false ;;
        esac
    fi
    if ! defaults write "$domain" "$key" "-$type" "$write_value"; then
        error "Failed to configure macOS preference: $domain $key"
        return 2
    fi
    # Shared lifecycle flag is read by the calling module wrapper.
    # shellcheck disable=SC2034
    MODULE_CHANGED=true
    DEFAULTS_RECORD_CHANGED=true
    if ! check_defaults_record "$domain" "$key" "$type" "$value"; then
        error "Failed to verify macOS preference: $domain $key"
        return 2
    fi
    return 0
}

apply_defaults_config() {
    local config_file="$1"
    local domain key type value
    local record_result
    DEFAULTS_CONFIG_CHANGED=false
    validate_defaults_config "$config_file" "${2:-}" || return 2
    while IFS='|' read -r domain key type value || [[ -n "$domain$key$type$value" ]]; do
        [[ -z "${domain// /}" ]] && continue
        apply_defaults_record "$domain" "$key" "$type" "$value"
        record_result=$?
        # Shared state is read by another sourced module.
        # shellcheck disable=SC2034
        [[ "$DEFAULTS_RECORD_CHANGED" != true ]] || DEFAULTS_CONFIG_CHANGED=true
        [[ $record_result -eq 0 ]] || return 2
    done < "$config_file"
    return 0
}

# Only generated records in a selected category, never the entire allowlist.
verify_macos_scalar_category() {
    local category="$1" config_file="$2" domain key type expected result any=false
    local MACOS_OBSERVED_RECORDS=''
    verification_category_selected "macos-$category" || return 0
    if ! validate_defaults_config "$config_file" "$category"; then
        verification_input_error "macos-$category"
        return 0
    fi
    if ! macos_observe_config "$config_file" "$category"; then
        verification_input_error "macos-$category"
        return 0
    fi
    while IFS='|' read -r domain key type expected || [[ -n "$domain$key$type$expected" ]]; do
        [[ -n "${domain// /}" ]] || continue
        any=true
        verification_coverage "macos-$category" "$domain/$key" resolved unknown
        check_defaults_record "$domain" "$key" "$type" "$expected"
        result=$?
        if [[ "${CV_ACTIVE:-false}" == true && $result -eq 2 &&
              "$DEFAULTS_OBSERVATION_KIND" == different ]]; then result=1; fi
        verification_result "macos-$category" "$domain/$key" stored_preference "$result" '' "$DEFAULTS_OBSERVATION_KIND" || return 2
    done < "$config_file"
    [[ "$any" == true ]] || verification_coverage "macos-$category" scope no_requirement unknown
    return 0
}

# As in Capture, this child admits only native defaults reads inside the owned
# observer. It reuses the production comparison and byte-validation helpers.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ $# -eq 4 && "$1" == --observe-config && "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]] || exit 2
    case "$3" in finder|dock|windows|keyboard|trackpad) ;; *) exit 2 ;; esac
    [[ -f "$4" && ! -L "$4" && -w "$4" ]] || exit 2
    source modules/core/common/common.sh || exit 2
    source modules/core/logger/logger.sh || exit 2
    VERBOSE=false
    application_observe() {
        [[ $# -eq 5 && "$2" == defaults ]] || return 2
        case "$1:$3" in local:read|local-diagnostic:read-type) ;; *) return 2 ;; esac
        shift
        "$@"
    }
    validate_defaults_config "$2" "$3" || exit 2
    while IFS='|' read -r domain key type expected || [[ -n "$domain$key$type$expected" ]]; do
        [[ -n "${domain// /}" ]] || continue
        check_defaults_record "$domain" "$key" "$type" "$expected"
        result=$?
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$domain" "$key" "$type" "$expected" \
            "$result" "$DEFAULTS_OBSERVATION_KIND" "$DEFAULTS_OBSERVED_PRESENT" "$DEFAULTS_OBSERVED_VALUE" >> "$4" || exit 2
    done < "$2"
    exit 0
fi
