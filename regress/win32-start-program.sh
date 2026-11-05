#!/bin/sh

# start-program runs a program from the server with no shell: an argument with
# spaces reaches it whole, and one that can't start fails with its name.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

trap "$TMUX kill-server 2>/dev/null" 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}

WTMUX=$(cygpath -w "$(readlink -f "$TEST_TMUX")")

$TMUX -fNUL new -d -s p </dev/null || fail "start server"

$TMUX start-program "$WTMUX" "-L$TEST_SOCKET" set -g @started 'two words' ||
    fail "start-program"
started() {
	[ "$($TMUX show -gqv @started | tr -d '\r')" = "two words" ]
}
wait_until started || fail "the program didn't run with its argument whole"

ERR=$($TMUX start-program no-such-program-94.exe 2>&1 | tr -d '\r')
case "$ERR" in
*"can't start no-such-program-94.exe"*) ;;
*) fail "a missing program gave: $ERR" ;;
esac
$TMUX has-session -t p || fail "server ended after a failed start"

$TMUX bind -T global-no-client 'W-`' start-program x.exe || fail "bind"
$TMUX list-keys -T global-no-client | grep -q 'start-program' || fail "bound key"

echo "PASS: start-program"
