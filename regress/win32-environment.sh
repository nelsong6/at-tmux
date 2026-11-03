#!/bin/sh

# A server's current environment, including changes made after startup, reaches
# every kind of child. Background jobs must not inherit its old OS environment.
PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"

OUT=$(mktemp -d)
NATIVE=$(cygpath -ma "$OUT")
cleanup() {
	"$TEST_TMUX" -L"$TEST_SOCKET" kill-server 2>/dev/null
	rm -f "$OUT/background.txt" "$OUT/foreground.txt" "$OUT/lookup.txt" \
	    "$OUT/session.txt" "$OUT/other.txt" "$OUT/pipe.txt" "$OUT/pane.txt" \
	    "$OUT/unicode.conf" "$OUT/unicode.ps1" "$OUT/unicode.txt" \
	    "$OUT/managed tools/tmux-env-probe.cmd"
	rmdir "$OUT/managed tools" "$OUT" 2>/dev/null
}
trap cleanup 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}

file_has() {
	[ -f "$1" ] && tr -d '\r' <"$1" | grep -qx "$2"
}

snapshot_is() {
	actual=$(printf '%s\n' "$1" | tr -d '\r' | sort)
	expected=$(printf '%s\n' "$2" | sort)
	[ "$actual" = "$expected" ] || {
		printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual"
		return 1
	}
}

export TMUX_ENV_CHANGED=startup TMUX_ENV_REMOVED=startup
$TMUX -fNUL new -d -s probe "$COMSPEC" //d //q || fail "new-session"
$TMUX setenv -g TMUX_ENV_CHANGED global
$TMUX setenv -g TMUX_ENV_ADDED added
$TMUX setenv -gu TMUX_ENV_REMOVED
GLOBAL='TMUX_ENV_ADDED=added
TMUX_ENV_CHANGED=global'

# Added, changed and removed variables use the current global environment.
$TMUX run-shell -t probe:0 "set TMUX_ENV_ > \"$NATIVE/foreground.txt\""
snapshot=$(cat "$OUT/foreground.txt")
snapshot_is "$snapshot" "$GLOBAL" || fail "foreground job global environment"
$TMUX run-shell -b -t probe:0 "set TMUX_ENV_ > \"$NATIVE/background.txt\""
wait_until file_has "$OUT/background.txt" 'TMUX_ENV_CHANGED=global' ||
    fail "background job never wrote the current environment"
snapshot_is "$(cat "$OUT/background.txt")" "$GLOBAL" || fail "background job global environment"

# PATH lookup includes a managed directory containing spaces, as alerts.exe does.
mkdir "$OUT/managed tools"
printf '@echo off\r\necho TMUX_ENV_PROBE=%%TMUX_ENV_CHANGED%%\r\n' >"$OUT/managed tools/tmux-env-probe.cmd"
$TMUX setenv -g Path "$NATIVE/managed tools;$SYSTEMROOT/System32"
$TMUX run-shell -t probe:0 "tmux-env-probe.cmd > \"$NATIVE/lookup.txt\""
snapshot=$(tr -d '\r' <"$OUT/lookup.txt")
[ "$snapshot" = 'TMUX_ENV_PROBE=global' ] || fail "job PATH lookup: $snapshot"
$TMUX if-shell -t probe:0 'tmux-env-probe.cmd | %SystemRoot%\System32\findstr.exe /x TMUX_ENV_PROBE=global' \
    'set -g @environment-if yes' 'set -g @environment-if no'
[ "$($TMUX show -gqv @environment-if | tr -d '\r')" = yes ] || fail "if-shell current environment"

# Normal panes still receive the same environment.
$TMUX new-window -d -t probe: -n snapshot -o remain-on-exit=on "$COMSPEC" //d //c "set TMUX_ENV_ > \"$NATIVE/pane.txt\""
wait_until file_has "$OUT/pane.txt" 'TMUX_ENV_CHANGED=global' || fail "new pane global environment"
snapshot=$(cat "$OUT/pane.txt")
snapshot_is "$snapshot" "$GLOBAL" || fail "new pane environment differs from jobs"

# A session override wins, a removal masks the global value, and other sessions
# keep their own environment. The pipe launcher follows the target session too.
$TMUX setenv -t probe TMUX_ENV_CHANGED session
$TMUX setenv -rt probe TMUX_ENV_ADDED
$TMUX run-shell -t probe:0 "set TMUX_ENV_ > \"$NATIVE/session.txt\""
snapshot=$(cat "$OUT/session.txt")
snapshot_is "$snapshot" 'TMUX_ENV_CHANGED=session' || fail "job session environment"
$TMUX new -d -s other "$COMSPEC" //d //q
$TMUX run-shell -t other:0 "set TMUX_ENV_ > \"$NATIVE/other.txt\""
snapshot=$(cat "$OUT/other.txt")
snapshot_is "$snapshot" "$GLOBAL" || fail "job leaked another session's environment"
$TMUX pipe-pane -t probe:0 "\"$COMSPEC\" /d /c set TMUX_ENV_ > \"$NATIVE/pipe.txt\""
wait_until file_has "$OUT/pipe.txt" 'TMUX_ENV_CHANGED=session' || fail "pipe job session environment"
snapshot_is "$(cat "$OUT/pipe.txt")" 'TMUX_ENV_CHANGED=session' || fail "pipe job removed variable"

# Config files carry UTF-8 values without Windows argv's ANSI conversion. The
# job must pass the environment as Unicode, just as the pane/PTY launcher does.
printf "set-environment -g TMUX_ENV_UNICODE 'caf\303\251 \346\235\261\344\272\254'\n" >"$OUT/unicode.conf"
$TMUX source-file "$NATIVE/unicode.conf"
cat >"$OUT/unicode.ps1" <<'PS'
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:TMUX_ENV_UNICODE))
PS
POWERSHELL="$SYSTEMROOT/System32/WindowsPowerShell/v1.0/powershell.exe"
$TMUX run-shell -t probe:0 "call \"$POWERSHELL\" -NoProfile -NonInteractive -File \"$NATIVE/unicode.ps1\" > \"$NATIVE/unicode.txt\""
snapshot=$(tr -d '\r' <"$OUT/unicode.txt")
expected=$(printf 'caf\303\251 \346\235\261\344\272\254' | base64)
[ "$snapshot" = "$expected" ] || fail "job Unicode environment: $snapshot"

echo 'ALL ENVIRONMENT TESTS PASSED'
