#!/bin/bash
# One opt-in clock helper per Bootstrap, not a subprocess per measurement.
# The opt-in EXIT hook joins only this shell's clock; execution/Stop channels
# are unchanged. Reserved FDs and the EXIT hook are used only when free.
MACSEED_PERFORMANCE_ACTIVE=false
performance_trace_start() {
    [[ "${MACSEED_PERFORMANCE_TRACE:-}" == 1 && -n "${MACSEED_PERFORMANCE_TRACE_DIR:-}" ]] || return 0
    [[ -d "$MACSEED_PERFORMANCE_TRACE_DIR" && -O "$MACSEED_PERFORMANCE_TRACE_DIR" &&
       ! -L "$MACSEED_PERFORMANCE_TRACE_DIR" ]] || return 0
    [[ ! -e /dev/fd/18 && ! -e /dev/fd/19 ]] || return 0
    [[ -z "$(trap -p EXIT)" ]] || return 0
    local performance_channels
    performance_channels="$(mktemp -d "${MACSEED_PERFORMANCE_TRACE_DIR}/clock.XXXXXXXX")" || return 0
    if ! mkfifo "$performance_channels/request" "$performance_channels/response"; then
        rm -f "$performance_channels/request" "$performance_channels/response"
        rmdir "$performance_channels" 2>/dev/null
        return 0
    fi
    exec 18<>"$performance_channels/request" 19<>"$performance_channels/response"
    python3 -B modules/core/performance_trace.py "$$" <"$performance_channels/request" >"$performance_channels/response" 2>/dev/null &
    MACSEED_PERFORMANCE_PID=$!
    MACSEED_PERFORMANCE_OWNER_SUBSHELL=$BASH_SUBSHELL
    trap 'performance_trace_stop' EXIT
    MACSEED_PERFORMANCE_ACTIVE=true
    performance_trace_edge ready clock
    rm -f "$performance_channels/request" "$performance_channels/response"
    rmdir "$performance_channels"
}

performance_trace_stop() {
    [[ "$BASH_SUBSHELL" == "${MACSEED_PERFORMANCE_OWNER_SUBSHELL:-}" &&
       -n "${MACSEED_PERFORMANCE_PID:-}" ]] || return 0
    local performance_jobs performance_deadline
    performance_trace_edge finish clock
    MACSEED_PERFORMANCE_ACTIVE=false
    exec 18>&- 19>&-
    # A flush ACK is not process exit. Reap before the supervised shell exits;
    # a stuck optional helper gets a bounded stop, never a surviving worker.
    performance_deadline=$((SECONDS + 1))
    while :; do
        performance_jobs="$(jobs -pr; jobs -ps)"
        [[ $'\n'"$performance_jobs"$'\n' == *$'\n'"$MACSEED_PERFORMANCE_PID"$'\n'* ]] || break
        if ((SECONDS >= performance_deadline)); then
            kill -KILL "$MACSEED_PERFORMANCE_PID" 2>/dev/null
            break
        fi
        sleep 0.01
    done
    wait "$MACSEED_PERFORMANCE_PID" 2>/dev/null || :
    MACSEED_PERFORMANCE_PID=
    return 0
} 2>/dev/null

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
