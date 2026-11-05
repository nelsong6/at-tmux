#!/bin/sh

# What a new server does with the set an earlier one left depends on how it ended.
# Last saved before this Windows sign-in, it ended with the PC: it comes back with
# no offer, whether a client is there or not. Saved since, it was lost while the
# PC stayed up: the offer asks and says it is likely crash recovery, as it does
# for a set whose restore the last server died in. @session-set-signin stands in
# for the sign-in's time, since CI's runner has none. Clients run in a pane of a
# second server, whose capture shows what they drew; upgrading runs beside
# conpty.dll.

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
T=$(printf '\t')

SYS=$(cygpath -w "$SYSTEMROOT")
LONG="$SYS\System32\PING.EXE -n 300 127.0.0.1 >nul"
PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"

# config SIGNIN: the time the sign-in began, for the next server.
config() {
	cat >"$OUT/test.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
set -g @session-set-dir '$(cygpath -m "$OUT")'
set -g @session-set-signin $1
EOF
}
config 4000000000
CONF=$(cygpath -m "$OUT/test.conf")
cat >"$OUT/outer.conf" <<EOF
set -g default-shell "$PS"
set -g status off
EOF
OUTER_CONF=$(cygpath -m "$OUT/outer.conf")
EXE=$(cygpath -ma "$TEST_TMUX")

fail() {
	echo "FAIL: $1"
	$TMUX ls 2>&1
	$TMUX show-messages 2>&1 | tail -10
	$OUTER capture-pane -p 2>&1
	ls -R "$OUT" 2>&1
	exit 1
}

# attach [ARGS]: a client in a pane of the outer server. "attach" by default.
attach() {
	$OUTER kill-server 2>/dev/null
	$OUTER -f "$OUTER_CONF" new -d -x100 -y30 \
	    "& '$EXE' -L$TEST_SOCKET ${1:-attach}" </dev/null ||
	    fail "start outer server"
	wait_until attached || fail "client never attached"
	CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r' | head -1)
}
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
drawn() {
	$OUTER capture-pane -p 2>/dev/null | tr -d '\r' | grep -q -- "$1"
}
detach() {
	$OUTER kill-server 2>/dev/null
	wait_until sh -c "[ -z \"\$($TMUX list-clients 2>/dev/null)\" ]" ||
	    fail "client never went"
}

# stop: kill-server, as a crash or a reboot ends one (its snapshot stays open).
stop() {
	$OUTER kill-server 2>/dev/null
	$TMUX kill-server
	wait_gone
	sleep 1.1
}

sessions_are() {
	[ "$($TMUX ls -F '#{session_name}' 2>/dev/null | tr -d '\r' | tr '\n' ' ' |
	    sed 's/ $//')" = "$1" ]
}
shows() {
	[ "$($TMUX display -p -c "$CLIENT" '#{client_session}' 2>/dev/null |
	    tr -d '\r')" = "$1" ]
}
said() {
	$TMUX show-messages 2>/dev/null | grep -q -- "$1"
}
done_restoring() {
	[ -z "$($TMUX display -p '#{server_restore}' 2>/dev/null | tr -d '\r')" ]
}
snap_has() { grep -q -- "$2" "$1" 2>/dev/null; }
snap() { echo "$OUT/live/$($TMUX display -p '#{b:socket_path}' | tr -d '\r').set"; }

# 1. A set to come back: two sessions, the client showing the second, not primary.
$TMUX -f "$CONF" new -d -s main -n one "$LONG" || fail "start first server"
$TMUX new-window -d -t main: -n two "$LONG" || fail "new-window two"
$TMUX new -d -s other -n o1 "$LONG" || fail "new session other"
SNAP=$(snap)
PREVIOUS="${SNAP%.set}-previous.set"
attach "attach -t =other"
wait_until snap_has "$SNAP" "^attached${T}other$" || fail "shown session not saved"
wait_until snap_has "$SNAP" "${T}o1${T}\|${T}o1$" || fail "windows not saved"
cp "$SNAP" "$OUT/saved"
stop

# 2. After a restart it comes back with no client there and nothing offered, the
# fresh session gone, and archived.
$TMUX -f "$CONF" new -d -s primary || fail "start after a restart"
wait_until sessions_are "main other" || fail "not restored with no client"
wait_until done_restoring || fail "restore never ended"
said "restoring after a restart" || fail "restore not recorded"
test -f "$PREVIOUS" && fail "restored set still offered"
[ "$(ls "$OUT/archive" | wc -l)" -ge 1 ] || fail "restored set not archived"
wait_until snap_has "$(snap)" "^attached${T}other$" ||
    fail "the session to show not saved"

# 3. A second restart before any client attached still has the set to bring back.
stop
$TMUX -f "$CONF" new -d -s primary || fail "start after a second restart"
wait_until sessions_are "main other" || fail "lost with no client ever attached"
wait_until done_restoring || fail "second restore never ended"

# 4. The first client lands on the session the set showed, with no menu. Opening
# at-terminal creates primary only if it isn't there, so this asks for it the
# way at-terminal does.
attach "new -A -s other"
wait_until shows other || fail "first client not on the saved session"
said "offered as" && fail "offered after a restart"
detach
attach "new -A -s main"
sleep 0.5
shows main || fail "only the first client is moved"

# 5. at-terminal starting the server after a restart comes to the same thing, the
# client there from the start.
$TMUX switch-client -c "$CLIENT" -t =other || fail "show other"
wait_until snap_has "$(snap)" "^attached${T}other$" || fail "other not saved"
stop
$OUTER -f "$OUTER_CONF" new -d -x100 -y30 \
    "& '$EXE' -L$TEST_SOCKET -f '$CONF' new -A -s primary" </dev/null ||
    fail "start outer server"
