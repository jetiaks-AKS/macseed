#!/bin/bash
# Local development build without distribution signing from the same sources as the Xcode target.
set -euo pipefail
cd "$(dirname "$0")"
configuration="${1:-Debug}"
case "$configuration" in Debug|Release) ;; *) echo 'Usage: ./build.sh [Debug|Release] [--test]' >&2; exit 2 ;; esac
if [[ $# -gt 2 || ( $# -eq 2 && "$2" != --test ) ]]; then
    echo 'Usage: ./build.sh [Debug|Release] [--test]' >&2
    exit 2
fi
# One inventory drives execution and the optional CI summary. Counts are suite
# invocations, never assertions; compilation and execution are separate stages.
suites=(PresentationTests DiagnosticReportTests OperationLogViewTests OperationLogTests
    CoreRuntimeTests EnvironmentStatusTests CaptureTests RestoreTests)
restore_subsets=(--final-restore-ux-only --assisted-appstore-only)
stages=("$configuration app build")
if [[ "${2:-}" == --test ]]; then
    for suite in "${suites[@]}"; do stages+=("Compile $suite" "$suite"); done
    for subset in "${restore_subsets[@]}"; do stages+=("RestoreTests $subset"); done
    if [[ "$configuration" == Release ]]; then stages+=("Release sample exclusion"); fi
fi
stage_results=()
stage_seconds=()
stage_index=0
stage_started=0
build_started=$SECONDS

finish() {
    local status=$? index
    trap - EXIT
    if [[ "${stage_results[$stage_index]:-}" == running ]]; then
        stage_results[$stage_index]=failed
        stage_seconds[$stage_index]=$((SECONDS - stage_started))
        printf 'FAIL: %s (exit %s)\n' "${stages[$stage_index]}" "$status" >&2
    fi
    if [[ -n "${MACSEED_DESKTOP_SUMMARY:-}" ]]; then
        {
            printf '### Desktop build/test\n\nExit status: %s. Elapsed: %s s.\n\n' "$status" "$((SECONDS - build_started))"
            printf '| Stage | Result | Elapsed (s) |\n|---|---|---|\n'
            for ((index=0; index<${#stages[@]}; index++)); do
                printf '| %s | %s | %s |\n' "${stages[$index]}" "${stage_results[$index]:-not-run}" "${stage_seconds[$index]:-—}"
            done
            printf '\nAssertion counts: unknown (suite process exit status only).\n'
        } > "$MACSEED_DESKTOP_SUMMARY" || exit 1
    fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_stage() {
    stage_started=$SECONDS
    stage_results[$stage_index]=running
    printf 'Running: %s\n' "${stages[$stage_index]}"
    # Keep errexit active inside build functions; do not invoke this in an if/||.
    "$@"
    stage_results[$stage_index]=passed
    stage_seconds[$stage_index]=$((SECONDS - stage_started))
    stage_index=$((stage_index + 1))
}

build_app() {
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    architecture="$(uname -m)"
    output_dir="$PWD/build/$configuration"
    mkdir -p "$output_dir/module-cache" "$output_dir/Macseed.app/Contents/MacOS"
    compiler_options=(-sdk "$sdk_path" -target "$architecture-apple-macosx14.0" -swift-version 5
        -module-cache-path "$output_dir/module-cache")
    if [[ "$configuration" == Debug ]]; then compiler_options+=(-D DEBUG -Onone -g); else compiler_options+=(-O); fi
    xcrun swiftc "${compiler_options[@]}" -parse-as-library Sources/*.swift -o "$output_dir/Macseed.app/Contents/MacOS/Macseed"
    cp Info.plist "$output_dir/Macseed.app/Contents/Info.plist"
    ./prepare-runtime.sh "$output_dir/Macseed.app/Contents/Resources"
    cp Resources/Macseed.icns "$output_dir/Macseed.app/Contents/Resources/Macseed.icns"
    /usr/bin/plutil -lint "$output_dir/Macseed.app/Contents/Info.plist"
    if [[ "$run_tests" == true ]]; then
        core_root="$(cd ../.. && pwd -P)"
        python_runtime="$(xcrun --find python3)"
    fi
}
run_tests=false
if [[ "${2:-}" == --test ]]; then run_tests=true; fi
run_stage build_app
if [[ "${2:-}" == --test ]]; then
    presentation_sources=()
    for source_file in Sources/*.swift; do
        if [[ "$source_file" != Sources/MacseedApp.swift ]]; then presentation_sources+=("$source_file"); fi
    done
    for suite in "${suites[@]}"; do
        test_sources=("${presentation_sources[@]}")
        case "$suite" in
            OperationLogTests|CoreRuntimeTests) test_sources=(Sources/Core*.swift Sources/OperationLog.swift) ;;
        esac
        run_stage xcrun swiftc "${compiler_options[@]}" -parse-as-library "${test_sources[@]}" "Tests/$suite.swift" \
            -o "$output_dir/$suite"
        test_arguments=()
        case "$suite" in
            CoreRuntimeTests|EnvironmentStatusTests|CaptureTests|RestoreTests) test_arguments+=("$core_root" "$python_runtime") ;;
        esac
        case "$suite" in CaptureTests|RestoreTests) test_arguments+=(--no-renders) ;; esac
        # Bash 3.2 treats an empty array as unset with nounset enabled.
        run_stage "$output_dir/$suite" ${test_arguments[@]+"${test_arguments[@]}"}
    done
    for subset in "${restore_subsets[@]}"; do
        run_stage "$output_dir/RestoreTests" "$core_root" "$python_runtime" "$subset" --no-renders
    done
    if [[ "$configuration" == Release ]]; then
        check_release_samples() {
            if /usr/bin/strings "$output_dir/Macseed.app/Contents/MacOS/Macseed" | /usr/bin/grep -E 'Demo States|Next Sample Event|Personal SSH key|SampleProvider' >/dev/null; then
                echo 'FAIL: sample UI/provider leaked into Release' >&2
                exit 1
            fi
            echo 'PASS: Release excludes sample provider and demo controls'
        }
        run_stage check_release_samples
    fi
fi
test "$stage_index" -eq "${#stages[@]}"
printf 'Built %s\n' "$output_dir/Macseed.app"
