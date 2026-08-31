#!/bin/sh

set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
diagnostic=$repo_root/scripts/kinamp-diagnostic
test_root=$(mktemp -d "${TMPDIR:-/tmp}/kinamp-diagnostic-test.XXXXXX")

cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_status() {
    expected=$1
    [ "$run_status" -eq "$expected" ] || {
        printf '%s\n' "$run_output" >&2
        fail "expected exit $expected, got $run_status"
    }
}

assert_contains() {
    needle=$1
    haystack=$2
    printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1 || {
        printf '%s\n' "$haystack" >&2
        fail "output did not contain: $needle"
    }
}

assert_not_contains() {
    needle=$1
    haystack=$2
    if printf '%s\n' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1; then
        printf '%s\n' "$haystack" >&2
        fail "output unexpectedly contained: $needle"
    fi
}

run_capture() {
    run_status=0
    run_output=$("$@" 2>&1) || run_status=$?
}

make_runtime() {
    fixture=$1
    mkdir -p "$fixture/runtime"
    mkfifo "$fixture/runtime/kinamp_cmd"
}

write_idle_status() {
    fixture=$1
    printf '%s\n' \
        "pid=$$" \
        'state=stopped' \
        'mode=audio' \
        'index=-1' \
        'count=1' \
        'path=/very/private/secret-audio.mp3' \
        'playlist=/very/private/secret-playlist.m3u' \
        'pos=0' \
        'dur=0' \
        'version=3.0.0' \
        'token=status-secret-that-must-not-print' \
        > "$fixture/runtime/kinamp_status"
}

make_package() {
    fixture=$1
    mkdir -p "$fixture/KinAMP" "$fixture/libs" "$fixture/koreader"
    printf '%s\n' '#!/bin/sh' \
        "printf launcher-was-executed > '$fixture/launcher-marker'" \
        > "$fixture/KinAMP/startkinamp_koreader.sh"
    printf '%s\n' '#!/bin/sh' \
        "printf binary-was-executed > '$fixture/binary-marker'" \
        > "$fixture/KinAMP/KinAMP-minimal"
    printf '%s\n' '3.0.0' > "$fixture/KinAMP/VERSION"
    printf '%s\n' '2026.07.1' > "$fixture/koreader/git-rev"
    chmod 755 "$fixture/KinAMP/startkinamp_koreader.sh" \
        "$fixture/KinAMP/KinAMP-minimal"
}

make_clean_ldd() {
    fixture=$1
    printf '%s\n' '#!/bin/sh' \
        "printf '%s\\n' 'linux-vdso.so.1 (0x0)' 'libc.so.6 => /lib/libc.so.6 (0x0)'" \
        > "$fixture/ldd"
    chmod 755 "$fixture/ldd"
}

make_missing_faad_ldd() {
    fixture=$1
    printf '%s\n' '#!/bin/sh' \
        "printf '%s\\n' 'libfaad.so.2 => not found' 'libmystery.so.1 => not found'" \
        > "$fixture/ldd"
    chmod 755 "$fixture/ldd"
}

test_help_and_validation() {
    run_capture "$diagnostic" --help
    assert_status 0
    assert_contains '--status-file' "$run_output"
    assert_contains '--skip-dependencies' "$run_output"
    assert_contains 'libfaad.so.2' "$run_output"
    assert_contains 'Exit status:' "$run_output"

    run_capture "$diagnostic" --runtime-dir=
    assert_status 1
    assert_contains 'ERROR:' "$run_output"
}

test_healthy_idle() {
    fixture=$test_root/healthy
    make_runtime "$fixture"
    write_idle_status "$fixture"
    make_package "$fixture"
    make_clean_ldd "$fixture"

    run_capture "$diagnostic" \
        --runtime-dir "$fixture/runtime" \
        --kinamp-dir "$fixture/KinAMP" \
        --libs-dir "$fixture/libs" \
        --ldd "$fixture/ldd" \
        --koreader-dir "$fixture/koreader"
    assert_status 0
    assert_contains 'CHECK runtime.command_fifo: PASS - type=FIFO' "$run_output"
    assert_contains 'CHECK runtime.status_file: PASS - type=regular-file' "$run_output"
    assert_contains 'state=stopped' "$run_output"
    assert_contains 'media=secret-audio.mp3' "$run_output"
    assert_contains 'playlist=secret-playlist.m3u' "$run_output"
    assert_contains 'version=3.0.0' "$run_output"
    assert_contains 'version.koreader: PASS - evidence=2026.07.1' "$run_output"
    assert_contains 'SUMMARY: READY' "$run_output"
    assert_not_contains '/very/private/' "$run_output"
    assert_not_contains 'status-secret-that-must-not-print' "$run_output"
}