wait_until attached || fail "client never attached"
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r' | head -1)
wait_until sessions_are "main other" || fail "not restored under a client"
wait_until shows other || fail "client not on the saved session"
wait_until done_restoring || fail "restore under a client never ended"
said "offered as" && fail "offered to a client after a restart"

# 6. A window that can't start is said on the first client, which wasn't there
# when it failed. The set's program comes back through an option that fails.
SNAP=$(snap)
$TMUX new-window -d -t =main: -n bad "$(cygpath -m "$SYSTEMROOT")/System32/PING.EXE" \
    -n 300 127.0.0.1 || fail "new-window bad"
wait_until snap_has "$SNAP" "${T}PING\|${T}ping" || fail "bad's program not saved"
cp "$SNAP" "$OUT/saved-bad"
stop
cat >>"$OUT/test.conf" <<EOF
set -g @session-set-restart-PING "no-such-program.exe argument"
set -g @session-set-restart-ping "no-such-program.exe argument"
EOF
$TMUX -f "$CONF" new -d -s primary || fail "start with a failing window"
wait_until sessions_are "main other" || fail "failure lost the set"
wait_until done_restoring || fail "failing restore never ended"
attach
wait_until drawn "failed: main:" || fail "the failure was never shown"

# 7. Every window failing leaves the fresh session, and the server, where they
# were, and the first client is told.
stop
cp "$OUT/saved-bad" "$SNAP" || fail "put the set back"
cat >>"$OUT/test.conf" <<EOF
set -g @session-set-restart-cmd "no-such-program.exe argument"
EOF
$TMUX -f "$CONF" new -d -s primary || fail "start with every window failing"
wait_until said "restored 0 of" || fail "total failure not recorded"
wait_until done_restoring || fail "total failure never ended"
sessions_are primary || fail "the fresh session didn't stay"
attach
wait_until drawn "restored 0 of" || fail "total failure never shown"
stop
config 4000000000
cp "$OUT/saved" "$SNAP" || fail "put the set back"
$TMUX -f "$CONF" new -d -s primary || fail "start after the failures"
wait_until sessions_are "main other" || fail "set not back after the failures"
wait_until done_restoring || fail "restore after the failures never ended"
attach

# 8. Lost while the PC was up: nothing comes back on its own, and the offer says
# what happened. Enter restores it.
wait_until snap_has "$(snap)" "^attached" || fail "not saved"
config 1
stop
$TMUX -f "$CONF" new -d -s primary || fail "start after a crash"
wait_until test -f "$PREVIOUS" || fail "set not set aside"
sleep 1
sessions_are primary || fail "restored with no offer after a crash"
attach
wait_until drawn "Crash recovery" || fail "offer not titled crash recovery"
drawn "likely a crash" || fail "offer doesn't say likely a crash"
said "offered as crash recovery" || fail "crash offer not recorded"
$TMUX send-keys -K -c "$CLIENT" Enter
wait_until sessions_are "main other" || fail "Enter did not restore"
wait_until done_restoring || fail "Enter's restore never ended"

# 9. After a restart with the new server's session in use, it asks, in the old
# words, rather than replace anything.
wait_until snap_has "$(snap)" "^attached" || fail "not saved"
config 4000000000
stop
$TMUX -f "$CONF" new -d -s busy -n busy "$LONG" || fail "start with a program"
wait_until test -f "$PREVIOUS" || fail "set not set aside"
sleep 1
sessions_are busy || fail "restored beside a session in use"
attach
wait_until drawn "Previous session set" || fail "not offered after a restart"
drawn "likely a crash" && fail "a restart called a crash"
$TMUX send-keys -K -c "$CLIENT" Enter
wait_until sessions_are "busy main other" || fail "Enter did not restore"
wait_until done_restoring || fail "that restore never ended"

# 10. A server that dies in a restore leaves the set, and the next one asks: a
# restore that kills its server never runs again unasked, even after a restart.
cp "$OUT/saved" "$OUT/died.set"
wait_until snap_has "$(snap)" "^attached" || fail "not saved"
SNAP=$(snap)
stop
cp "$OUT/died.set" "$PREVIOUS" || fail "put the set back"
sed "s/^restoring${T}0/restoring${T}1/" "$SNAP" >"$OUT/restoring" &&
    cp "$OUT/restoring" "$SNAP" || fail "mark the snapshot restoring"
$TMUX -f "$CONF" new -d -s primary || fail "start after dying in a restore"
sleep 1
sessions_are primary || fail "restored again after dying in a restore"
attach
wait_until drawn "Crash recovery" || fail "death in a restore not called a crash"
$TMUX send-keys -K -c "$CLIENT" Escape
wait_until sh -c "! test -f '$PREVIOUS'" || fail "Escape did not archive"

# 11. An upgraded server is not a new one: a set still waiting is offered, never
# restored into what is running.
detach
cp "$OUT/died.set" "$PREVIOUS" || fail "put the set back"
before=$($TMUX display -p '#{pid}' | tr -d '\r')
$TMUX upgrade-server "$(cygpath -wa "$TEST_TMUX")" || fail "upgrade-server"
moved() {
	_pid=$($TMUX display -p '#{pid}' 2>/dev/null | tr -d '\r')
	[ -n "$_pid" ] && [ "$_pid" != "$before" ]
}
wait_until moved || fail "server never moved"
attach
wait_until drawn "Previous session set" || fail "upgraded server didn't offer"
sessions_are primary || fail "upgraded server restored with no offer"

exit 0
