#!/usr/bin/env bash
#
# Synthetic tests for the plugin runtime dispatcher. No real hook runtime or
# journal is used: small shims record which one process would have been exec'd.

set -u

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
if [[ $SCRIPT_DIR == "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR=.
fi
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P) || exit 1
SOURCE_LAUNCHER=$REPO_ROOT/hooks/devlog-plugin-launcher.sh
REAL_BASH=$(command -v bash) || {
    printf '%s\n' 'FAIL: bash is required to test the plugin launcher.' >&2
    exit 1
}
REAL_CAT=$(command -v cat) || {
    printf '%s\n' 'FAIL: cat is required to capture synthetic runtime stdin.' >&2
    exit 1
}
HOST_PLATFORM=$(uname -s 2>/dev/null) || exit 1
REAL_CYGPATH=$(command -v cygpath 2>/dev/null || :)
ORIGINAL_PATH=$PATH

FAILURES=0
CASE_NUMBER=0
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/devlog-plugin-test.XXXXXXXX") || exit 1

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
    FAILURES=$((FAILURES + 1))
    printf 'FAIL %s\n' "$1"
}

assert_eq() {
    local expected=$1
    local actual=$2
    local label=$3
    if [[ $actual != "$expected" ]]; then
        fail "$label (expected '$expected', got '$actual')"
    fi
}

assert_file_line() {
    local expected=$1
    local path=$2
    local label=$3
    if [[ ! -f $path ]] || ! grep -Fqx -- "$expected" "$path"; then
        fail "$label"
    fi
}

canonicalize_host_path() {
    local value=$1
    case $HOST_PLATFORM in
        MINGW* | MSYS* | CYGWIN*)
            [[ -n $REAL_CYGPATH ]] || return 1
            "$REAL_CYGPATH" -m -l -- "$value" 2>/dev/null
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}

assert_hook_argument() {
    local expected=$1
    local path=$2
    local label=$3
    local line=
    local actual=
    local expected_canonical
    local actual_canonical

    if [[ ! -f $path ]]; then
        fail "$label (argument trace is missing)"
        return
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        actual=$line
    done < "$path"
    expected_canonical=$(canonicalize_host_path "$expected") || {
        fail "$label (expected path could not be normalized)"
        return
    }
    actual_canonical=$(canonicalize_host_path "$actual") || {
        fail "$label (actual path could not be normalized)"
        return
    }
    assert_eq "$expected_canonical" "$actual_canonical" "$label"
}

