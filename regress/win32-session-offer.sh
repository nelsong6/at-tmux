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
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
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
set -g @session-set-resume '$SYS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "Start-Sleep 300 # resumed {id}"'
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
	    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach" \
	    -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$OUT/resize")" &
	wait_until attached || fail "client never attached"
	CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')
}
attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}

# stop: kill-server, which leaves its snapshot open as a crash or a reboot does.
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
messages_have() {
	$TMUX show-messages 2>/dev/null | tr -d '\r' | grep -q -- "$1"
}
snap() { echo "$OUT/live/$($TMUX display -p '#{b:socket_path}' | tr -d '\r').set"; }
snap_has() { grep -q -- "$2" "$1" 2>/dev/null; }

# 1. A set to come back: three sessions in a row order their names don't sort
# in, one of them moved there by reorder-session, a split window with a Claude pane, zoomed, the second window current
# and the first the one shown before it, shown by a client.
$TMUX -f "$CONF" new -d -s main -n one "$LONG" || fail "start first server"
$TMUX new-window -d -t main: -n two "$LONG" || fail "new-window two"
$TMUX split-window -d -t main:two "$LONG" || fail "split two"
$TMUX new-window -d -t main: -n three "$LONG" || fail "new-window three"
$TMUX set -p -t main:two.1 @claude-session abc123 || fail "set claude"
$TMUX select-pane -t main:two.1
$TMUX select-window -t main:two
$TMUX new -d -s other -n o1 "$LONG" || fail "new session other"
$TMUX new -d -s alpha -n a1 "$LONG" || fail "new session alpha"
$TMUX new -d -s zed -n z1 "$LONG" || fail "new session zed"
$TMUX reorder-session -s zed front || fail "reorder-session"
SNAP=$(snap)
PREVIOUS="${SNAP%.set}-previous.set"
attach
$TMUX switch-client -c "$CLIENT" -t main
sizes() { $TMUX lsp -t "$1" -F '#{pane_width}x#{pane_height}' | tr -d '\r' | tr '\n' ' '; }
layout=$(sizes main:two)
$TMUX resize-pane -Z -t main:two.1 || fail "zoom"
wait_until snap_has "$SNAP" "^attached${T}main$" || fail "shown session not saved"
wait_until snap_has "$SNAP" "${T}abc123${T}" || fail "Claude pane not saved"
row=$($TMUX display -p '#{S:#{session_name} }' | tr -d '\r')
[ "$row" = "zed main other alpha " ] || fail "sessions row not as arranged ($row)"
first=$(sed -n "s/^start${T}//p" "$SNAP" | tr -d '\r')
stop

# 2. The next server sets it aside and offers it; Enter brings it back in
# place of the fresh session, the client on the session it showed.
$TMUX -f "$CONF" new -d -s primary || fail "start second server"
wait_until test -f "$PREVIOUS" || fail "earlier snapshot not set aside"
attach
press_until Enter sessions_are "alpha main other zed" || fail "Enter did not restore"
messages_have "offered after being told to exit" || fail "saved since sign-in, not offered as lost"
windows_are main "one two three" || fail "restored windows differ"
[ "$($TMUX display -p '#{S:#{session_name} }' | tr -d '\r')" = "$row" ] ||
    fail "sessions not back in the sessions row's order"
[ "$($TMUX display -p -t main:two '#{window_panes}' | tr -d '\r')" = 2 ] ||
    fail "restored window lacks its split"
$TMUX display -p -t main:two.1 '#{pane_start_command}' | grep -q 'resumed abc123' ||
    fail "Claude pane not resumed"
[ "$($TMUX display -p -t main:two '#{pane_index}' | tr -d '\r')" = 1 ] ||
    fail "active pane not restored"
[ "$($TMUX display -p -t main: '#{window_name}' | tr -d '\r')" = two ] ||
    fail "current window not restored"
[ "$($TMUX display -p -t main:two '#{window_zoomed_flag}' | tr -d '\r')" = 1 ] ||
    fail "zoomed window not zoomed"
$TMUX resize-pane -Z -t main:two.1 || fail "unzoom"
[ "$(sizes main:two)" = "$layout" ] || fail "zoomed window's layout differs"
$TMUX lsw -t =main -F '#{window_last_flag}#{window_name}' | tr -d '\r' |
    grep -qx 1one || fail "last window not restored"
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
wait_until sessions_are "alpha main other primary zed" ||
    fail "restore-set made no set"
