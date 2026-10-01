#!/bin/bash

BUNDLE_HELPER="modules/bundle/bundle.py"

bundle_prompt() {
    local answer
    [[ "${MACSEED_APPLICATION_EXECUTION:-false}" != true ]] || return 2
    printf '%s ' "$1"
    IFS= read -r answer || return 1
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]
}

bundle_offer_age() {
    command -v age >/dev/null 2>&1 && return 0
    if ! command -v brew >/dev/null 2>&1; then
        error "age is required for secure SSH identities; Homebrew is unavailable"
        return 2
    fi
    bundle_prompt "Install age with Homebrew now? [y/N]" || return 1
    brew install age || return 2
    command -v age >/dev/null 2>&1 || return 2
}

bundle_stage() {
    local temporary
    temporary="$(mktemp -d "${TMPDIR:-/tmp}/mbt-bundle.XXXXXX")" || return 2
    (cd "$temporary" && pwd -P)
}

bundle_capture() (
    umask 077
    local stage result output timestamp
    stage="$(bundle_stage)" || return 2
    trap 'rm -rf "$stage"' EXIT
    mkdir -m 700 "$stage/generated" || return 2
    info "Scanning supported state into private Capture staging."
    BLUEPRINT_FILE="$stage/blueprint.conf" BLUEPRINT_GENERATED_DIR="$stage/generated" \
        ./bootstrap.sh --discover
    result=$?
    [[ $result -le 1 ]] || return "$result"
    local tool inventory
    for tool in mas code; do
        case "$tool" in
            mas) inventory="$stage/generated/appstore.conf" ;;
            code) inventory="$stage/generated/vscode-extensions.conf" ;;
        esac
        if [[ ! -f "$inventory" && ! -L "$inventory" ]] &&
           ! command -v "$tool" >/dev/null 2>&1; then
            warning "$tool is unavailable; its application inventory was not captured."
            bundle_prompt "Continue Capture with no $tool items? [y/N]" || return 1
            (umask 077; : > "$inventory") || return 2
        fi
    done
    BUNDLE_CAPTURE_ACTIVE=true BLUEPRINT_FILE="$stage/blueprint.conf" BLUEPRINT_GENERATED_DIR="$stage/generated" \
        ./bootstrap.sh --blueprint || return 2
    if [[ ! -f "$stage/blueprint.conf" ]]; then
        info "Capture cancelled before selection was saved."
        return 0
    fi
    BLUEPRINT_FILE="$stage/blueprint.conf" BLUEPRINT_GENERATED_DIR="$stage/generated" \
        ./bootstrap.sh --dry-run
    result=$?
    [[ $result -le 1 ]] || return "$result"
    python3 "$BUNDLE_HELPER" check-portability "$stage" "$HOME" || return 2
    if [[ -e "$HOME/.ssh" || -L "$HOME/.ssh" ]] &&
       bundle_prompt "Select SSH identities for encrypted Secure Credentials? [y/N]"; then
        if bundle_offer_age; then
            ./scripts/ssh-identity-migrate.sh capture-export --output "$stage/secure.age"
            result=$?
            [[ $result -le 1 ]] || return "$result"
        else
            warning "Secure SSH export unavailable or declined."
            bundle_prompt "Continue Capture without SSH identities? [y/N]" || return 1
        fi
    fi
    timestamp="$(date +%Y%m%d-%H%M%S)" || return 2
    [[ ! -L exports ]] || { error "Unsafe exports directory"; return 2; }
    if [[ -e exports ]]; then
        [[ -d exports && "$(stat -f '%u' exports 2>/dev/null)" == "$(id -u)" ]] || {
            error "Unsafe exports directory"
            return 2
        }
    else
        mkdir -m 700 exports || return 2
    fi
    chmod 700 exports || return 2
    output="$(cd exports && pwd -P)/bootstrap-$timestamp.mbt"
    python3 "$BUNDLE_HELPER" pack "$stage" "$output" "$HOME" || return 2
    success "Bootstrap Bundle created: $output"
    info "Transfer this one private Bundle to the new Mac."
)