make_runtime_shim() {
    local path=$1
    cat > "$path" <<'SHIM'
#!/bin/sh
runtime_name=${0##*/}
printf '%s\n' "$runtime_name" >> "$DEVLOG_TEST_TRACE"
printf '%s\n' "$@" > "$DEVLOG_TEST_ARGS"
printf '%s\n' "${CLAUDE_DEVLOG_DIR-}" > "$DEVLOG_TEST_DIR"
printf '%s\n' "${CLAUDE_DEVLOG_LANG-}" > "$DEVLOG_TEST_LANG"
"$DEVLOG_TEST_CAT" > "$DEVLOG_TEST_STDIN"
exit 0
SHIM
    chmod +x "$path"
}

make_uname_shim() {
    local path=$1
    cat > "$path" <<'SHIM'
#!/bin/sh
printf '%s\n' "$DEVLOG_TEST_UNAME"
SHIM
    chmod +x "$path"
}

make_cygpath_shim() {
    local path=$1
    cat > "$path" <<'SHIM'
#!/bin/sh
if [ "$#" -ne 3 ] || [ "$1" != '-m' ] || [ "$2" != '--' ]; then
    exit 2
fi
printf '%s\n' "$3"
SHIM
    chmod +x "$path"
}

make_failing_cygpath_shim() {
    local path=$1
    cat > "$path" <<'SHIM'
#!/bin/sh
exit 7
SHIM
    chmod +x "$path"
}

new_case() {
    CASE_NUMBER=$((CASE_NUMBER + 1))
    CASE_ROOT=$TEST_ROOT/case-$CASE_NUMBER
    SHIM_ROOT=$CASE_ROOT/shims
    PLUGIN_ROOT=$CASE_ROOT/plugin\ root
    mkdir -p -- "$SHIM_ROOT" "$PLUGIN_ROOT/hooks"
    cp -- "$SOURCE_LAUNCHER" "$PLUGIN_ROOT/hooks/devlog-plugin-launcher.sh"
    : > "$PLUGIN_ROOT/hooks/devlog-session-start.ps1"
    : > "$PLUGIN_ROOT/hooks/devlog-prompt-nudge.ps1"
    : > "$PLUGIN_ROOT/hooks/devlog-stop.ps1"
    : > "$PLUGIN_ROOT/hooks/devlog-session-start.sh"
    : > "$PLUGIN_ROOT/hooks/devlog-prompt-nudge.sh"
    : > "$PLUGIN_ROOT/hooks/devlog-stop.sh"
    TRACE_FILE=$CASE_ROOT/trace
    ARGS_FILE=$CASE_ROOT/args
    DIR_FILE=$CASE_ROOT/dir
    LANG_FILE=$CASE_ROOT/lang
    STDIN_FILE=$CASE_ROOT/stdin
    STDOUT_FILE=$CASE_ROOT/stdout
    STDERR_FILE=$CASE_ROOT/stderr
    make_uname_shim "$SHIM_ROOT/uname"
}

run_launcher() {
    local platform=$1
    local event=$2
    local payload=$3
    local plugin_dir=$4
    local legacy_dir=$5
    local plugin_lang=$6
    local legacy_lang=$7
    local path_value=$8

    (
        export PATH=$path_value
        export DEVLOG_TEST_UNAME=$platform
        export DEVLOG_TEST_TRACE=$TRACE_FILE
        export DEVLOG_TEST_ARGS=$ARGS_FILE
        export DEVLOG_TEST_DIR=$DIR_FILE
        export DEVLOG_TEST_LANG=$LANG_FILE
        export DEVLOG_TEST_STDIN=$STDIN_FILE
        export DEVLOG_TEST_CAT=$REAL_CAT
        export CLAUDE_PLUGIN_OPTION_DEVLOG_DIR=$plugin_dir
        export CLAUDE_DEVLOG_DIR=$legacy_dir
        export CLAUDE_PLUGIN_OPTION_DEVLOG_LANG=$plugin_lang
        export CLAUDE_DEVLOG_LANG=$legacy_lang
        printf '%s' "$payload" |
            "$REAL_BASH" --noprofile --norc "$PLUGIN_ROOT/hooks/devlog-plugin-launcher.sh" "$event"
    ) > "$STDOUT_FILE" 2> "$STDERR_FILE"
}

run_success_case() {
    local platform=$1
    local event=$2
    local runtime=$3
    local hook_file=$4
    local plugin_dir=$5
    local legacy_dir=$6
    local plugin_lang=$7
    local legacy_lang=$8
    local payload='{"session_id":"synthetic"}'

    new_case
    make_runtime_shim "$SHIM_ROOT/$runtime"
    set +e
    run_launcher "$platform" "$event" "$payload" "$plugin_dir" "$legacy_dir" \
        "$plugin_lang" "$legacy_lang" "$SHIM_ROOT"
    local status=$?
    set -e

    assert_eq 0 "$status" "$platform/$event should succeed"
    assert_file_line "$runtime" "$TRACE_FILE" "$platform/$event should select $runtime"
    local invocation_count=0
    if [[ -f $TRACE_FILE ]]; then
        invocation_count=$(wc -l < "$TRACE_FILE" | tr -d ' ')
    fi
    assert_eq 1 "$invocation_count" "$platform/$event must execute one runtime only"
    assert_hook_argument "$PLUGIN_ROOT/hooks/$hook_file" "$ARGS_FILE" "$platform/$event should select $hook_file"
    assert_eq "$payload" "$(cat "$STDIN_FILE")" "$platform/$event must forward stdin unchanged"
    assert_eq '' "$(cat "$STDOUT_FILE")" "$platform/$event launcher must add no stdout"
    assert_eq '' "$(cat "$STDERR_FILE")" "$platform/$event launcher must add no stderr"
}

if [[ ! -f $SOURCE_LAUNCHER ]]; then
    printf '%s\n' 'FAIL: hooks/devlog-plugin-launcher.sh is missing.'
    exit 1
fi
if [[ ! -x $SOURCE_LAUNCHER ]]; then
    printf '%s\n' 'FAIL: hooks/devlog-plugin-launcher.sh is not executable.'
    exit 1
fi

# Git for Windows maps /tmp to the runner's native temporary directory. Prove
# that an implicitly converted native argument still compares equal to the
# original POSIX fixture path before testing runtime selection.
case $HOST_PLATFORM in
    MINGW* | MSYS* | CYGWIN*)
        path_probe_expected=$TEST_ROOT/'canonical probe ; dollar $() amp & brackets []'
        : > "$path_probe_expected"
        path_probe_short=$("$REAL_CYGPATH" -m -s -- "$path_probe_expected") || exit 1
        path_probe_argument=$("$REAL_CYGPATH" -u -- "$path_probe_short") || exit 1
        path_probe_trace=$TEST_ROOT/canonical-path.trace
        printf '%s\n' "$path_probe_argument" > "$path_probe_trace"
        assert_hook_argument "$path_probe_expected" "$path_probe_trace" \
            'Native and POSIX host paths must canonicalize to one target'
        ;;
