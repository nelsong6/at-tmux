#!/bin/sh

# A server's flight record on Linux and macOS: a clean end leaves none, and a
# SIGKILL leaves a report that the next server writes.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Lflight-$$"
OUT=$(mktemp -d) || exit 1
TMUX_FLIGHT_DIR=$OUT/flight
TMUX_ERROR_LOG_DIR=$OUT/errors
export TMUX_FLIGHT_DIR TMUX_ERROR_LOG_DIR
trap '$TMUX kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15

fail() {
	echo "FAIL: $1"
	ls -la "$OUT/flight" 2>/dev/null
	exit 1
}
wait_for() {
	i=0
	while [ "$i" -lt 100 ]; do
		"$@" && return 0
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}
no_records() { ! ls "$OUT"/flight/*.rec >/dev/null 2>&1; }
killed() { ! $TMUX list-sessions >/dev/null 2>&1; }

$TMUX -f/dev/null new -d || fail 'new-session'
pid=$($TMUX display-message -p '#{pid}')
ls "$OUT"/flight/*"-$pid.rec" >/dev/null 2>&1 || fail 'a running server has no record'
$TMUX kill-server
wait_for no_records || fail 'a clean end left a record'
[ ! -d "$OUT/flight/ended" ] || fail 'a clean end was reported'

$TMUX -f/dev/null new -d || fail 'new-session'
pid=$($TMUX display-message -p '#{pid}')
$TMUX set -g @flight-test 1
kill -9 "$pid"
wait_for killed || fail 'the server outlived its kill'
$TMUX -f/dev/null new -d || fail 'new-session'
report=$OUT/flight/ended/tmux-$pid.log
[ -f "$report" ] || fail 'a killed server was not reported'
grep -q '^ended: *with no record of why' "$report" || fail 'the report says nothing of how it ended'
grep -q 'command set-option' "$report" || fail 'the report has no recent events'

echo PASS
exit 0
