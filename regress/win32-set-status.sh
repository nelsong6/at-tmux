#!/bin/sh

# set-window-status and set-session-status set a window's Claude state, the
# window option @claude, by hand: working and waiting set it, done unsets it,
# anything else is refused and changes nothing. The session form sets every
# window in its session and no other. The default window-status formats colour
# the window through @claude-style (TMUX-67).

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

# state WINDOW EXPECTED: WINDOW's @claude is EXPECTED (empty for unset).
state() {
	got=$($TMUX show -wqv -t "$1" @claude | tr -d '\r')
	[ "$got" = "$2" ] || fail "$1's @claude is '$got', expected '$2'"
}

$TMUX -fNUL new -d -s a -n a1 </dev/null || fail "new-session a"
$TMUX neww -d -t a: -n a2 || fail "new-window a2"
$TMUX new -d -s b -n b1 </dev/null || fail "new-session b"

# One window, by target; its neighbour and the other session stay unset.
$TMUX set-window-status -t a:a1 working || fail "set-window-status working"
state a:a1 working
state a:a2 ''
state b:b1 ''
$TMUX set-window-status -t a:a1 waiting || fail "set-window-status waiting"
state a:a1 waiting
$TMUX set-window-status -t a:a1 done || fail "set-window-status done"
state a:a1 ''
$TMUX show -w -t a:a1 | tr -d '\r' | grep -q '^@claude ' &&
    fail "done left @claude set"
$TMUX set-window-status -t a:a1 done || fail "done on an unset window"

# An unknown state is refused and changes nothing.
$TMUX set-window-status -t a:a1 working || fail "set working again"
$TMUX set-window-status -t a:a1 busy 2>/dev/null && fail "busy accepted"
state a:a1 working

# Every window in a session, and none in another.
$TMUX set-session-status -t a waiting || fail "set-session-status waiting"
state a:a1 waiting
state a:a2 waiting
state b:b1 ''
$TMUX set-session-status -t a idle 2>/dev/null && fail "idle accepted"
state a:a2 waiting
$TMUX set-session-status -t a done || fail "set-session-status done"
state a:a1 ''
state a:a2 ''

# The window list draws the state through @claude-style.
$TMUX set -g @claude-style \
    '#{?#{==:#{@claude},working},#[fg=#39BAE6],#{?#{==:#{@claude},waiting},#[fg=#FFB454],}}' ||
    fail "set @claude-style"
$TMUX set-window-status -t b:b1 working || fail "set b1 working"
$TMUX display -p -t b:b1 '#{E:window-status-format}' | tr -d '\r' |
    grep -q '#\[fg=#39BAE6\]' || fail "working not drawn blue"
$TMUX set-window-status -t b:b1 done || fail "set b1 done"
$TMUX display -p -t b:b1 '#{E:window-status-format}' | tr -d '\r' |
    grep -q 'fg=#39BAE6' && fail "done still drawn blue"

# The current window and session are marked by brackets alone: colour is the
# state's, so a finished one draws in the grey of every other finished name.
$TMUX display -p -t b:b1 '#{T:window-status-current-format}' | tr -d '\r' |
    grep -Fqx '[b1]#[none]' || fail "current window not plain brackets"
$TMUX show -gv status-sessions-format | tr -d '\r' |
    grep -Fq 'list=focus]#[fg=#8a8f98][#S]' ||
    fail "current session not plain brackets"

$TMUX kill-server 2>/dev/null
exit 0
