#!/bin/sh

# The session set's offer says how the server that saved the set really ended:
# told to exit, killed from outside, crashed, or nothing says, each with its own
# title, and the answer is that server's even with others come and gone since.
# The client runs in a pane of a second server, whose copy shows what it drew.

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
package=$(cd "$(dirname "$TEST_TMUX")" && pwd)
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15

cat >"$OUT/test.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
set -g @session-set-dir '$(cygpath -m "$OUT/sets")'
set -g @session-set-signin 0
EOF
CONF=$(cygpath -m "$OUT/test.conf")
cat >"$OUT/outer.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
EOF

fail() {
	echo "FAIL: $1"
	$OUTER capture-pane -p 2>&1
	ls -R "$OUT" 2>&1
	exit 1
}

$OUTER -f "$(cygpath -m "$OUT/outer.conf")" new -d -x 100 -y 30 </dev/null ||
    fail 'outer server'
$OUTER send-keys "set TMUX=" Enter

screen_has() { $OUTER capture-pane -p | tr -d '\r' | grep -q -- "$1"; }
messages_have() { $TMUX show-messages | tr -d '\r' | grep -q -- "$1"; }
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
detached() { [ -z "$($TMUX list-clients 2>/dev/null)" ]; }
killed() { ! $TMUX list-sessions >/dev/null 2>&1; }
snapshot() { ls "$OUT"/sets/live/*"$TEST_SOCKET".set 2>/dev/null; }
previous() { ls "$OUT"/sets/live/*-previous.set >/dev/null 2>&1; }
snapshot_saved() { [ -n "$(snapshot)" ] && grep -q "$1" "$(snapshot)"; }

# started: a server, with a client that has shown it, so its set is offered.
started() {
	TMP=$(cygpath -aw "$OUT") $TMUX -f "$CONF" new -d -s kept -x 100 -y 30 </dev/null ||
	    fail 'starting a server'
	pid=$($TMUX display-message -p '#{pid}' | tr -d '\r')
}
shown() {
	started
	$OUTER send-keys "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach" Enter
	wait_until attached || fail 'no client attached'
	wait_until snapshot_saved "^attached.kept" || fail 'the set was not saved'
	sleep 1.1
}
kill_it() {
	"$taskkill" //F //PID "$pid" >/dev/null || fail 'killing the server'
	wait_until killed || fail 'the server outlived its kill'
	sleep 1.1
}

# offered WORDS: the next client gets a menu saying WORDS. Escape archives the
# set and leaves the client in the fresh server.
offered() {
	$OUTER send-keys "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach" Enter
	wait_until attached || fail 'no client attached'
	for _words in "$@"; do
		wait_until screen_has "$_words" || fail "the menu lacks: $_words"
	done
	$TMUX send-keys -K -c "$($TMUX list-clients -F '#{client_name}' | tr -d '\r')" Escape
	gone_previous() { ! previous; }
	wait_until gone_previous || fail 'Escape left the set'
}
not_offered() { ! screen_has "$1" || fail "the menu says: $1"; }
# stopped: the running server is gone, leaving its set as kill-server does.
stopped() {
	$TMUX kill-server
	wait_until killed || fail 'kill-server'
	sleep 1.1
}
detach() {
	$TMUX detach-client
	wait_until detached || fail 'the client stayed'
	$OUTER send-keys "cls" Enter
	cleared() { ! screen_has 'tmux server'; }
	wait_until cleared || fail 'the screen stayed'
}

# Told to exit: the snapshot says so, and that is no crash.
shown
stopped
snapshot_saved '^stopped.[1-9]' || fail 'the snapshot does not say it was stopped'
started
offered ' Server shut down ' 'The tmux server was told to exit'
not_offered 'crash'
messages_have 'offered after being told to exit' || fail 'not logged as an exit'
detach
stopped

# Killed from outside: its report has no crash in it.
shown
kill_it
dead=$pid
started
offered ' Server killed ' 'The tmux server was killed from outside' \
    "ended/tmux-$dead.log"
messages_have 'offered after an outside kill' || fail 'not logged as a kill'
detach
stopped

# The answer is the server that saved the set: one no client showed dies after
# it, and the menu still names the first.
shown
kill_it
dead=$pid
started
wait_until previous || fail 'the set was not set aside'
kill_it
started
offered ' Server killed ' "ended/tmux-$dead.log"
detach
stopped

# A crash gives its reason. win32-crash.ps1 finds tmux.pdb beside the exe.
shown
"$powershell" -NoProfile -ExecutionPolicy Bypass \
    -File "$(cygpath -aw "$(dirname "$0")/win32-crash.ps1")" -Id "$pid" \
    -Exe "$(cygpath -aw "$package/tmux.exe")" ||
    fail 'crashing the server'
wait_until killed || fail 'the server outlived its crash'
sleep 1.1
dead=$pid
started
offered ' Server crashed ' 'The tmux server crashed: exception' \
    "ended/tmux-$dead.log"
messages_have 'offered after a crash' || fail 'not logged as a crash'
detach
stopped

# A # in a reason is text, not a format.
shown
kill_it
dead=$pid
started
sed 's/^ended: .*/ended:        crashed: bad #{pid} #[bold] text/' \
    "$OUT/flight/ended/tmux-$dead.log" >"$OUT/edited"
cat "$OUT/edited" >"$OUT/flight/ended/tmux-$dead.log"
offered 'crashed: bad #{pid} #\[bold\] text'
detach
stopped

# A report older than the set is an earlier process with that pid, so it says
# nothing, and the menu doesn't guess.
shown
kill_it
dead=$pid
started
touch -d '2020-01-01' "$OUT/flight/ended/tmux-$dead.log" ||
    fail 'dating the report'
offered ' Previous session set ' 'nothing says why'
not_offered 'crash'
messages_have 'offered after a stop with no report' || fail 'not logged'

echo PASS
exit 0
