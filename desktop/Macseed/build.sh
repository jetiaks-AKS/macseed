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
suites=(PresentationTests SettingsTests HomebrewSetupTests HomebrewPackageTests HomebrewLaunchTests DiagnosticReportTests OperationLogViewTests OperationLogTests
    CoreRuntimeTests EnvironmentStatusTests CaptureTests RestoreTests)
restore_subsets=(--final-restore-ux-only --assisted-appstore-only)
stages=("$configuration app build")
if [[ "${2:-}" == --test ]]; then
    stages+=("BundledAgeTests (Python)")
    if [[ "$configuration" == Debug ]]; then stages+=("Compile shared test sources"); fi
    for suite in "${suites[@]}"; do stages+=("Compile $suite" "$suite"); done
    for subset in "${restore_subsets[@]}"; do stages+=("RestoreTests $subset"); done
    if [[ "$configuration" == Release ]]; then stages+=("Release sample exclusion"); fi
fi
stage_results=()
stage_seconds=()
stage_index=0
stage_started=0
build_started=$SECONDS

write_summary() {
    local status=$1 index
    if [[ -n "${MACSEED_DESKTOP_SUMMARY:-}" ]]; then
        {
            printf '### Desktop build/test\n\nExit status: %s. Elapsed: %s s.\n\n' "$status" "$((SECONDS - build_started))"
            printf '| Stage | Result | Elapsed (s) |\n|---|---|---|\n'
            for ((index=0; index<${#stages[@]}; index++)); do
                printf '| %s | %s | %s |\n' "${stages[$index]}" "${stage_results[$index]:-not-run}" "${stage_seconds[$index]:-—}"
            done
            printf '\nAssertion counts: unknown (suite process exit status only).\n'
        } > "$MACSEED_DESKTOP_SUMMARY.tmp" || return 1
        mv "$MACSEED_DESKTOP_SUMMARY.tmp" "$MACSEED_DESKTOP_SUMMARY"
    fi
}

finish() {
    local status=$?
    trap - EXIT
    if [[ "${stage_results[$stage_index]:-}" == running ]]; then
        stage_results[$stage_index]=failed
        stage_seconds[$stage_index]=$((SECONDS - stage_started))
        printf 'FAIL: %s (exit %s)\n' "${stages[$stage_index]}" "$status" >&2
    fi
    write_summary "$status" || exit 1
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_stage() {
    stage_started=$SECONDS
    stage_results[$stage_index]=running
    # Keep the current stage and all NOT RUN stages even after hosted SIGKILL.
    write_summary running
    printf 'Running: %s\n' "${stages[$stage_index]}"
    # Keep errexit active inside build functions; do not invoke this in an if/||.
    "$@"
    stage_results[$stage_index]=passed
    stage_seconds[$stage_index]=$((SECONDS - stage_started))
    stage_index=$((stage_index + 1))
    write_summary running
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
    ./prepare-runtime.sh "$output_dir/Macseed.app/Contents/Resources" "$architecture"
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
    # The unittest class prepares both pinned archives through prepare-age.py.
    # Reuse bounded execution, exact method reports and owned-process cleanup.
    run_stage "$python_runtime" -B ../../scripts/test_runner.py \
        desktop/Macseed/Tests/BundledAgeTests.py --
    presentation_sources=()
    for source_file in Sources/*.swift; do
        if [[ "$source_file" != Sources/MacseedApp.swift ]]; then presentation_sources+=("$source_file"); fi
    done
    test_compiler_options=("${compiler_options[@]}")
    # Retain Debug assertions, debug symbols and -Onone semantics while
    # avoiding repeated frontend work within each compilation.
    if [[ "$configuration" == Debug ]]; then test_compiler_options+=(-whole-module-optimization); fi
    if [[ "$configuration" == Debug ]]; then
        # Build the common production sources once per invocation. Test bodies
        # keep internal access and Debug assertions; no persistent result cache.
        shared_tests="$output_dir/test-support"
        mkdir -p "$shared_tests"
        run_stage xcrun swiftc "${test_compiler_options[@]}" -parse-as-library -enable-testing \
            -module-name MacseedTestSupport -emit-module \
            -emit-module-path "$shared_tests/MacseedTestSupport.swiftmodule" \
            -emit-object "${presentation_sources[@]}" -o "$shared_tests/MacseedTestSupport.o"
    fi
    compile_test() {
        local suite=$1
        case "$suite" in
            OperationLogTests|CoreRuntimeTests)
                # Preserve these transport/storage suites' smaller source set.
                xcrun swiftc "${test_compiler_options[@]}" -parse-as-library \
                    Sources/Core*.swift Sources/OperationLog.swift "Tests/$suite.swift" -o "$output_dir/$suite"
                ;;
            *)
                if [[ "$configuration" == Debug ]]; then
                    # Preserve #filePath and diagnostics for source-reading tests.
                    {
                        printf '@testable import MacseedTestSupport\n'
                        printf '#sourceLocation(file: "Tests/%s.swift", line: 1)\n' "$suite"
                        cat "Tests/$suite.swift"
                    } > "$shared_tests/$suite-entry.swift"
                    xcrun swiftc "${test_compiler_options[@]}" -parse-as-library -I "$shared_tests" \
                        "$shared_tests/$suite-entry.swift" "$shared_tests/MacseedTestSupport.o" -o "$output_dir/$suite"
                else
                    xcrun swiftc "${test_compiler_options[@]}" -parse-as-library \
                        "${presentation_sources[@]}" "Tests/$suite.swift" -o "$output_dir/$suite"
                fi
                ;;
        esac
    }
    for suite in "${suites[@]}"; do
        run_stage compile_test "$suite"
        test_arguments=()
        case "$suite" in
            SettingsTests) test_arguments+=("$core_root" "$python_runtime" "$output_dir/Macseed.app") ;;
            CoreRuntimeTests|EnvironmentStatusTests|CaptureTests|RestoreTests) test_arguments+=("$core_root" "$python_runtime") ;;
        esac
        case "$suite" in CaptureTests|RestoreTests) test_arguments+=(--no-renders) ;; esac
        # Bash 3.2 treats an empty array as unset with nounset enabled.
        if [[ "$suite" == PresentationTests ]]; then
            # Independent of AppKit/MainActor: a stuck native call cannot starve
            # the deadline. CI #151 took 83 s; preserve the 45-minute job cap.
            run_stage "$python_runtime" ../../scripts/desktop_test_runner.py --timeout 600 \
                "$output_dir/$suite" ${test_arguments[@]+"${test_arguments[@]}"}
        else
            run_stage "$output_dir/$suite" ${test_arguments[@]+"${test_arguments[@]}"}
        fi
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
