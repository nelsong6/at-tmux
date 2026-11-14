#!/bin/sh

# A pane whose respawn can't start its program reads as one whose program
# printed why and exited 1 (TMUX-62): it shows the reason and remain-on-exit's
# line, #{pane_dead} is 1 with status 1, pane-died runs, and remain-on-exit
# decides whether it stays. Before, a second failed respawn left it blank and
# not dead. It also stays usable: a later respawn, capture-pane -P and
# send-keys -R work on it and the server keeps running (TMUX-61: the failed
# respawn left the pane without its input parser, and the next respawn ended
# the server).

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

CMDEXE=$(cygpath -w "$SYSTEMROOT/System32/cmd.exe")
MISSING=no-such-program-tmux62
WHY="^can't start $MISSING: The system cannot find the file specified$"
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
	$TMUX display -p -t "$1" '#{pane_dead} #{pane_dead_status}' 2>/dev/null |
	    tr -d '\r'
}

dead_with_1() {
	[ "$(dead "$1")" = "1 1" ]
}

# respawn_missing TARGET WHEN: two arguments start the program directly, so a
# missing one fails to spawn, and the caller is told why.
respawn_missing() {
	out=$($TMUX respawn-pane -k -t "$1" $MISSING --version 2>&1 |
	    tr -d '\r')
	echo "$out" | grep -q "can't start $MISSING: " ||
	    fail "respawn of a missing program printed '$out'"
	alive "$2"
}

# shows_dead TARGET WHEN: the pane is dead with status 1 and shows why above
# remain-on-exit's line, drawn once.
shows_dead() {
	wait_until dead_with_1 "$1" ||
	    fail "pane reads '$(dead "$1")', not dead with status 1, after $2"
	wait_for "$1" "$WHY" || fail "no reason in the pane after $2"
	wait_for "$1" '^Pane is dead (status 1, ' ||
	    fail "no dead line after $2"
	n=$($TMUX capture-pane -p -t "$1" | tr -d '\r' | grep -c '^Pane is dead')
	[ "$n" = 1 ] || fail "dead line drawn $n times after $2"
}

died_ran() {
	[ "$($TMUX show -gv @died 2>/dev/null | tr -d '\r')" = yes ]
}

$TMUX -f$CFG new -d -s w -x 80 -y 24 </dev/null || fail "new-session"
$TMUX set -g remain-on-exit on
$TMUX set-hook -g pane-died 'set -g @died yes'

# The status is the failure's, not the exit of the shell the respawn killed.
respawn_missing w:^ "a failed respawn of a running pane"
shows_dead w:^ "a failed respawn of a running pane"
wait_until died_ran || fail "pane-died didn't run after a failed respawn"

# The pane was already dead, so no exit is still to come.
$TMUX set -gu @died
respawn_missing w:^ "a second failed respawn"
shows_dead w:^ "a second failed respawn"
wait_until died_ran || fail "pane-died didn't run after a second failed respawn"

$TMUX capture-pane -P -p -t w:^ >/dev/null 2>&1
alive "capture-pane -P on the dead pane"
$TMUX send-keys -R -t w:^ 2>/dev/null
alive "send-keys -R on the dead pane"

$TMUX respawn-pane -k -t w:^ "$CMDEXE" //k echo tmux61-back ||
    fail "respawn of cmd.exe"
alive "respawning a working program"
wait_for w:^ '^tmux61-back' || fail "cmd.exe's output never showed"
[ "$(dead w:^)" = "0 " ] || fail "pane reads '$(dead w:^)' after a working respawn"

# remain-on-exit failed keeps it, as for a program that exits 1.
$TMUX set -g remain-on-exit failed
respawn_missing w:^ "a failed respawn with remain-on-exit failed"
shows_dead w:^ "a failed respawn with remain-on-exit failed"

# respawn-window takes the same path.
$TMUX new-window -d -t w:2 || fail "new-window"
out=$($TMUX respawn-window -k -t w:2 $MISSING --version 2>&1 | tr -d '\r')
echo "$out" | grep -q "can't start $MISSING: " ||
    fail "respawn-window of a missing program printed '$out'"
alive "a failed respawn-window"
shows_dead w:2 "a failed respawn-window"
$TMUX kill-window -t w:2

# Without remain-on-exit the pane closes, as when its program exits.
$TMUX set -g remain-on-exit off
$TMUX split-window -t w:^ || fail "split-window"
wait_panes w:^ 2 || fail "split-window made no second pane"
respawn_missing w:^.1 "a failed respawn with remain-on-exit off"
wait_panes w:^ 1 ||
    fail "a failed respawn with remain-on-exit off left the pane open"

echo "ALL RESPAWN-FAILED TESTS PASSED"
exit 0
