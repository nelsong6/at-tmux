#!/bin/sh

# Destroy busy consoles without waiting on their blocked bridge threads.
PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
trap "timeout --foreground --kill-after=1 10 $TMUX kill-server 2>/dev/null" 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}

$TMUX -fNUL new -d -s close -n keep </dev/null || fail "start server"
FLOOD=$(cygpath -wa "$(dirname "$0")/win32-pty-flood.ps1")
PS="$SYSTEMROOT\System32\WindowsPowerShell\v1.0\powershell.exe"
for i in 1 2 3 4; do
	$TMUX new-window -d -t close: -n "busy$i" \
	    "$PS" -NoProfile -File "$FLOOD" || fail "start busy$i"
	wait_for "close:busy$i" '^xxxxxxxx' || fail "busy$i produced no output"
done

timeout --foreground --kill-after=1 10 $TMUX kill-window -a -t close:keep ||
    fail "destroy busy windows"
timeout --foreground --kill-after=1 10 $TMUX has-session -t close ||
    fail "server stopped responding while closing consoles"
$TMUX kill-server || fail "kill server"
wait_gone || fail "server did not exit"
echo "ALL CONSOLE SHUTDOWN TESTS PASSED"
