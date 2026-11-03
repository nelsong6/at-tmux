#!/bin/sh

# reorder-session moves a session to another place in the sessions row (the
# S: loop's index order): front, back, one place either way, or before or
# after a named session. A session made afterwards goes at the end.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

trap "$TMUX kill-server 2>/dev/null" 0 1 15
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=1
}

row() {
	$TMUX display -p '#{S:#{session_name} }' | tr -d '\r' | sed 's/ $//'
}

# expect ROW DESCRIPTION
expect() {
	_r=$(row)
	[ "$_r" = "$1" ] || fail "$2: row is '$_r', not '$1'"
}

$TMUX -fNUL new -d -s a < /dev/null || exit 1
for s in b c d; do
	$TMUX new -d -s $s < /dev/null || exit 1
done
expect "a b c d" "sessions not in the order made"

$TMUX reorder-session -s d front || fail "front refused"
expect "d a b c" "front"
$TMUX reorders -s d back || fail "back refused"
expect "a b c d" "back"
$TMUX reorders -s c forward || fail "forward refused"
expect "a c b d" "forward"
$TMUX reorders -s a forward || fail "forward at the front refused"
expect "a c b d" "forward at the front"
$TMUX reorders -s d backward || fail "backward at the back refused"
expect "a c b d" "backward at the back"
$TMUX reorders -s a backward || fail "backward refused"
expect "c a b d" "backward"
echo "PASS 1: front, back, forward and backward"

$TMUX reorders -s d -t c || fail "-t refused"
expect "d c a b" "before a session"
$TMUX reorders -s d -t b -a || fail "-t -a refused"
expect "c a b d" "after a session"
$TMUX reorders -s c -t =c || fail "-t itself refused"
expect "c a b d" "before itself"
echo "PASS 2: before and after a named session"

$TMUX reorders -s c 2>/dev/null && fail "no place accepted"
$TMUX reorders -s c sideways 2>/dev/null && fail "unknown place accepted"
$TMUX reorders -s c -t a front 2>/dev/null && fail "a place with -t accepted"
$TMUX reorders -s c -t a -a -b 2>/dev/null && fail "-a with -b accepted"
expect "c a b d" "a refused command changed the row"
echo "PASS 3: a bad place is refused and changes nothing"

$TMUX new -d -s e < /dev/null || fail "new session e"
expect "c a b d e" "a new session"
$TMUX kill-session -t =a
$TMUX reorders -s e front || fail "front after kill-session refused"
expect "e c b d" "front after a session went"
$TMUX new -d -s f < /dev/null || fail "new session f"
expect "e c b d f" "a new session after a reorder"
echo "PASS 4: a new session goes at the end"

[ $FAIL -eq 0 ] || exit 1
exit 0
