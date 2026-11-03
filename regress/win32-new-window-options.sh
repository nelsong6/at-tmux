#!/bin/sh

# new-window -o name=value: a window option is set on the new window before
# its program can end (TMUX-52). With remain-on-exit=failed, a program that
# fails at once keeps its window and output, one that succeeds closes it, and
# a bad -o makes no window.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

CMDEXE=$(cygpath -w "$SYSTEMROOT/System32/cmd.exe")
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
OUT=$(mktemp)
CTL=$(mktemp)
SLEEPER=$(mktemp)
FAIL=0
cleanup() {
	$TMUX kill-server 2>/dev/null
	[ -s $SLEEPER ] && kill "$(cat $SLEEPER)" 2>/dev/null
	rm -f $CFG $OUT $CTL $SLEEPER
}
trap cleanup 0 1 15

TFAIL=0
fail() {
	echo "FAIL: $1"
	FAIL=1
	TFAIL=1
}

pass() {
	[ $TFAIL -eq 0 ] && echo "PASS $1"
	TFAIL=0
}

window_exists() {
	$TMUX lsw -t w -F '#{window_name}' 2>/dev/null | tr -d '\r' |
	    grep -qx -- "$1"
}

windows() {
	$TMUX lsw -t w 2>/dev/null | wc -l
}

pane_dead() {
	[ "$($TMUX display -p -t "$1" '#{pane_dead}' 2>/dev/null | tr -d '\r')" = 1 ]
}

$TMUX -f$CFG new -d -s w -n home -x 80 -y 24 </dev/null || exit 1
$TMUX set -g remain-on-exit off

# --- Test 1: a program that prints and fails at once keeps its window, dead,
# with its output and exit status. ---
$TMUX new-window -d -a -t w:home -n failing -o remain-on-exit=failed \
    "$CMDEXE" //c "echo boom& exit 3" >$OUT 2>&1 || fail "1: $(cat $OUT)"
wait_until pane_dead w:failing || fail "1: the pane didn't stay, dead"
window_exists failing || fail "1: window gone"
# The dead message goes on a new last line, scrolling the screen by one as
# upstream does, so the first line of output can be in the history.
$TMUX capture-pane -p -S - -t w:failing | tr -d '\r' | grep -q '^boom' ||
    fail "1: output gone"
ST=$($TMUX display -p -t w:failing '#{pane_dead_status}' | tr -d '\r')
[ "$ST" = 3 ] || fail "1: dead status $ST"
[ "$($TMUX show -wv -t w:failing remain-on-exit | tr -d '\r')" = failed ] ||
    fail "1: option not on the window"
[ "$($TMUX show -gwv remain-on-exit | tr -d '\r')" = off ] ||
    fail "1: the global option changed"
pass "1: a failing program keeps its window"
$TMUX kill-window -t w:failing

# --- Test 2: one that succeeds closes its window. ---
$TMUX new-window -d -a -t w:home -n fine -o remain-on-exit=failed \
    "$CMDEXE" //c "exit 0" >$OUT 2>&1 || fail "2: $(cat $OUT)"
wait_until sh -c "! $TMUX lsw -t w -F '#{window_name}' | tr -d '\r' | grep -qx fine" ||
    fail "2: a program that succeeded left its window"
pass "2: success closes the window"

# --- Test 3: without -o, a failing program's window goes as before. ---
$TMUX new-window -d -a -t w:home -n plain "$CMDEXE" //c "exit 3" >$OUT 2>&1
wait_until sh -c "! $TMUX lsw -t w -F '#{window_name}' | tr -d '\r' | grep -qx plain" ||
    fail "3: a window without -o stayed"
pass "3: no -o, no change"

# --- Test 4: a bad -o is an error and makes no window. ---
BEFORE=$(windows)
for bad in nosuch=1 remain-on-exit=sometimes noequals status=on; do
	if $TMUX new-window -d -n bad -o "$bad" "$CMDEXE" //c "exit 0" >$OUT 2>&1; then
		fail "4: -o $bad was taken"
	fi
	grep -q . $OUT || fail "4: -o $bad: no message"
done
[ "$(windows)" = "$BEFORE" ] || fail "4: a bad -o made a window"
pass "4: a bad -o is refused"

# --- Test 5: user options and several -o. ---
$TMUX new-window -d -a -t w:home -n user -o @at=pick -o remain-on-exit=on \
    "$CMDEXE" //c "exit 0" >$OUT 2>&1 || fail "5: $(cat $OUT)"
wait_until pane_dead w:user || fail "5: remain-on-exit=on not applied"
[ "$($TMUX show -wv -t w:user @at | tr -d '\r')" = pick ] || fail "5: @at not set"
pass "5: user options and several -o"
$TMUX kill-window -t w:user

# --- Test 6: with -W, a program that fails without drawing shows its dead
# pane and the client is switched to it. ---
(sleep 300 >/dev/null 2>&1 & echo $! >$SLEEPER; wait) |
    $TMUX -C attach -t w >$CTL 2>&1 &
wait_until [ -n "$($TMUX list-clients -F '#{client_name}' 2>/dev/null)" ] ||
    { fail "6: no client"; exit 1; }
C=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
$TMUX new-window -a -t w:home -n quiet -o remain-on-exit=failed -W "$C" \
    "$CMDEXE" //c "exit 4" >$OUT 2>&1 || fail "6: $(cat $OUT)"
window_exists quiet || fail "6: window gone"
wait_until pane_dead w:quiet || fail "6: not dead"
[ "$($TMUX list-clients -F '#{window_name}' | tr -d '\r')" = quiet ] ||
    fail "6: client not switched"
pass "6: -W shows the dead pane"

exit $FAIL
