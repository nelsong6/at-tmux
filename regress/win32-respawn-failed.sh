#!/bin/sh

# A pane whose respawn can't start its program stays dead and usable: a later
# respawn, capture-pane -P and send-keys -R work on it, and the server keeps
# running (TMUX-61). Before the fix the failed respawn left the pane without
# its input parser, and the next respawn ended the server.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltmux61test-respawn"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

CMDEXE=$(cygpath -w "$SYSTEMROOT/System32/cmd.exe")
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
trap "$TMUX kill-server 2>/dev/null; rm -f $CFG" 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}

alive() {
	$TMUX has-session 2>/dev/null || fail "server ended after $1"
}

dead() {
	$TMUX display -p -t w:0 '#{pane_dead}' 2>/dev/null | tr -d '\r'
}

# Two arguments start the program directly, so a missing one fails to spawn.
respawn_missing() {
	out=$($TMUX respawn-pane -k -t w:0 no-such-program-tmux61 --version \
	    2>&1 | tr -d '\r')
	echo "$out" | grep -q 'spawn failed' ||
	    fail "respawn of a missing program printed '$out'"
	alive "$1"
	[ "$(dead)" = 1 ] || fail "pane not dead after $1"
}

$TMUX -f$CFG new -d -s w -x 80 -y 24 </dev/null || fail "new-session"
$TMUX set -g remain-on-exit on

respawn_missing "a failed respawn"
respawn_missing "a second failed respawn"

$TMUX capture-pane -P -p -t w:0 >/dev/null 2>&1
alive "capture-pane -P on the dead pane"
$TMUX send-keys -R -t w:0 2>/dev/null
alive "send-keys -R on the dead pane"

$TMUX respawn-pane -k -t w:0 "$CMDEXE" //k echo tmux61-back ||
    fail "respawn of cmd.exe"
alive "respawning a working program"
wait_for w:0 '^tmux61-back' || fail "cmd.exe's output never showed"
[ "$(dead)" = 0 ] || fail "pane still dead after a working respawn"

respawn_missing "a failed respawn of a running pane"

echo "ALL RESPAWN-FAILED TESTS PASSED"
exit 0
