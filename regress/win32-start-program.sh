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

OUT=$(mktemp -d)
trap "$TMUX kill-server 2>/dev/null; rm -rf $OUT" 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}

WTMUX=$(cygpath -w "$(readlink -f "$TEST_TMUX")")
"$(dirname "$TEST_TMUX")/alt-tab-test.exe" || fail "Alt+Tab hook gate"

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

$TMUX start-program -K M-Tab no-such-program-94.exe >/dev/null 2>&1 &&
    fail "missing program succeeded"
[ -z "$($TMUX show -gqv @start-program-key | tr -d '\r')" ] ||
    fail "failed launch left a pending key"
$TMUX start-program -K no-such-key "$WTMUX" "-L$TEST_SOCKET" \
    set -g @invalid-key-started yes >/dev/null 2>&1 && fail "invalid key succeeded"
[ -z "$($TMUX show -gqv @invalid-key-started | tr -d '\r')" ] ||
    fail "invalid key started the program"

$TMUX bind -n M-Tab set -g @launch-key forward || fail "bind forward"
$TMUX bind -n M-BTab set -g @launch-key backward || fail "bind backward"
$TMUX start-program -K M-Tab "$WTMUX" "-L$TEST_SOCKET" \
    set -g @started first || fail "defer forward"
$TMUX start-program -K M-BTab "$WTMUX" "-L$TEST_SOCKET" \
    set -g @started second || fail "replace deferred key"
[ -z "$($TMUX show -gqv @launch-key | tr -d '\r')" ] ||
    fail "key ran without a client"

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
attach() {
    "$PS" -NoProfile -ExecutionPolicy Bypass \
        -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
        -Command "\"$WTMUX\" -L$TEST_SOCKET attach" \
        -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$OUT/resize")" &
}
delivered() {
    [ "$($TMUX show -gqv @launch-key | tr -d '\r')" = backward ]
}
attach
wait_until delivered || fail "key was not delivered to the attached client"
[ -z "$($TMUX show -gqv @start-program-key | tr -d '\r')" ] ||
    fail "delivered key was not cleared"
$TMUX detach-client || fail "detach"
detached() { [ -z "$($TMUX list-clients | tr -d '\r')" ]; }
wait_until detached || fail "client did not detach"
$TMUX set -g @launch-key consumed || fail "mark consumed"
attach
attached() { [ -n "$($TMUX list-clients | tr -d '\r')" ]; }
wait_until attached || fail "second client did not attach"
[ "$($TMUX show -gqv @launch-key | tr -d '\r')" = consumed ] ||
    fail "key was delivered a second time"
echo "PASS: launch key waits for attachment, replaces repeats and runs once"

$TMUX bind -T global-no-client 'W-`' start-program x.exe || fail "bind"
$TMUX list-keys -T global-no-client | grep -q 'start-program' || fail "bound key"

echo "PASS: start-program"