esac

# Three fixed events map to the three fixed Bash entrypoints.
run_success_case Linux session-start bash devlog-session-start.sh \
    '/tmp/plugin path with spaces' '/tmp/legacy' en ja
assert_eq '/tmp/plugin path with spaces' "$(cat "$DIR_FILE")" 'Plugin directory option must win and preserve spaces'
assert_eq en "$(cat "$LANG_FILE")" 'Plugin language option must win'

run_success_case Linux prompt-nudge bash devlog-prompt-nudge.sh \
    '' '/tmp/legacy path' '' en
assert_eq '/tmp/legacy path' "$(cat "$DIR_FILE")" 'Blank plugin directory must preserve legacy directory'
assert_eq en "$(cat "$LANG_FILE")" 'Blank plugin language must preserve legacy language'

run_success_case Darwin stop bash devlog-stop.sh \
    '/tmp/plugin' '/tmp/legacy' ja en

# Windows selection is deterministic: pwsh, Windows PowerShell, then Bash.
new_case
make_cygpath_shim "$SHIM_ROOT/cygpath"
make_runtime_shim "$SHIM_ROOT/pwsh"
make_runtime_shim "$SHIM_ROOT/powershell.exe"
make_runtime_shim "$SHIM_ROOT/bash"
set +e
run_launcher MINGW64_NT-10.0 session-start '{"session_id":"win-pwsh"}' \
    '/tmp/plugin' '/tmp/legacy' ja en "$SHIM_ROOT"
status=$?
set -e
assert_eq 0 "$status" 'Windows pwsh selection should succeed'
assert_file_line pwsh "$TRACE_FILE" 'Windows should prefer pwsh'
assert_eq 1 "$(wc -l < "$TRACE_FILE" | tr -d ' ')" 'Windows pwsh selection must execute once'

new_case
make_cygpath_shim "$SHIM_ROOT/cygpath"
make_runtime_shim "$SHIM_ROOT/powershell.exe"
make_runtime_shim "$SHIM_ROOT/bash"
set +e
run_launcher MSYS_NT-10.0 stop '{"session_id":"win-ps51"}' \
    '/tmp/plugin' '/tmp/legacy' ja en "$SHIM_ROOT"
status=$?
set -e
assert_eq 0 "$status" 'Windows PowerShell 5.1 selection should succeed'
assert_file_line powershell.exe "$TRACE_FILE" 'Windows should fall back to Windows PowerShell'
assert_eq 1 "$(wc -l < "$TRACE_FILE" | tr -d ' ')" 'Windows PowerShell selection must execute once'

new_case
make_cygpath_shim "$SHIM_ROOT/cygpath"
make_runtime_shim "$SHIM_ROOT/bash"
set +e
run_launcher CYGWIN_NT-10.0 prompt-nudge '{"session_id":"win-bash"}' \
    '/tmp/plugin' '/tmp/legacy' ja en "$SHIM_ROOT"
status=$?
set -e
assert_eq 0 "$status" 'Windows Bash fallback should succeed'
assert_file_line bash "$TRACE_FILE" 'Windows should fall back to Bash'
assert_eq 1 "$(wc -l < "$TRACE_FILE" | tr -d ' ')" 'Windows Bash selection must execute once'

# Run the real dispatcher and one real selected hook against a throwaway path.
# This catches path conversion or environment-bridge bugs that runtime shims
# cannot expose while still avoiding a live plugin installation or real journal.
CASE_NUMBER=$((CASE_NUMBER + 1))
actual_plugin_root=$TEST_ROOT/'plugin root ; dollar $() amp & brackets []'
actual_root=$TEST_ROOT/actual\ devlog
legacy_root=$TEST_ROOT/legacy\ devlog
mkdir -p -- "$actual_plugin_root/hooks"
cp -- "$REPO_ROOT"/hooks/devlog-* "$actual_plugin_root/hooks/"
actual_root_for_hook=$actual_root
legacy_root_for_hook=$legacy_root
case $(uname -s 2>/dev/null) in
    MINGW* | MSYS* | CYGWIN*)
        actual_root_for_hook=$(cygpath -m "$actual_root")
        legacy_root_for_hook=$(cygpath -m "$legacy_root")
        ;;
