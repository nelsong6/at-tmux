#!/bin/sh

# The hold (AHT-206): a new server whose @session-set-ready-file can't be read
# holds the restore of its previous set and the at server's @at-programs-start
# until it can, checking the file itself, and says so in #{server_restore},
# which home-sync's sign-in waits on; a client sees a menu saying so, whose
# Restore now (Enter) ends the hold at once and Escape closes, still waiting.
# Both options come from programs.conf, which the server reads as it starts,
# as home-sync's does. With no file named nothing is held. The server is an at
# server (its socket name ends in -at), the only one that runs the starts, so
# its config takes the desktop's keys straight back; it takes turns with the
# other tests that bind them. Clients run in a pseudo-console and keys reach
# them with send-keys -K.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
SOCKET="$TEST_SOCKET-at"
TMUX="$TEST_TMUX -L$SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap "$TMUX kill-server 2>/dev/null; rm -rf $OUT" 0 1 15
T=$(printf '\t')
M=$(cygpath -m "$OUT")

PS="$(cygpath -m "$POWERSHELL_EXE")"
SYS=$(cygpath -w "$SYSTEMROOT")
LONG="$SYS\System32\PING.EXE -n 300 127.0.0.1 >nul"
# A set last saved before this sign-in, so it comes back with no offer.
cat >"$OUT/test.conf" <<EOF
unbind -T global Win
unbind -T global M-Tab
unbind -T global M-BTab
unbind -a -T global-no-client
set -g default-shell '$COMSPEC'
set -g status off
set -g @session-set-dir '$M'
set -g @session-set-signin 4102444800
EOF
CONF=$(cygpath -m "$OUT/test.conf")
mkdir "$OUT/at-home"
PROGRAMS="$OUT/at-home/programs.conf"
START="set -g @at-programs-start \"run-shell -b 'echo started >>$M/started'\""
# The at server's own session set and programs.conf, under the test's folder.
export LOCALAPPDATA="$(cygpath -w "$OUT")"
export USERPROFILE="$(cygpath -w "$OUT")"
# Not the run's own programs.conf, win32-run.sh's (TMUX-254).
unset TMUX_PROGRAMS_CONF

fail() {
	echo "FAIL: $1"
	$TMUX ls 2>&1
	$TMUX show-messages 2>&1 | grep session-set
	ls -R "$OUT" 2>&1
	exit 1
}

attach() {
	"$PS" -NoProfile -ExecutionPolicy Bypass \
	    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
	    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -L$SOCKET attach" \
	    -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$OUT/resize")" &
	wait_until attached || fail "client never attached"
	CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
}
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}

# stop: kill-server, which leaves its snapshot open as a reboot does.
stop() {
	$TMUX kill-server
	wait_gone
	sleep 1.1
}

# press KEY until CHECK holds: the menu draws a moment after the client
# attaches, and a key before that goes to the pane.
press_until() {
	_key=$1
	shift
	_tries=$((WAIT_TIMEOUT * 2))
	until "$@"; do
		_tries=$((_tries - 1))
		[ $_tries -gt 0 ] || return 1
		$TMUX send-keys -K -c "$CLIENT" "$_key" 2>/dev/null
		sleep 0.5
	done
}

sessions_are() {
	[ "$($TMUX ls -F '#{session_name}' 2>/dev/null | tr -d '\r' | tr '\n' ' ' |
	    sed 's/ $//')" = "$1" ]
}
messages_have() {
	$TMUX show-messages 2>/dev/null | tr -d '\r' | grep -q -- "$1"
}
starts_are() {
	[ "$(cat "$OUT/started" 2>/dev/null | wc -l)" -eq "$1" ]
}
snap() { echo "$OUT/live/$($TMUX display -p '#{b:socket_path}' | tr -d '\r').set"; }
snap_has() { grep -q -- "$2" "$1" 2>/dev/null; }
restore_is() {
	[ "$($TMUX display -p '#{server_restore}' 2>/dev/null | tr -d '\r')" = "$1" ]
}

# save: a set of main (two windows) beside primary, shown by a client.
save() {
	$TMUX new -d -s main -n one "$LONG" 2>/dev/null ||
	    $TMUX has -t =main || fail "new session main"
	$TMUX lsw -t =main -F '#{window_name}' | grep -q two ||
	    $TMUX new-window -d -t main: -n two "$LONG" || fail "new-window two"
	$TMUX switch-client -c "$CLIENT" -t main
	wait_until snap_has "$(snap)" "^attached${T}main$" || fail "set not saved"
	stop
}

# 1. A set to come back, from a server with no programs.conf.
$TMUX -f "$CONF" new -d -s primary || fail "start first server"
attach
save

# 2. The ready file is missing: the new server holds the restore and the
# start, and a client sees the wait. Escape closes it and the hold goes on;
# the file appearing ends it, restoring the set and running the start.
cat >"$PROGRAMS" <<EOF
set -g @session-set-ready-file '$M/ready'
$START
EOF
$TMUX -f "$CONF" new -d -s primary || fail "start second server"
wait_until messages_have "holding the restore and starts until $M/ready" ||
    fail "not held"
restore_is "waiting for the NAS" ||
    fail "server_restore does not say it waits: $($TMUX display -p '#{server_restore}')"
attach
wait_until messages_have "waiting shown on $CLIENT" || fail "wait not shown"
press_until Escape messages_have "waiting closed on $CLIENT, still holding" ||
    fail "Escape did not close the wait"
sessions_are primary || fail "restored while held"
starts_are 0 || fail "started while held"
# A client attaching later is shown the wait again.
$TMUX detach-client -t "$CLIENT"
wait_until eval '! attached' || fail "client did not detach"
attach
wait_until messages_have "waiting shown on $CLIENT" ||
    fail "wait not shown to a later client"
sessions_are primary || fail "restored while held, after Escape"
starts_are 0 || fail "started while held, after Escape"
echo ready >"$OUT/ready"
wait_until sessions_are "main primary" || fail "not restored once the file read"
wait_until starts_are 1 || fail "not started once the file read"
messages_have "session-set: ready file read after" || fail "release not recorded"
wait_until restore_is "" || fail "server_restore not empty after the restore"
echo 'PASS: held while the file is missing, released when it reads'

# 3. Restore now (Enter) ends the hold with the file still missing.
save
rm -f "$OUT/ready"
$TMUX -f "$CONF" new -d -s primary || fail "start third server"
wait_until messages_have "holding the restore and starts" || fail "third not held"
attach
wait_until messages_have "waiting shown on $CLIENT" || fail "third wait not shown"
sessions_are primary || fail "third restored while held"
restore_is "waiting for the NAS" || fail "third server_restore does not say it waits"
press_until Enter sessions_are "main primary" || fail "Enter did not restore"
wait_until starts_are 2 || fail "Enter did not start"
messages_have "session-set: released by Restore now" ||
    fail "Restore now not recorded"
wait_until restore_is "" || fail "server_restore not empty after Restore now"
echo 'PASS: Restore now ends the hold'

# 4. With no ready file named, nothing is held: the start runs and the set
# comes back as the server starts, with no client.
save
echo "$START" >"$PROGRAMS"
$TMUX -f "$CONF" new -d -s primary || fail "start fourth server"
wait_until starts_are 3 || fail "unheld start did not run"
wait_until sessions_are "main primary" || fail "unheld set not restored"
messages_have "holding the restore" && fail "held with no file named"
wait_until restore_is "" || fail "server_restore not empty with no hold"
echo 'PASS: no ready file, no hold'

echo 'ALL SESSION HOLD TESTS PASSED'
