#!/bin/bash
# One opt-in clock helper per Bootstrap, not a subprocess per measurement.
# No traps or execution/Stop channels are changed. Reserved FDs are used only
# when free; any diagnostic failure disables timing without failing the command.
MACSEED_PERFORMANCE_ACTIVE=false
performance_trace_start() {
    [[ "${MACSEED_PERFORMANCE_TRACE:-}" == 1 && -n "${MACSEED_PERFORMANCE_TRACE_DIR:-}" ]] || return 0
    [[ -d "$MACSEED_PERFORMANCE_TRACE_DIR" && -O "$MACSEED_PERFORMANCE_TRACE_DIR" &&
       ! -L "$MACSEED_PERFORMANCE_TRACE_DIR" ]] || return 0
    [[ ! -e /dev/fd/18 && ! -e /dev/fd/19 ]] || return 0
    local performance_channels
    performance_channels="$(mktemp -d "${MACSEED_PERFORMANCE_TRACE_DIR}/clock.XXXXXXXX")" || return 0
    if ! mkfifo "$performance_channels/request" "$performance_channels/response"; then
        rm -f "$performance_channels/request" "$performance_channels/response"
        rmdir "$performance_channels" 2>/dev/null
        return 0
    fi
    exec 18<>"$performance_channels/request" 19<>"$performance_channels/response"
    python3 -B modules/core/performance_trace.py "$$" <"$performance_channels/request" >"$performance_channels/response" 2>/dev/null &
    MACSEED_PERFORMANCE_ACTIVE=true
    performance_trace_edge ready clock
    rm -f "$performance_channels/request" "$performance_channels/response"
    rmdir "$performance_channels"
}

performance_trace_edge() {
    [[ "$MACSEED_PERFORMANCE_ACTIVE" == true ]] || return 0
    local performance_ack
    if ! { printf '%s %s\n' "$1" "$2" >&18 && IFS= read -r -t 1 performance_ack <&19 && [[ "$performance_ack" == ok ]]; }; then
        MACSEED_PERFORMANCE_ACTIVE=false
    fi
    return 0
}

performance_measure() {
    local performance_label="$1" performance_status
    shift
    if [[ "$MACSEED_PERFORMANCE_ACTIVE" == true && "$performance_label" == verification.* ]]; then
        local MACSEED_PERFORMANCE_SCOPE=verification MACSEED_PERFORMANCE_PHASE=verification
        export MACSEED_PERFORMANCE_SCOPE MACSEED_PERFORMANCE_PHASE
    fi
    if [[ "${MACSEED_PERFORMANCE_PHASE:-}" == verification && "$performance_label" == cask.* ]]; then
        performance_label="verification.$performance_label"
    fi
    performance_trace_edge begin "$performance_label"
    "$@"
    performance_status=$?
    performance_trace_edge end "$performance_label"
    return "$performance_status"
}
