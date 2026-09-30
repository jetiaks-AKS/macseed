#!/bin/bash

# ==========================================
# App Store Discovery
# ==========================================

serialize_appstore_inventory() {

    local output_file="$1"
    local inventory="$2"

    [[ -z "$inventory" ]] && return 0

    awk '{
        app_id=$1
        $1=""
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+\([^()]+\)$/, "")
        print app_id "|" $0
    }' > "$output_file" <<< "$inventory" || return 2

    return 0

}

# ==========================================

discover_appstore() {

    if ! command -v mas >/dev/null 2>&1; then

        warning "mas is not installed"
        return 1

    fi

    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/appstore.conf"

    action "Exporting App Store applications..."

    local inventory
    if ! inventory="$(MAS_NO_AUTO_INDEX=1 mas list)"; then
        error "Failed to inventory App Store applications"
        return 2
    fi

    if ! discovery_publish_file "$output_file" serialize_appstore_inventory "$inventory"; then
        error "Failed to publish App Store applications"
        return 2
    fi

    provenance_publish app-store || return 2

    local app_count
    app_count=$(wc -l < "$output_file" | tr -d ' ')

    if [[ "$VERBOSE" == true ]]; then

        while IFS="|" read -r app_id app_name; do

            [[ -z "$app_id" ]] && continue

            detail "$app_id  $app_name"

        done < "$output_file"

    fi

    success "$app_count App Store application(s) exported"

}
