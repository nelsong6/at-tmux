#!/bin/sh

# A window's @claude attention is the user's move: it is unset once a client
# looks at the window, where waiting stays. The sessions row colours a session
# by @claude-style while any of its windows is waiting or attention.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest-claude-attention"
TMUX_OUTER="$TEST_TMUX -Ltest-claude-attention-outer"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
$TMUX_OUTER kill-server 2>/dev/null
wait_gone

trap "$TMUX kill-server 2>/dev/null; $TMUX_OUTER kill-server 2>/dev/null" 0 1 15

fail() {
	echo "claude-attention: $1" >&2
	exit 1
}

state() {
	$TMUX display -p -t "$1" '#{@claude}'
}

$TMUX -f/dev/null new -d -x100 -y30 -s a -n a1 </dev/null || fail "new a"
$TMUX neww -d -t a: -n a2 || fail "new a2"
$TMUX neww -d -t a: -n a3 || fail "new a3"
$TMUX new -d -s b -n b1 || fail "new b"
$TMUX set -g @claude-style \
    '#{?#{==:#{@claude},attention},#[fg=#ffb454],#{?#{==:#{@claude},waiting},#[fg=#ffb454],}}'

$TMUX set-window-status -t a:a2 attention || fail "set a2 attention"
$TMUX set-window-status -t a:a3 waiting || fail "set a3 waiting"
[ "$(state a:a2)" = attention ] || fail "attention not set"
$TMUX display -p -t b '#{T:status-sessions-format}' | grep -q 'fg=#ffb454.*a' ||
	fail "session a not coloured"
$TMUX set-window-status -t a:a2 bogus 2>/dev/null && fail "bogus accepted"

# No client looks at a, so selecting its windows clears nothing.
$TMUX selectw -t a:a2
[ "$(state a:a2)" = attention ] || fail "attention cleared with no client"

# A client on a looks at a2: attention goes, waiting on a3 stays.
$TMUX selectw -t a:a1
$TMUX_OUTER -f/dev/null new -d -x100 -y30 "$TMUX attach -t a" </dev/null ||
	fail "outer server"
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || fail "client did not attach"
[ "$(state a:a2)" = attention ] || fail "a2 cleared while not current"
$TMUX selectw -t a:a2
[ -z "$(state a:a2)" ] || fail "attention kept after it was seen"
$TMUX selectw -t a:a3
[ "$(state a:a3)" = waiting ] || fail "waiting cleared when seen"

# Set on the window being looked at, attention is seen at once.
$TMUX set -w -t a:a3 @claude attention
[ -z "$(state a:a3)" ] || fail "attention on the current window kept"
$TMUX set -w -t a:a1 @claude attention
[ "$(state a:a1)" = attention ] || fail "attention on another window lost"

exit 0
