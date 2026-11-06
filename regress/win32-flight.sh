#!/bin/sh

# A server's flight record: a clean end leaves none, a forced kill leaves a
# report the next server writes and tells the first client about, a client that
# saw the server go gives the moment, upgrade-server reports nothing, and a
# server Windows took with it is reported as that, without telling the client.

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
system=$(cygpath "$SYSTEMROOT")/System32
taskkill=$system/taskkill.exe
powershell=$system/WindowsPowerShell/v1.0/powershell.exe
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
$TMUX show-messages | tr -d '\r' | grep -q 'was killed from outside' ||
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
told() { $OUTER capture-pane -p | tr -d '\r' | grep -q 'was killed from outside'; }
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

# say_ending [SWITCH]: Windows' messages for the session ending, once the server
# has its window up. goes: the end itself, with nothing more from the server.
say_ending() {
	"$powershell" -NoProfile -ExecutionPolicy Bypass \
	    -File "$(cygpath -aw "$(dirname "$0")/win32-endsession.ps1")" \
	    -Id "$pid" "$@" 2>/dev/null
}
goes() {
	dead=$pid
	"$taskkill" //F //PID "$dead" >/dev/null || fail 'ending the server'
	wait_until killed || fail 'the server outlived its end'
}
ended_line() { tr -d '\r' <"$OUT/flight/ended/tmux-$dead.log" | grep '^ended:'; }
attach() {
	$OUTER send-keys "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach" Enter
	wait_until attached || fail 'no client attached'
}

# Windows ending the session is reported as that, and it is not news: the first
# client is told nothing, and show-messages and the report still say so.
wait_until say_ending || fail 'the server did not take the end of the session'
goes
started
ended_line | grep -q '^ended: *with Windows: Windows ended the session at 2' ||
    fail 'the report does not say Windows ended it'
$TMUX show-messages | tr -d '\r' | grep -q 'The last tmux server ended with Windows' ||
    fail 'show-messages does not say Windows ended it'
attach
sleep 1
! $OUTER capture-pane -p | grep -q 'The last tmux server' ||
    fail 'the first client was told of a Windows ending'

# A shutdown that was called off, or an installer closing the server, is not the
# session ending: a kill afterwards is a kill.
wait_until say_ending -Cancelled || fail 'telling the server it was called off'
goes
started
ended_line | grep -q '^ended: *with no record of why' ||
    fail 'a cancelled shutdown counted'
wait_until say_ending -Installer || fail 'telling the server of an installer'
goes
started
ended_line | grep -q '^ended: *with no record of why' ||
    fail 'an installer counted'

# With no word from Windows, a server that last worked before this sign-in may
# have gone with the PC or not: the report and the client get just that.
goes
TMUX_FLIGHT_SIGNIN=9999999999
export TMUX_FLIGHT_SIGNIN
started
unset TMUX_FLIGHT_SIGNIN
ended_line | grep -q '^ended: *before this Windows sign-in: no word from Windows' ||
    fail 'the report does not say it ended before this sign-in'
attach
before() { $OUTER capture-pane -p | tr -d '\r' | grep -q 'before this Windows'; }
wait_until before || fail 'the first client was not told'

echo PASS
exit 0