esac
actual_stdout=$TEST_ROOT/actual-session.stdout
actual_stderr=$TEST_ROOT/actual-session.stderr
set +e
(
    export PATH=$ORIGINAL_PATH
    export CLAUDE_PLUGIN_OPTION_DEVLOG_DIR=$actual_root_for_hook
    export CLAUDE_DEVLOG_DIR=$legacy_root_for_hook
    export CLAUDE_PLUGIN_OPTION_DEVLOG_LANG=en
    export CLAUDE_DEVLOG_LANG=ja
    printf '%s' '{"session_id":"plugin-integration"}' |
        "$REAL_BASH" --noprofile --norc \
            "$actual_plugin_root/hooks/devlog-plugin-launcher.sh" session-start
) > "$actual_stdout" 2> "$actual_stderr"
status=$?
set -e
assert_eq 0 "$status" 'Real launcher SessionStart should succeed'
assert_eq '' "$(cat "$actual_stderr")" 'Real launcher SessionStart should keep stderr empty'
if ! grep -Fq -- '"hookEventName":"SessionStart"' "$actual_stdout"; then
    fail 'Real launcher SessionStart should emit SessionStart JSON'
fi
if ! grep -Fq -- 'Dev journal routine' "$actual_stdout"; then
    fail 'Plugin language option should reach the real selected hook'
fi
if [[ ! -f $actual_root/.devlog-markers/plugin-integration.start ]]; then
    fail 'Plugin directory option should receive the real session marker'
fi
if [[ -e $legacy_root ]]; then
    fail 'Overridden legacy directory must remain untouched'
fi

actual_stop_stdout=$TEST_ROOT/actual-stop.stdout
actual_stop_stderr=$TEST_ROOT/actual-stop.stderr
set +e
(
    export PATH=$ORIGINAL_PATH
    export CLAUDE_PLUGIN_OPTION_DEVLOG_DIR=$actual_root_for_hook
    export CLAUDE_DEVLOG_DIR=$legacy_root_for_hook
    export CLAUDE_PLUGIN_OPTION_DEVLOG_LANG=en
    export CLAUDE_DEVLOG_LANG=ja
    printf '%s' '{"session_id":"plugin-integration"}' |
        "$REAL_BASH" --noprofile --norc \
            "$actual_plugin_root/hooks/devlog-plugin-launcher.sh" stop
) > "$actual_stop_stdout" 2> "$actual_stop_stderr"
status=$?
set -e
assert_eq 0 "$status" 'Real launcher Stop should succeed'
assert_eq '' "$(cat "$actual_stop_stderr")" 'Real launcher Stop should keep stderr empty'
if ! grep -Fq -- '"decision":"block"' "$actual_stop_stdout"; then
    fail 'Real launcher Stop should preserve the block decision'
fi

# Unsupported inputs fail with fixed diagnostics and never echo protected data.
new_case
make_runtime_shim "$SHIM_ROOT/bash"
protected_value='SECRET_FIXTURE_MUST_NOT_APPEAR'
raw_payload='RAW_PRIVATE_LOG_MUST_NOT_APPEAR'
set +e
run_launcher Plan9 session-start "$raw_payload" "$protected_value" \
    "$protected_value" "$protected_value" "$protected_value" "$SHIM_ROOT"
status=$?
set -e
assert_eq 64 "$status" 'Unknown platform must exit 64'
assert_eq '' "$(cat "$STDOUT_FILE")" 'Unknown platform must not write stdout'
assert_eq 'claude-code-devlog-hooks: unsupported runtime.' "$(cat "$STDERR_FILE")" 'Unknown platform must use a fixed diagnostic'
if grep -Fq -- "$protected_value" "$STDOUT_FILE" "$STDERR_FILE" ||
    grep -Fq -- "$raw_payload" "$STDOUT_FILE" "$STDERR_FILE"; then
    fail 'Unknown platform diagnostic leaked configuration or stdin'
fi
if [[ -s $TRACE_FILE ]]; then
    fail 'Unknown platform must not invoke a runtime'
fi

new_case
make_runtime_shim "$SHIM_ROOT/bash"
set +e
run_launcher Linux unknown-event "$raw_payload" "$protected_value" \
    "$protected_value" "$protected_value" "$protected_value" "$SHIM_ROOT"