bundle_choose_categories() {
    local stage="$1" answer index state
    local -a names=("Applications" "Homebrew" "macOS Settings" "Shell" "Git" "SSH Configuration" "Workspace" "VS Code Settings")
    local -a disabled=()
    local -a groups=()
    BUNDLE_SECURE_SELECTED=true
    [[ -f "$stage/secure.age" ]] || BUNDLE_SECURE_SELECTED=false
    while true; do
        groups=()
        for index in "${disabled[@]}"; do groups+=("${names[$index]}"); done
        echo "Restore selection:"
        python3 "$BUNDLE_HELPER" summary "$stage" "$BUNDLE_SECURE_SELECTED" "${groups[@]}" || return 2
        printf 'Enter=continue, C=change categories, Q=cancel: '
        IFS= read -r answer || return 3
        case "$answer" in
            "") break ;;
            [qQ]) return 3 ;;
            [cC])
                for ((index=0; index<${#names[@]}; index++)); do
                    state=x
                    [[ " ${disabled[*]} " != *" $index "* ]] || state=" "
                    printf '  %d [%s] %s\n' "$((index+1))" "$state" "${names[$index]}"
                done
                printf '  9 [%s] Secure Credentials\n' "$([[ "$BUNDLE_SECURE_SELECTED" == true ]] && echo x || echo ' ')"
                printf 'Enter numbers to disable (comma separated), or Q: '
                IFS= read -r answer || return 3
                [[ "$answer" != [qQ] ]] || return 3
                [[ "$answer" =~ ^[1-9](,[1-9])*$ ]] || { warning "Use numbers 1-9."; continue; }
                local token
                IFS=, read -r -a tokens <<< "$answer"
                for token in "${tokens[@]}"; do
                    if [[ "$token" == 9 ]]; then
                        BUNDLE_SECURE_SELECTED=false
                    else
                        disabled+=("$((token-1))")
                    fi
                done
                ;;
            *) warning "Choose Enter, C or Q." ;;
        esac
    done
    groups=()
    for index in "${disabled[@]}"; do groups+=("${names[$index]}"); done
    python3 "$BUNDLE_HELPER" narrow "$stage" "${groups[@]}" || return 2
}

# Called only by Restore Bootstrap, after complete selected-input validation and
# preflight. Reuse the normal SSH consumer and the separate no-clobber importer.
bundle_restore_prerequisites() {
    local result
    if blueprint_category_enabled ssh-configuration && ssh_configuration_scope_selected; then
        bootstrap_ssh_configuration
        result=$?
        # A partial source can still publish all selected eligible profiles.
        # The normal later SSH pass retains that source warning in Summary.
        if [[ $result -ne 0 ]] &&
           ! [[ $result -eq 1 && "$SSH_TARGET_STATUS" == identical && "$SSH_SOURCE_PARTIAL" == true ]]; then
            error "Selected SSH configuration is not ready; dependent restoration stopped"
            return 2
        fi
    fi
    if [[ -n "${BUNDLE_RESTORE_SECURE_FILE:-}" ]]; then
        bundle_offer_age
        result=$?
        [[ $result -eq 0 ]] || return "$result"
        info "Secure Credentials: enter the Bundle passphrase created during Capture, not an SSH-key passphrase."
        secure_verification_import
        result=$?
        if [[ $result -ne 0 ]]; then
            warning "Secure SSH import did not complete; dependent restoration stopped"
            return "$result"
        fi
    fi
    return 0
}

bundle_restore() (
    umask 077
    local input="$1" stage result secure_selected
    [[ -n "$input" ]] || { error "Restore requires a Bundle path"; return 2; }
    stage="$(bundle_stage)" || return 2
    trap 'rm -rf "$stage"' EXIT
    python3 "$BUNDLE_HELPER" unpack "$input" "$stage" "$HOME" || return 2
    python3 "$BUNDLE_HELPER" recover || return 2
    bundle_choose_categories "$stage"
    result=$?
    if [[ $result -eq 3 ]]; then info "Restore cancelled."; return 0; fi
    [[ $result -eq 0 ]] || return "$result"
    secure_selected="$BUNDLE_SECURE_SELECTED"
    BUNDLE_RESTORE_PREVIEW=true BLUEPRINT_FILE="$stage/blueprint.conf" BLUEPRINT_GENERATED_DIR="$stage/generated" \
        ./bootstrap.sh --dry-run
    result=$?
    [[ $result -le 1 ]] || return "$result"
    bundle_prompt "Apply this selection with Bootstrap? [y/N]" || {
        info "Restore cancelled before publication."
        return 0
    }
    python3 "$BUNDLE_HELPER" publish "$stage" || return 2
    local secure_file=""
    [[ "$secure_selected" != true ]] || secure_file="$stage/secure.age"
    env -u BLUEPRINT_FILE -u BLUEPRINT_GENERATED_DIR -u SSH_SNAPSHOT_FILE \
        -u ZSH_SNAPSHOT_FILE BUNDLE_RESTORE_ACTIVE=true \
        BUNDLE_RESTORE_SECURE_FILE="$secure_file" ./bootstrap.sh --bootstrap
    result=$?
    if [[ $result -gt 1 ]]; then
        error "Restore Bootstrap did not complete; review applied changes before retrying."
        return "$result"
    fi
    if [[ $result -ne 0 ]]; then
        warning "Restore finished with warnings or a deferred prerequisite; review Bootstrap output before continuing."
        return "$result"
    fi
    success "Restore completed. Future bs workflow runs from ordinary local state."
    return "$result"
)
