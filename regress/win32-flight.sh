#!/bin/sh

# A server's flight record: a clean end leaves none, a forced kill leaves a
# report the next server writes and tells the first client about, a client that
# saw the server go gives the moment, and upgrade-server reports nothing.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
OUT=$(mktemp -d) || exit 1
TMUX_FLIGHT_DIR=$(cygpath -m "$OUT/flight")
TMUX_ERROR_LOG_DIR=$(cygpath -m "$OUT/errors")
export TMUX_FLIGHT_DIR TMUX_ERROR_LOG_DIR
taskkill=$(cygpath "$SYSTEMROOT")/System32/taskkill.exe
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15

fail() {
	echo "FAIL: $1"
	ls -la "$OUT/flight" "$OUT/flight/ended" 2>/dev/null
	cat "$OUT"/flight/ended/* 2>/dev/null
	exit 1
}
started() {
	$TMUX -fNUL new -d -x 80 -y 24 </dev/null || fail 'new-session'
	pid=$($TMUX display-message -p '#{pid}' | tr -d '\r')
	[ -n "$pid" ] || fail 'no server pid'
}
record() { ls "$OUT"/flight/*"-$1.rec" >/dev/null 2>&1; }
no_records() { ! ls "$OUT"/flight/*.rec >/dev/null 2>&1; }
killed() { ! $TMUX list-sessions >/dev/null 2>&1; }

# A clean end leaves no record, no report, and a line saying how.
started
record "$pid" || fail 'a running server has no record'
$TMUX kill-server
WAIT_TIMEOUT=30 wait_until no_records || fail 'a clean end left a record'
[ ! -d "$OUT/flight/ended" ] || fail 'a clean end was reported'
grep -q 'ended: told to exit' "$OUT/errors/tmux-$pid.log" ||
    fail 'a clean end left no line saying how'

# A forced kill gets no chance to clean up, and the record survives it.
started
$TMUX set -g @flight-test 1
"$taskkill" //F //PID "$pid" >/dev/null || fail 'killing the server'
wait_until killed || fail 'the server outlived its kill'
dead=$pid
started
report=$OUT/flight/ended/tmux-$dead.log
[ -f "$report" ] || fail 'a killed server was not reported'
tr -d '\r' <"$report" | grep -q '^ended: *with no record of why' ||
    fail 'the report says nothing of how it ended'
tr -d '\r' <"$report" | grep -q '^ran as: *no package' ||
    fail 'the report does not say what the server ran inside'
tr -d '\r' <"$report" | grep -q 'command set-option' ||
    fail 'the report has no recent events'
tr -d '\r' <"$report" | grep -q '^client lost: *not recorded' ||
    fail 'no client saw that server go'
$TMUX show-messages | tr -d '\r' | grep -q 'ended without saying why' ||
    fail 'show-messages does not say'
! ls "$OUT"/flight/*"-$dead.rec" >/dev/null 2>&1 || fail 'a reported record stayed'

# A client attached when the server goes gives the moment, and the next server
# tells the first client to attach.
cat >"$OUT/outer.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
EOF
$OUTER -f "$OUT/outer.conf" new -d -x 80 -y 24 </dev/null || fail 'outer server'
$OUTER send-keys "set TMUX=" Enter "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach" Enter
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || fail 'no client attached'
"$taskkill" //F //PID "$pid" >/dev/null || fail 'killing the attached server'
dead=$pid
lost() { ls "$OUT"/flight/*.lost >/dev/null 2>&1; }
wait_until lost || fail 'the client noted nothing'
started
report=$OUT/flight/ended/tmux-$dead.log
tr -d '\r' <"$report" | grep -q '^client lost: *2[0-9-]* [0-9:]*$' ||
    fail 'the report has no moment the client lost it'
$OUTER send-keys "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach" Enter
told() { $OUTER capture-pane -p | tr -d '\r' | grep -q 'ended without saying why'; }
wait_until told || { $OUTER capture-pane -p; fail 'the first client was not told'; }

# A handover ends the old server cleanly, with nothing to report.
old=$pid
$TMUX upgrade-server "$(cygpath -w "$TEST_TMUX")" || fail 'upgrade-server'
upgraded() { [ "$($TMUX display -p '#{pid}' | tr -d '\r')" != "$old" ]; }
wait_until upgraded || fail 'the server was not replaced'
pid=$($TMUX display-message -p '#{pid}' | tr -d '\r')
record "$pid" || fail 'the new server has no record'
gone_old() { ! ls "$OUT"/flight/*"-$old.rec" >/dev/null 2>&1; }
wait_until gone_old || fail 'the old server left its record'
[ ! -f "$OUT/flight/ended/tmux-$old.log" ] || fail 'a handover was reported'
grep -q "ended: handed over to $pid" "$OUT/errors/tmux-$old.log" ||
    fail 'the handover left no line saying how'

echo PASS
exit 0
