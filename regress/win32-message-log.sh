#!/bin/sh

# Startup failures retain their caller's error; failed program exits are
# recorded too, as standard log lines (AHT-204). History survives the server
# and rotates.
PATH=/bin:/usr/bin
TERM=screen
. "$(dirname "$0")/win32-test.sh"
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
OUT=$(mktemp -d) || exit 1
LOG="$OUT/tmux.log"
export TMUX_LOG=$(cygpath -w "$LOG")
CFG="$OUT/config"
printf "set -g default-shell '%s'\n" "$COMSPEC" >"$CFG"
cleanup() {
	$TMUX kill-server 2>/dev/null
	rm -rf "$OUT"
}
trap cleanup 0 1 15
fail() { echo "FAIL: $*"; exit 1; }

$TMUX -f"$CFG" new-session -d -s w -n home || fail "start server"
PID=$($TMUX display -p '#{pid}' | tr -d '\r')

for command in new-window split-window; do
	case "$command" in
new-window) set -- -a -t w:home -o remain-on-exit=failed ;;
	split-window) set -- -t w:home ;;
	esac
	if $TMUX "$command" "$@" tmux41-no-such-program.exe --test >"$OUT/reply" 2>&1; then
		fail "$command accepted a program that cannot start"
	fi
	grep -q "can't start tmux41-no-such-program.exe" "$OUT/reply" || fail "$command lost the caller's error: $(cat "$OUT/reply")"
done
grep -q " pid=$PID error command failed command=new-window error=\"create window failed: can't start tmux41-no-such-program.exe" "$LOG" || fail "new-window failure not logged: $(cat "$LOG")"
grep -q " error command failed command=split-window error=\"create pane failed: can't start tmux41-no-such-program.exe" "$LOG" || fail "split failure not logged"
grep -q "^$(date +%Y)-[0-9-]*T[0-9:.]*\([-+][0-9:]*\|Z\) pid=" "$LOG" || fail "error time is not current, with its zone"
grep -q " socket=[^ ]*$TEST_SOCKET" "$LOG" || fail "the line names no socket"
[ "$($TMUX list-windows -t w | wc -l)" -eq 1 ] || fail "failed window remains"
[ "$($TMUX list-panes -t w:home | wc -l)" -eq 1 ] || fail "failed split remains"

CMDEXE=$(cygpath -w "$SYSTEMROOT/System32/cmd.exe")
$TMUX new-window -d -t w -n fails "$CMDEXE" //c "exit 7" || fail "start failing program"
has_exit() { grep -q ' error pane exited pane=%[0-9]* .* status=7 ' "$LOG"; }
wait_until has_exit || fail "program's failed exit not logged"

head -c 1048577 /dev/zero >"$LOG"
if $TMUX set-option -g tmux41-rotation-marker on >"$OUT/reply" 2>&1; then
	fail "unknown option was accepted"
fi
[ -f "$LOG.old" ] || fail "full log was not rotated"
grep -q tmux41-rotation-marker "$LOG" || fail "new entry missing after rotation"

$TMUX kill-server || fail "stop server"
wait_gone || fail "server did not stop"
grep -q tmux41-rotation-marker "$LOG" || fail "history lost when server ended"
echo 'PASS: launch failures and failed exits persist as standard lines; caller behavior and rotation hold'
