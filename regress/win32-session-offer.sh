#!/bin/sh

# The session set's offer and restore: a server that finds the snapshot an
# earlier server of its name left offers it in a menu on the first client to
# attach; Enter rebuilds it in place of the fresh session, Escape archives it,
# and a server no client ever showed is skipped. restore-set rebuilds an
# archived snapshot beside the server's sessions. Clients run in a
# pseudo-console, as in Windows Terminal, and keys reach them with send-keys -K.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap "$TMUX kill-server 2>/dev/null; rm -rf $OUT" 0 1 15
T=$(printf '\t')

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
SYS=$(cygpath -w "$SYSTEMROOT")
LONG="$SYS\System32\PING.EXE -n 300 127.0.0.1 >nul"
cat >"$OUT/test.conf" <<EOF
set -g default-shell '$COMSPEC'
set -g status off
set -g @session-set-dir '$(cygpath -m "$OUT")'
set -g @session-set-resume '$LONG & rem resumed {id}'
EOF
CONF=$(cygpath -m "$OUT/test.conf")

fail() {
	echo "FAIL: $1"
	$TMUX ls 2>&1
	$TMUX lsw -a -F '#{session_name}:#{window_index} #{window_name} #{window_panes}' 2>&1
	ls -R "$OUT" 2>&1
	cat "$OUT"/live/*.set 2>&1
	exit 1
}

# attach: a client in a pseudo-console, as Windows Terminal runs one.
attach() {
	"$PS" -NoProfile -ExecutionPolicy Bypass \
	    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" \
	    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -Ltest attach" \
	    -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$OUT/resize")" &
	wait_until attached || fail "client never attached"
	CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
}
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}

# stop: kill-server, as a crash or a reboot ends one (its snapshot stays open).
stop() {
	$TMUX kill-server
	wait_gone
	sleep 1.1
}

# press KEY until CHECK holds: the menu draws on the client a moment after it
# attaches, and a key before that goes to the pane, where it does nothing.
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
windows_are() {
	[ "$($TMUX lsw -t"=$1" -F '#{window_name}' 2>/dev/null | tr -d '\r' |
	    tr '\n' ' ' | sed 's/ $//')" = "$2" ]
}
snap() { echo "$OUT/live/$($TMUX display -p '#{b:socket_path}' | tr -d '\r').set"; }
snap_has() { grep -q -- "$2" "$1" 2>/dev/null; }

# 1. A set to come back: two sessions, a split window with a Claude pane, the
# second window current, shown by a client.
$TMUX -f "$CONF" new -d -s main -n one "$LONG" || fail "start first server"
$TMUX new-window -d -t main: -n two "$LONG" || fail "new-window two"
$TMUX split-window -d -t main:two "$LONG" || fail "split two"
$TMUX set -p -t main:two.1 @claude-session abc123 || fail "set claude"
$TMUX select-pane -t main:two.1
$TMUX select-window -t main:two
$TMUX new -d -s other -n o1 "$LONG" || fail "new session other"
SNAP=$(snap)
PREVIOUS="${SNAP%.set}-previous.set"
attach
$TMUX switch-client -c "$CLIENT" -t main
wait_until snap_has "$SNAP" "^attached${T}main$" || fail "shown session not saved"
wait_until snap_has "$SNAP" "${T}abc123${T}" || fail "Claude pane not saved"
first=$(sed -n "s/^start${T}//p" "$SNAP" | tr -d '\r')
stop

# 2. The next server sets it aside and offers it; Enter brings it back in
# place of the fresh session, the client on the session it showed.
$TMUX -f "$CONF" new -d -s primary || fail "start second server"
wait_until test -f "$PREVIOUS" || fail "earlier snapshot not set aside"
attach
press_until Enter sessions_are "main other" || fail "Enter did not restore"
windows_are main "one two" || fail "restored windows differ"
[ "$($TMUX display -p -t main:two '#{window_panes}' | tr -d '\r')" = 2 ] ||
    fail "restored window lacks its split"
$TMUX display -p -t main:two.1 '#{pane_start_command}' | grep -q 'resumed abc123' ||
    fail "Claude pane not resumed"
[ "$($TMUX display -p -t main:two '#{pane_index}' | tr -d '\r')" = 1 ] ||
    fail "active pane not restored"
[ "$($TMUX display -p -t main: '#{window_name}' | tr -d '\r')" = two ] ||
    fail "current window not restored"
[ "$($TMUX display -p -c "$CLIENT" '#{client_session}' | tr -d '\r')" = main ] ||
    fail "client not shown the session it showed"
test -f "$PREVIOUS" && fail "restored set still offered"
test -f "$OUT/archive/$(basename "${SNAP%.set}")-$first.set" ||
    fail "restored set not archived"
second=$(sed -n "s/^start${T}//p" "$SNAP" | tr -d '\r')
stop

# 3. Escape archives the set and keeps the fresh session.
$TMUX -f "$CONF" new -d -s primary || fail "start third server"
attach
press_until Escape eval '! test -f "$PREVIOUS"' || fail "Escape did not archive"
sessions_are primary || fail "Escape changed the sessions"
test -f "$OUT/archive/$(basename "${SNAP%.set}")-$second.set" ||
    fail "set not archived on Escape"
third=$(sed -n "s/^start${T}//p" "$SNAP" | tr -d '\r')
wait_until snap_has "$SNAP" "^attached${T}primary$" || fail "third not shown"
stop

# 4. A server no client showed (started at logon, gone before the terminal
# opened) is archived, and the set before it is still the one offered.
$TMUX -f "$CONF" new -d -s primary || fail "start fourth server"
wait_until test -f "$PREVIOUS" || fail "third server's set not set aside"
stop
$TMUX -f "$CONF" new -d -s primary || fail "start fifth server"
wait_until snap_has "$(snap)" "${T}primary${T}" || fail "fifth not saved"
snap_has "$PREVIOUS" "^start${T}$third$" ||
    fail "set a client showed replaced by one none did"

# 5. restore-set rebuilds an archived snapshot beside the sessions there, a
# name already taken getting -2, and keeps it archived.
$TMUX restore-set -d "archive/$(basename "${SNAP%.set}")-$first.set" ||
    fail "restore-set"
wait_until sessions_are "main other primary" || fail "restore-set made no set"
$TMUX restore-set -d "archive/$(basename "${SNAP%.set}")-$first.set" ||
    fail "restore-set again"
wait_until windows_are main-2 "one two" || fail "taken name not numbered"
$TMUX restore-set -d "$(cygpath -m "$OUT/test.conf")" 2>/dev/null &&
    fail "restore-set took a file that is not a snapshot"

exit 0