test_missing_runtime_files() {
    fixture=$test_root/missing
    run_capture "$diagnostic" --runtime-dir "$fixture/runtime"
    assert_status 2
    assert_contains 'CHECK runtime.directory: FAIL' "$run_output"
    assert_contains 'CHECK runtime.command_fifo: FAIL - missing' "$run_output"
    assert_contains 'CHECK runtime.status_file: FAIL - missing' "$run_output"
    assert_contains 'SUMMARY: PROBLEM' "$run_output"
}

test_malformed_and_oversized_status() {
    fixture=$test_root/malformed
    make_runtime "$fixture"
    printf '%s\n' 'state=playing' 'not-a-status-field' \
        'path=/do/not/print.wav' > "$fixture/runtime/kinamp_status"
    run_capture "$diagnostic" --runtime-dir "$fixture/runtime"
    assert_status 2
    assert_contains 'CHECK runtime.status_fields: FAIL' "$run_output"
    assert_not_contains '/do/not/' "$run_output"

    fixture=$test_root/oversized
    make_runtime "$fixture"
    {
        printf '%s\n' 'state=stopped'
        index=0
        while [ "$index" -lt 17000 ]; do
            printf x
            index=$((index + 1))
        done
    } > "$fixture/runtime/kinamp_status"
    run_capture "$diagnostic" --runtime-dir "$fixture/runtime"
    assert_status 2
    assert_contains 'status exceeds the 16384-byte read limit' "$run_output"
}

test_missing_library() {
    fixture=$test_root/missing-library
    make_runtime "$fixture"
    write_idle_status "$fixture"
    make_package "$fixture"
    make_missing_faad_ldd "$fixture"

    run_capture "$diagnostic" \
        --runtime-dir "$fixture/runtime" \
        --kinamp-dir "$fixture/KinAMP" \
        --libs-dir "$fixture/libs" \
        --ldd "$fixture/ldd"
    assert_status 2
    assert_contains 'CHECK kinamp.dependencies: FAIL - ldd reports missing=libfaad.so.2,libmystery.so.1' "$run_output"
    assert_contains 'CHECK kinamp.dependency.libfaad.so.2: FAIL' "$run_output"
    assert_contains 'restore KinAMP/libs_hf' "$run_output"
    assert_not_contains '/very/private/' "$run_output"
}

test_missing_optional_tools() {
    fixture=$test_root/missing-tools
    make_runtime "$fixture"
    write_idle_status "$fixture"
    make_package "$fixture"
    tools=$fixture/tools
    mkdir -p "$tools"
    for tool in awk dd head stat tr wc uname; do
        tool_path=$(command -v "$tool") || fail "missing host tool: $tool"
        ln -s "$tool_path" "$tools/$tool"
    done

    run_status=0
    run_output=$(PATH="$tools" "$diagnostic" \
        --runtime-dir "$fixture/runtime" \
        --kinamp-dir "$fixture/KinAMP" 2>&1) || run_status=$?
    assert_status 3
    assert_contains 'CHECK tool.readlink: INFO - unavailable' "$run_output"
    assert_contains 'CHECK kinamp.dependencies: INFO - ldd is unavailable' "$run_output"
    assert_contains 'SUMMARY: INCOMPLETE' "$run_output"
}

test_read_only_behavior() {
    fixture=$test_root/read-only
    make_runtime "$fixture"
    write_idle_status "$fixture"
    make_package "$fixture"
    make_clean_ldd "$fixture"
    before_status=$(cat "$fixture/runtime/kinamp_status")

    run_capture "$diagnostic" \
        --runtime-dir "$fixture/runtime" \
        --kinamp-dir "$fixture/KinAMP" \
        --libs-dir "$fixture/libs" \
        --ldd "$fixture/ldd"
    assert_status 0
    after_status=$(cat "$fixture/runtime/kinamp_status")
    [ "$before_status" = "$after_status" ] || fail 'status file changed'
    [ -p "$fixture/runtime/kinamp_cmd" ] || fail 'command FIFO changed or disappeared'
    [ -f "$fixture/KinAMP/startkinamp_koreader.sh" ] || fail 'launcher disappeared'
    [ -f "$fixture/KinAMP/KinAMP-minimal" ] || fail 'binary disappeared'
    [ ! -e "$fixture/launcher-marker" ] || fail 'launcher was executed'
    [ ! -e "$fixture/binary-marker" ] || fail 'KinAMP binary was executed'

    if grep -E '(^|[[:space:];])(rm|mv|cp|mkdir|mkfifo|touch|ln|kill|pkill|killall)([[:space:];]|$)' \
        "$diagnostic" >/dev/null 2>&1; then
        fail 'diagnostic contains a mutating or signaling command'
    fi
}

test_help_and_validation
test_healthy_idle
test_missing_runtime_files
test_malformed_and_oversized_status
test_missing_library
test_missing_optional_tools
test_read_only_behavior

printf '%s\n' 'kinamp diagnostic shell tests: PASS'
