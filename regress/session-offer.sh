#!/bin/sh

# The session set after a reboot on Linux: a set saved before this sign-in
# (systemd-logind's session start, else the boot) comes back with no offer, and
# one saved since is offered in a menu that only a click closes, not the mouse
# moving over or off it. The menu's client runs in a pane of a second server.

PATH=/bin:/usr/bin
TERM=screen

[ "$(uname -s)" = Linux ] || { echo "SKIP: Linux only"; exit 0; }
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
unset TMUX TMUX_FLIGHT_SIGNIN
TMUX="$TEST_TMUX -Lssoffer-$$"
OUTER="$TEST_TMUX -Lssouter-$$"
OUT=$(mktemp -d) || exit 1
TMUX_FLIGHT_DIR=$OUT/flight
TMUX_ERROR_LOG_DIR=$OUT/errors
TMUX_EVENT_LOG_DIR=$OUT/events
export TMUX_FLIGHT_DIR TMUX_ERROR_LOG_DIR TMUX_EVENT_LOG_DIR
trap '$TMUX kill-server 2>/dev/null; $OUTER kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15

cat >"$OUT/test.conf" <<EOF
set -g default-shell /bin/sh
set -g status off
set -g mouse on
set -g @session-set-dir '$OUT/dir'
EOF

fail() {
	echo "FAIL: $1"
	$TMUX lsw -a -F '#{session_name}:#{window_index} #{window_name}' 2>&1
	$OUTER capture-pane -p 2>&1
	ls -R "$OUT/dir" 2>&1
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
gone() { ! $TMUX list-sessions >/dev/null 2>&1; }
snap_has() { grep -q "$1" "$SNAP" 2>/dev/null; }
windows_are() {
	[ "$($TMUX lsw -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" = "$1" ]
}
shown() { $OUTER capture-pane -p | grep -q 'Start fresh'; }
mouse() { $OUTER send-keys -l "$(printf '\033[<%s' "$1")"; }

# save: a server with windows one and two, shown on a client (as attached
# names), killed as a reboot would end it. The next server starts a second
# later, since one of the same start time is taken for an upgraded one.
save() {
	$TMUX -f "$OUT/test.conf" new -d -s main -n one 'sleep 300' ||
	    fail 'start the saving server'
	$TMUX new-window -d -t main: -n two 'sleep 300'
	SNAP=$OUT/dir/live/$($TMUX display -p '#{b:socket_path}').set
	PREVIOUS=${SNAP%.set}-previous.set
	wait_for snap_has '	two	' || fail 'the set was not saved'
	$TMUX kill-server
	wait_for gone || fail 'the saving server outlived its kill'
	sed -i 's/^attached	$/attached	main/' "$SNAP"
	sleep 1.1
}

# 1. Saved before this sign-in: a new server rebuilds it, unasked.
save
sed -i 's/^seen	.*/seen	1000/' "$SNAP"
$TMUX -f "$OUT/test.conf" new -d || fail 'start after the reboot'
wait_for windows_are 'one two ' || fail 'a set from before this sign-in was not restored'
wait_for test ! -f "$PREVIOUS" || fail 'the restored set was not archived'

# 2. Saved since: the next server offers it, and the mouse moving leaves the
# menu open, off it and over its items.
$TMUX kill-server
wait_for gone || fail 'the restoring server outlived its kill'
sleep 1.1
$OUTER -f/dev/null new -d -x 100 -y 30 \
    "$TMUX -f '$OUT/test.conf' new" ||
    fail 'start the outer server'
wait_for shown || fail 'a set saved since this sign-in was not offered'
mouse '35;5;5M'
mouse '35;6;5M'
y=$($OUTER capture-pane -p | grep -n 'Restore' | cut -d: -f1)
mouse "35;50;${y}M"
sleep 0.5
shown || fail 'moving the mouse closed the offer'
[ -f "$PREVIOUS" ] || fail 'moving the mouse chose for the offer'

# 3. A click off the menu closes it without a choice.
mouse '0;5;5M'
mouse '0;5;5m'
wait_for eval '! shown' || fail 'a click off the menu left it open'
[ -f "$PREVIOUS" ] || fail 'a click off the menu chose for the offer'

echo PASS
exit 0
