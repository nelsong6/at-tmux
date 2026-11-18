#!/bin/sh

# new-session -H makes a hidden session (TMUX-237): the sessions row neither
# lists nor counts it, so with one other session there is still no row, and a
# client on it shows the session it is grouped with as its own; a target that
# names no session never picks it; #{session_hidden} says which it is. The
# client runs in a pane of a second server, whose copy shows the rows it drew.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
$OUTER kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap "$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; rm -rf $OUT" 0 1 15
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=1
}

SHELL_CFG="set -g default-shell '$(cygpath -w "$SYSTEMROOT")\\System32\\cmd.exe'"
CFG="$OUT/hidden.conf"
printf '%s\nset -g status-position top\nset -g status-right ""\n' "$SHELL_CFG" >"$CFG"
OUTER_CFG="$OUT/outer.conf"
printf '%s\nset -g status off\n' "$SHELL_CFG" >"$OUTER_CFG"

$TMUX -f "$CFG" new -d -x60 -y10 -s alpha -n one </dev/null || exit 1
$TMUX neww -d -t alpha -n two || exit 1
$TMUX new -d -H -s shot -t alpha || exit 1
$TMUX selectw -t shot:two || exit 1

[ "$($TMUX display -p -t shot '#{session_hidden}' | tr -d '\r')" = 1 ] ||
    fail "shot's session_hidden isn't 1"
[ "$($TMUX display -p -t alpha '#{session_hidden}' | tr -d '\r')" = 0 ] ||
    fail "alpha's session_hidden isn't 0"
row=$($TMUX display -p -t alpha '#{S:#{session_name} }' | tr -d '\r')
[ "$row" = "alpha " ] || fail "the S: loop is '$row', not 'alpha '"
[ "$($TMUX display -p -t alpha:one '#{session_name}' | tr -d '\r')" = alpha ] ||
    fail "alpha's window doesn't name alpha"
echo "PASS 1: the S: loop leaves a hidden session out"

$OUTER -f "$OUTER_CFG" new -d -x60 -y10 \
    "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach -t shot -f read-only,ignore-size" </dev/null ||
    exit 1
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }

screen() {
	$OUTER capture-pane -p 2>/dev/null | tr -d '\r'
}
# The first row drawn: the window bar when there is no sessions row.
first_row_has() {
	screen | head -1 | grep -q "$1"
}
wait_until first_row_has two || fail "the window bar isn't the first row: $(screen | head -2)"
screen | head -2 | grep -q shot && fail "a hidden session drew a sessions row: $(screen | head -2)"
echo "PASS 2: one session and a hidden one draw no sessions row"

$TMUX new -d -s beta </dev/null || exit 1
row_shows_alpha() {
	screen | head -1 | grep -q '\[alpha\]'
}
wait_until row_shows_alpha || fail "the sessions row doesn't show alpha as current: $(screen | head -2)"
screen | head -1 | grep -q beta || fail "the sessions row doesn't list beta: $(screen | head -1)"
screen | head -1 | grep -q shot && fail "the sessions row lists the hidden session: $(screen | head -1)"
echo "PASS 3: a client on a hidden session shows its group's session as current"

name=$($TMUX display -p '#{session_name}' | tr -d '\r')
[ "$name" != shot ] || fail "a command with no target picked the hidden session"
name=$($TMUX display -p -t "$($TMUX display -p -t alpha:two '#{window_id}' | tr -d '\r')" '#{session_name}' | tr -d '\r')
[ "$name" = alpha ] || fail "the window's target found session '$name', not alpha"
echo "PASS 4: a target that names no session passes over a hidden one"

$TMUX kill-session -t shot || fail "kill-session shot"
[ "$($TMUX display -p -t alpha '#{window_name}' | tr -d '\r')" = one ] ||
    fail "choosing a window in the hidden session changed alpha's"
echo "PASS 5: the hidden session's window choice was its own"

[ $FAIL -eq 0 ] || exit 1
exit 0
