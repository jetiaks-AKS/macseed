#!/bin/bash

# ==========================================
# Logger
# ==========================================

LOG_DIR="logs"
LOG_HISTORY_DIR="$LOG_DIR/history"
LOG_FILE=""
LATEST_LOG="$LOG_DIR/latest.log"
LOG_PREFIX="unknown"

START_TIME=0
LOGGER_CLOSED=false

# ==========================================
# Initialize Logger
# ==========================================

init_logger() {

    mkdir -p "$LOG_HISTORY_DIR"

    local timestamp
    timestamp="$(date +"%Y-%m-%d_%H-%M-%S")"

    case "$MODE" in
        --bootstrap)
            LOG_PREFIX="bootstrap"
            ;;
        --discover)
            LOG_PREFIX="discover"
            ;;
        --blueprint)
            LOG_PREFIX="blueprint"
            ;;
        --check)
            LOG_PREFIX="check"
            ;;
        --dry-run)
            LOG_PREFIX="preview"
            ;;
        --compare)
            LOG_PREFIX="compare"
            ;;
        *)
            LOG_PREFIX="unknown"
            ;;
    esac

    LOG_FILE="$LOG_HISTORY_DIR/${LOG_PREFIX}-${timestamp}.log"

    touch "$LOG_FILE"

    START_TIME=$(date +%s)

    log "=========================================="
    log " Macseed — Capture. Rebuild. Continue."
    log "=========================================="
    log ""
    log "Version  : $TOOLKIT_VERSION"

    case "$MODE" in
        --bootstrap)
            log "Mode     : Bootstrap"
            ;;
        --discover)
            log "Mode     : Discovery"
            ;;
        --blueprint)
            log "Mode     : Blueprint"
            ;;
        --check)
            log "Mode     : Check"
            ;;
        --dry-run)
            log "Mode     : Preview"
            ;;
        --compare)
            log "Mode     : Environment Comparison"
            ;;
        *)
            log "Mode     : Unknown"
            ;;
    esac

    if [[ "$VERBOSE" == true ]]; then
        log "Verbose  : Yes"
    else
        log "Verbose  : No"
    fi

    log ""
    log "Started  : $(date '+%Y-%m-%d %H:%M:%S')"
    log ""
    log "=========================================="

    trap 'handle_interrupt' INT TERM
}

# ==========================================
# Write Message To Log
# ==========================================

log() {

    [[ -n "$LOG_FILE" ]] || return 0

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    printf '%s %s\n' "$timestamp" "$1" >> "$LOG_FILE"
}

# ==========================================
# Handle Interruption
# ==========================================

handle_interrupt() {

    [[ "$LOGGER_CLOSED" == true ]] && exit 130

    log ""
    log "[WARN] Toolkit interrupted"
    log "Finished : $(date '+%Y-%m-%d %H:%M:%S')"

    local end_time
    local duration

    end_time=$(date +%s)
    duration=$((end_time - START_TIME))

    log "Duration : ${duration}s"
    log "Status   : Interrupted"
    log ""
    log "=========================================="

    cp "$LOG_FILE" "$LATEST_LOG"

    LOGGER_CLOSED=true

    exit 130
}

# ==========================================
# Finalize Logger
# ==========================================

close_logger() {

    [[ -n "$LOG_FILE" ]] || return 0
    [[ "$LOGGER_CLOSED" == true ]] && return 0

    local end_time
    local duration

    end_time=$(date +%s)
    duration=$((end_time - START_TIME))

    log ""
    log "Finished : $(date '+%Y-%m-%d %H:%M:%S')"
    log "Duration : ${duration}s"
    log ""
    log "=========================================="

    cp "$LOG_FILE" "$LATEST_LOG"

    LOGGER_CLOSED=true
}
