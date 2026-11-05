#!/bin/sh

# Two clients attached to one server can each be named. Every Windows console
# reports the tty CON, so before TMUX-119 both clients were called CON and a
# command naming one reached whichever attached first. Each client runs in its
# own pane of a second server, so each has a console of its own.

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
EXE=$(cygpath -ma "$TEST_TMUX")

fail() {
	echo "FAIL: $1"
	FAIL=1
}

pass() {
	[ "$FAIL" -eq 0 ] && echo "PASS $1"
}

# The status line's job records each run, per client: with status-interval 0
# it runs again only when that client's status is refreshed.
cat >"$OUT/inner.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status on
set -g status-interval 0
set -g status-right '#(echo run>>$(cygpath -m "$OUT")/run-#{client_pid})'
EOF
cat >"$OUT/outer.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
EOF

$TMUX -f "$OUT/inner.conf" new -d -s one -x 80 -y 24 </dev/null || exit 1
$TMUX new -d -s two </dev/null || exit 1
$OUTER -f "$OUT/outer.conf" new -d -s out -x 80 -y 24 \
    "\"$EXE\" -L$TEST_SOCKET attach -t one" </dev/null || exit 1

clients_are() {
	[ "$($TMUX list-clients 2>/dev/null | wc -l)" -eq "$1" ]
}
wait_until clients_are 1 || { echo "first client never attached"; exit 1; }
FIRST=$($TMUX list-clients -F '#{client_pid}' | tr -d '\r')

# Attached second, so a name both shared would reach the first, not this one.
$OUTER neww -d -t out "\"$EXE\" -L$TEST_SOCKET attach -t one" </dev/null || exit 1
wait_until clients_are 2 || { echo "second client never attached"; exit 1; }
SECOND=$($TMUX list-clients -F '#{client_pid}' | tr -d '\r' | grep -v "^$FIRST$")
[ -n "$FIRST" ] && [ -n "$SECOND" ] && [ "$FIRST" != "$SECOND" ] ||
    { echo "clients not told apart: $FIRST, $SECOND"; exit 1; }
NAME1=client-$FIRST
NAME2=client-$SECOND

# --- Test 1: each client has a name of its own, from its process ---
[ "$($TMUX list-clients -F '#{client_pid} #{client_name}' | tr -d '\r' | sort)" = \
    "$(printf '%s\n%s\n' "$FIRST $NAME1" "$SECOND $NAME2" | sort)" ] ||
    fail "names: $($TMUX list-clients -F '#{client_pid} #{client_name}')"
[ "$($TMUX list-clients -F '#{client_tty}' | tr -d '\r' | sort -u)" = CON ] ||
    fail "client_tty changed: $($TMUX list-clients -F '#{client_tty}')"
pass "1: each client's name is its own"

# --- Test 2: a command naming a client reaches that client ---
for pair in "$NAME1 $FIRST" "$NAME2 $SECOND"; do
	set -- $pair
	GOT=$($TMUX display-message -c "$1" -p '#{client_pid}' | tr -d '\r')
	[ "$GOT" = "$2" ] || fail "display-message -c $1 reached $GOT"
done
pass "2: a name reaches its client"

# --- Test 3: refreshing one client's status runs only its job ---
runs() {
	if [ -f "$OUT/run-$1" ]; then
		wc -l <"$OUT/run-$1" | tr -d ' '
	else
		echo 0
	fi
}
ran() {
	[ "$(runs "$1")" -gt "$2" ]
}
wait_until ran "$FIRST" 0 || fail "first client's job never ran"
wait_until ran "$SECOND" 0 || fail "second client's job never ran"

RUNS1=$(runs "$FIRST")
RUNS2=$(runs "$SECOND")
$TMUX refresh-client -S -t "$NAME2"
wait_until ran "$SECOND" "$RUNS2" || fail "refresh of the second client ran nothing"
RUNS2=$(runs "$SECOND")
$TMUX refresh-client -S -t "$NAME1"
wait_until ran "$FIRST" "$RUNS1" || fail "refresh of the first client ran nothing"
[ "$(runs "$SECOND")" = "$RUNS2" ] || fail "refreshing the first ran the second's job"
pass "3: a refresh reaches the client named and no other"

# --- Test 4: switch-client -c moves the client named ---
$TMUX switch-client -c "$NAME2" -t two
session_of() {
	$TMUX list-clients -F '#{client_pid} #{client_session}' | tr -d '\r' |
	    sed -n "s/^$1 //p"
}
second_moved() {
	[ "$(session_of "$SECOND")" = two ]
}
wait_until second_moved || fail "second client stayed in $(session_of "$SECOND")"
[ "$(session_of "$FIRST")" = one ] || fail "first client moved to $(session_of "$FIRST")"
pass "4: switch-client moves the client named"

# --- Test 5: a choice in choose-client acts on the client chosen ---
# Its Enter runs detach-client on the row's client.
$TMUX choose-client -t two -f "#{==:#{client_pid},$SECOND}"
in_mode() {
	[ "$($TMUX display -t two -p '#{pane_in_mode}' | tr -d '\r')" = 1 ]
}
wait_until in_mode || fail "choose-client never opened"
$TMUX send-keys -t two Enter
wait_until clients_are 1 || fail "choose-client detached nobody"
[ "$($TMUX list-clients -F '#{client_pid}' | tr -d '\r')" = "$FIRST" ] ||
    fail "choose-client detached the other client"
pass "5: choose-client detaches the client chosen"

$OUTER kill-server 2>/dev/null
$TMUX kill-server 2>/dev/null

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CLIENT NAME TESTS PASSED"
exit 0