status=$?
set -e
assert_eq 64 "$status" 'Unknown event must exit 64'
assert_eq '' "$(cat "$STDOUT_FILE")" 'Unknown event must not write stdout'
assert_eq 'claude-code-devlog-hooks: unsupported hook event.' "$(cat "$STDERR_FILE")" 'Unknown event must use a fixed diagnostic'
if grep -Fq -- "$protected_value" "$STDOUT_FILE" "$STDERR_FILE" ||
    grep -Fq -- "$raw_payload" "$STDOUT_FILE" "$STDERR_FILE"; then
    fail 'Unknown event diagnostic leaked configuration or stdin'
fi
if [[ -s $TRACE_FILE ]]; then
    fail 'Unknown event must not invoke a runtime'
fi

new_case
make_runtime_shim "$SHIM_ROOT/bash"
rm -f -- "$PLUGIN_ROOT/hooks/devlog-stop.sh"
set +e
run_launcher Linux stop "$raw_payload" "$protected_value" \
    "$protected_value" "$protected_value" "$protected_value" "$SHIM_ROOT"
status=$?
set -e
assert_eq 66 "$status" 'Missing bundled hook must exit 66'
assert_eq 'claude-code-devlog-hooks: bundled hook is unavailable.' "$(cat "$STDERR_FILE")" 'Missing hook must use a fixed diagnostic'
if grep -Fq -- "$protected_value" "$STDOUT_FILE" "$STDERR_FILE" ||
    grep -Fq -- "$raw_payload" "$STDOUT_FILE" "$STDERR_FILE"; then
    fail 'Missing hook diagnostic leaked configuration or stdin'
fi
if [[ -s $TRACE_FILE ]]; then
    fail 'Missing hook must not invoke a runtime'
fi

new_case
make_cygpath_shim "$SHIM_ROOT/cygpath"
set +e
run_launcher MINGW64_NT-10.0 session-start "$raw_payload" "$protected_value" \
    "$protected_value" "$protected_value" "$protected_value" "$SHIM_ROOT"
status=$?
set -e
assert_eq 64 "$status" 'Missing Windows runtime must exit 64'
assert_eq 'claude-code-devlog-hooks: unsupported runtime.' "$(cat "$STDERR_FILE")" 'Missing runtime must use a fixed diagnostic'
if [[ -s $TRACE_FILE ]]; then
    fail 'Missing runtime must not invoke a runtime'
fi

new_case
make_runtime_shim "$SHIM_ROOT/pwsh"
set +e
run_launcher MINGW64_NT-10.0 session-start "$raw_payload" "$protected_value" \
    "$protected_value" "$protected_value" "$protected_value" "$SHIM_ROOT"
status=$?
set -e
assert_eq 64 "$status" 'Missing Windows path converter must exit 64'
assert_eq 'claude-code-devlog-hooks: unsupported runtime.' "$(cat "$STDERR_FILE")" 'Missing path converter must use a fixed diagnostic'
if grep -Fq -- "$protected_value" "$STDOUT_FILE" "$STDERR_FILE" ||
    grep -Fq -- "$raw_payload" "$STDOUT_FILE" "$STDERR_FILE"; then
    fail 'Missing path converter diagnostic leaked configuration or stdin'
fi
if [[ -s $TRACE_FILE ]]; then
    fail 'Missing path converter must not invoke a runtime'
fi

new_case
make_failing_cygpath_shim "$SHIM_ROOT/cygpath"
make_runtime_shim "$SHIM_ROOT/pwsh"
set +e
run_launcher MINGW64_NT-10.0 session-start "$raw_payload" "$protected_value" \
    "$protected_value" "$protected_value" "$protected_value" "$SHIM_ROOT"
status=$?
set -e
assert_eq 64 "$status" 'Failed Windows path conversion must exit 64'
assert_eq 'claude-code-devlog-hooks: unsupported runtime.' "$(cat "$STDERR_FILE")" 'Failed path conversion must use a fixed diagnostic'
if grep -Fq -- "$protected_value" "$STDOUT_FILE" "$STDERR_FILE" ||
    grep -Fq -- "$raw_payload" "$STDOUT_FILE" "$STDERR_FILE"; then
    fail 'Failed path conversion diagnostic leaked configuration or stdin'
fi
if [[ -s $TRACE_FILE ]]; then
    fail 'Failed path conversion must not invoke a runtime'
fi

if ((FAILURES > 0)); then
    printf 'Plugin launcher test failed (%s failures).\n' "$FAILURES"
    exit 1
fi

printf 'Plugin launcher test passed (%s synthetic and integration cases).\n' "$CASE_NUMBER"
