#!/bin/sh

# A server busy on its main thread is still there: clients wait in line rather
# than being told there is no server, however many there are, and one that has
# heard nothing for ten seconds says so and goes on waiting. Only a server that
# has gone reads as "no server running". One core is busy, for a few seconds.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

DIR=$(mktemp -d)
WDIR=$(cygpath -m "$DIR")
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
trap "$TMUX kill-server 2>/dev/null; rm -rf $DIR $CFG" 0 1 15

fail() {
	echo "FAIL: $1"
	head -3 "$DIR"/out.* 2>/dev/null
	exit 1
}

$TMUX -f"$(cygpath -m $CFG)" new -d -s main || fail "start server"

# A file that takes the server's main thread a while: LINES lines of it.
busy_file() {
	awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) print "set -g @busy 1" }' \
	    >"$DIR/busy.conf"
}
# How long LINES of it take, in milliseconds.
measure() {
	busy_file "$1"
	_a=$(date +%s%3N)
	$TMUX source-file "$WDIR/busy.conf" || fail "source the busy file"
	echo $(($(date +%s%3N) - _a))
}
# Lines for about $1 seconds, from a measured run.
LINES=20000
MS=$(measure $LINES)
[ "$MS" -gt 0 ] || MS=1
lines_for() { echo $(($1 * 1000 * LINES / MS)); }

# 1. Sixteen clients while the server is busy: all answered, none turned away.
#    Each takes two connection passes, and before this the table held sixteen.
busy_file "$(lines_for 4)"
$TMUX source-file "$WDIR/busy.conf" &
BUSY=$!
sleep 0.5
PIDS=
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
	$TMUX display -p answered$i >"$DIR/out.$i" 2>&1 &
	PIDS="$PIDS $!"
done
for pid in $PIDS; do
	wait "$pid" || BAD=1
done
wait "$BUSY"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
	[ "$(tr -d '\r' <"$DIR/out.$i")" = "answered$i" ] ||
	    fail "client $i: $(cat "$DIR/out.$i")"
done
[ -z "$BAD" ] || fail "a client exited non-zero"

# 2. A client kept waiting over ten seconds says so, then gets its answer. The
#    measured length runs short on some machines: a wait under ten seconds proves
#    nothing, so it goes again with twice as much.
SECONDS_BUSY=13
for attempt in 1 2 3; do
	busy_file "$(lines_for $SECONDS_BUSY)"
	$TMUX source-file "$WDIR/busy.conf" &
	BUSY=$!
	sleep 0.5
	WAIT_START=$(date +%s%3N)
	$TMUX display -p answered >"$DIR/out.long" 2>"$DIR/err.long" ||
	    fail "the long wait failed: $(cat "$DIR/err.long")"
	WAITED=$(($(date +%s%3N) - WAIT_START))
	wait "$BUSY"
	[ "$WAITED" -lt 10500 ] || break
	SECONDS_BUSY=$((SECONDS_BUSY * 2))
done
[ "$WAITED" -ge 10500 ] || fail "the server was only busy for $WAITED ms"
[ "$(tr -d '\r' <"$DIR/out.long")" = "answered" ] || fail "no answer after the wait"
grep -q "has not answered for 10 seconds, still waiting" "$DIR/err.long" ||
    fail "the wait wasn't reported: $(cat "$DIR/err.long")"

# 3. A quick client says nothing of the kind, and a long command that was heard
#    doesn't either: run-shell here takes as long as the wait above.
$TMUX display -p answered >/dev/null 2>"$DIR/err.quick"
[ ! -s "$DIR/err.quick" ] || fail "a quick client reported a wait"
$TMUX run-shell -d 11 >/dev/null 2>"$DIR/err.heard"
[ ! -s "$DIR/err.heard" ] || fail "a command that was heard reported a wait"

# 4. A server that has gone is the only one with no server running.
$TMUX kill-server
wait_gone
if $TMUX display -p answered 2>"$DIR/err.gone"; then
	fail "a client was answered by a server that has gone"
fi
grep -q "^no server running on " "$DIR/err.gone" ||
    fail "a server that has gone reads as: $(cat "$DIR/err.gone")"

exit 0
