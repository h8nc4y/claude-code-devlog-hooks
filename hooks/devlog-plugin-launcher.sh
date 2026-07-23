#!/usr/bin/env bash
#
# One plugin entrypoint for every supported host. Claude Code's hook schema
# has no per-OS branch, so this dispatcher chooses exactly one existing hook
# implementation and then replaces itself with that process.

set -u

fail_event() {
    printf '%s\n' 'claude-code-devlog-hooks: unsupported hook event.' >&2
    exit 64
}

fail_runtime() {
    printf '%s\n' 'claude-code-devlog-hooks: unsupported runtime.' >&2
    exit 64
}

fail_hook_file() {
    printf '%s\n' 'claude-code-devlog-hooks: bundled hook is unavailable.' >&2
    exit 66
}

# Event names are a fixed internal protocol. Never turn an arbitrary argument
# into a script path.
case ${1-} in
    session-start)
        powershell_hook=devlog-session-start.ps1
        bash_hook=devlog-session-start.sh
        ;;
    prompt-nudge)
        powershell_hook=devlog-prompt-nudge.ps1
        bash_hook=devlog-prompt-nudge.sh
        ;;
    stop)
        powershell_hook=devlog-stop.ps1
        bash_hook=devlog-stop.sh
        ;;
    *)
        fail_event
        ;;
esac

# Derive the root from the launcher that Claude Code located through
# CLAUDE_PLUGIN_ROOT. This normalizes native Windows paths into the active Git
# Bash namespace and avoids trusting a separately inherited environment value.
launcher_dir=${BASH_SOURCE[0]%/*}
if [[ $launcher_dir == "${BASH_SOURCE[0]}" ]]; then
    launcher_dir=.
fi
plugin_root=$(CDPATH= cd -- "$launcher_dir/.." && pwd -P) || fail_hook_file

powershell_target="$plugin_root/hooks/$powershell_hook"
bash_target="$plugin_root/hooks/$bash_hook"

# Claude Code 2.1.207 exports userConfig through these environment variables.
# Quoted assignments keep spaces and metacharacters as data; no eval, source,
# or shell command interpolation is involved.
if [[ -n ${CLAUDE_PLUGIN_OPTION_DEVLOG_DIR-} ]]; then
    export CLAUDE_DEVLOG_DIR="${CLAUDE_PLUGIN_OPTION_DEVLOG_DIR}"
fi
if [[ -n ${CLAUDE_PLUGIN_OPTION_DEVLOG_LANG-} ]]; then
    export CLAUDE_DEVLOG_LANG="${CLAUDE_PLUGIN_OPTION_DEVLOG_LANG}"
fi

platform=$(uname -s 2>/dev/null) || fail_runtime

case $platform in
    MINGW* | MSYS* | CYGWIN*)
        # Native Windows keeps the existing PowerShell behavior when possible.
        # Git Bash does not always convert script paths containing valid Windows
        # shell metacharacters. Convert the fixed bundled path explicitly before
        # handing it to PowerShell; a missing converter fails closed.
        path_converter=$(type -P cygpath 2>/dev/null) || fail_runtime
        powershell_native_target=$(
            "$path_converter" -m -- "$powershell_target" 2>/dev/null
        ) || fail_runtime
        [[ -n $powershell_native_target ]] || fail_runtime

        # Only one branch reaches exec, so Bash and PowerShell never both run.
        if runtime=$(type -P pwsh 2>/dev/null); then
            [[ -f $powershell_target ]] || fail_hook_file
            exec "$runtime" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
                -File "$powershell_native_target"
        elif runtime=$(type -P powershell.exe 2>/dev/null); then
            [[ -f $powershell_target ]] || fail_hook_file
            exec "$runtime" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
                -File "$powershell_native_target"
        elif runtime=$(type -P powershell 2>/dev/null); then
            [[ -f $powershell_target ]] || fail_hook_file
            exec "$runtime" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
                -File "$powershell_native_target"
        elif runtime=$(type -P bash 2>/dev/null); then
            [[ -f $bash_target ]] || fail_hook_file
            exec "$runtime" --noprofile --norc "$bash_target"
        else
            fail_runtime
        fi
        ;;
    Linux | Darwin)
        runtime=$(type -P bash 2>/dev/null) || fail_runtime
        [[ -f $bash_target ]] || fail_hook_file
        exec "$runtime" --noprofile --norc "$bash_target"
        ;;
    *)
        fail_runtime
        ;;
esac
