#!/bin/sh

# Startup failures retain their caller's error; failed program exits are
# recorded too. History survives the server, rotates and expires old files.
PATH=/bin:/usr/bin
TERM=screen
. "$(dirname "$0")/win32-test.sh"
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
OUT=$(mktemp -d) || exit 1
export TMUX_ERROR_LOG_DIR=$(cygpath -w "$OUT")
CFG="$OUT/config"
printf "set -g default-shell '%s'\n" "$COMSPEC" >"$CFG"
cleanup() {
	$TMUX kill-server 2>/dev/null
	rm -f "$OUT"/*
	rmdir "$OUT"
}
trap cleanup 0 1 15
fail() { echo "FAIL: $*"; exit 1; }

touch "$OUT/tmux-999999.log" "$OUT/unrelated.log"
touch -t 200001010000 "$OUT/tmux-999999.log" "$OUT/unrelated.log"
$TMUX -f"$CFG" new-session -d -s w -n home || fail "start server"
PID=$($TMUX display -p '#{pid}' | tr -d '\r')
LOG="$OUT/tmux-$PID.log"

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
[ ! -e "$OUT/tmux-999999.log" ] || fail "expired log remains"
[ -e "$OUT/unrelated.log" ] || fail "unrelated file removed"
grep -q "create window failed: can't start tmux41-no-such-program.exe" "$LOG" || fail "new-window failure not logged"
grep -q "create pane failed: can't start tmux41-no-such-program.exe" "$LOG" || fail "split failure not logged"
grep -q "^$(date -u +%Y)-" "$LOG" || fail "error timestamp is not current"
[ "$($TMUX list-windows -t w | wc -l)" -eq 1 ] || fail "failed window remains"
[ "$($TMUX list-panes -t w:home | wc -l)" -eq 1 ] || fail "failed split remains"

CMDEXE=$(cygpath -w "$SYSTEMROOT/System32/cmd.exe")
$TMUX new-window -d -t w -n fails "$CMDEXE" //c "exit 7" || fail "start failing program"
has_exit() { grep -q 'exited with status 7' "$LOG"; }
wait_until has_exit || fail "program's failed exit not logged"

head -c 1048576 /dev/zero >"$LOG"
if $TMUX set-option -g tmux41-rotation-marker on >"$OUT/reply" 2>&1; then
	fail "unknown option was accepted"
fi
[ -f "$LOG.1" ] || fail "full log was not rotated"
grep -q tmux41-rotation-marker "$LOG" || fail "new entry missing after rotation"

$TMUX kill-server || fail "stop server"
wait_gone || fail "server did not stop"
grep -q tmux41-rotation-marker "$LOG" || fail "history lost when server ended"
echo 'PASS: launch failures and failed exits persist; caller behavior, rotation and retention hold'