$TMUX restore-set -d "archive/$(basename "${SNAP%.set}")-$first.set" ||
    fail "restore-set again"
wait_until windows_are main-2 "one two three" || fail "taken name not numbered"
$TMUX restore-set -d "$(cygpath -m "$OUT/test.conf")" 2>/dev/null &&
    fail "restore-set took a file that is not a snapshot"

# 6. A set last saved before this sign-in comes back with no client and no
# offer, in place of the fresh session, and the first client lands on the
# session it showed.
cat >"$OUT/reboot.conf" <<EOF
source '$CONF'
set -g @session-set-signin 4102444800
EOF
BASE=$(basename "${SNAP%.set}")
attach
press_until Escape eval '! test -f "$PREVIOUS"' || fail "fifth's offer not closed"
$TMUX switch-client -c "$CLIENT" -t alpha
wait_until snap_has "$SNAP" "^attached${T}alpha$" || fail "alpha not saved"
fifth=$(sed -n "s/^start${T}//p" "$SNAP" | tr -d '\r')
stop
$TMUX -f "$(cygpath -m "$OUT/reboot.conf")" new -d -s primary || fail "start sixth server"
wait_until test -f "$OUT/archive/$BASE-$fifth.set" || fail "not restored unasked"
sessions_are "alpha alpha-2 main main-2 other other-2 primary zed zed-2" || fail "silent restore's sessions"
windows_are main "one two three" || fail "silent restore's windows"
test -f "$PREVIOUS" && fail "restored set still offered"
wait_until snap_has "$SNAP" "^attached${T}alpha$" || fail "shown session not kept"
attach
client_on_alpha() {
	[ "$($TMUX display -p -c "$CLIENT" '#{client_session}' | tr -d '\r')" = alpha ]
}
wait_until client_on_alpha || fail "first client not on the session it showed"
sixth=$(sed -n "s/^start${T}//p" "$SNAP" | tr -d '\r')
stop

# 7. A restore that can't finish (here a saved size with no room for a window's
# second pane) leaves the fresh session and the set, and the next server offers
# it rather than running it again.
sed -i "s/^window${T}\([0-9]*\)${T}[0-9]*${T}[0-9]*${T}/window${T}\1${T}3${T}1${T}/" "$SNAP"
$TMUX -f "$(cygpath -m "$OUT/reboot.conf")" new -d -s primary || fail "start seventh server"
wait_until messages_have "restore after a reboot failed" || fail "failure not recorded"
wait_until sessions_are primary || fail "fresh session not back"
snap_has "$PREVIOUS" "^start${T}$sixth$" || fail "failed restore lost its set"
stop
$TMUX -f "$(cygpath -m "$OUT/reboot.conf")" new -d -s primary || fail "start eighth server"
attach
wait_until messages_have "offered as the previous set" || fail "set not offered"
sessions_are primary || fail "restore ran again unasked"
press_until Escape eval '! test -f "$PREVIOUS"' || fail "offer not closed"

# 8. A program that can't start doesn't cost a restore after a reboot: the set
# comes back with a shell in its place, and says so.
cp "$SYSTEMROOT/System32/PING.EXE" "$OUT/gone.exe"
$TMUX new-window -d -t primary: -n gone "$(cygpath -w "$OUT/gone.exe")" -n 300 127.0.0.1 ||
    fail "gone window"
wait_until snap_has "$SNAP" "${T}gone${T}" || fail "gone not saved"
eighth=$(sed -n "s/^start${T}//p" "$SNAP" | tr -d '\r')
stop
rm -f "$OUT/gone.exe"
$TMUX -f "$(cygpath -m "$OUT/reboot.conf")" new -d -s primary || fail "start ninth server"
wait_until test -f "$OUT/archive/$BASE-$eighth.set" || fail "a lost program stopped the restore"
wait_until messages_have "a shell in place of: primary.* (gone), can't start" ||
    fail "the lost program isn't reported"
[ -z "$($TMUX display -p -t =primary:gone '#{pane_start_command}' | tr -d '\r')" ] ||
    fail "the lost program's window isn't a shell"

exit 0
