#!/bin/sh

# The window bar shows every window while they all fit, and only the current
# one, with no trim markers, once they don't; toggle-single-window shows only
# the current one however many fit, and every one again (TMUX-202). The client
# runs in a pane of a second server, whose copy shows the status row it drew.

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

SHELL_CFG="set -g default-shell '$(cygpath -w "$SYSTEMROOT")\\System32\\cmd.exe'"
CFG="$OUT/single.conf"
printf '%s\nset -g status-position top\n' "$SHELL_CFG" >"$CFG"
OUTER_CFG="$OUT/outer.conf"
printf '%s\nset -g status off\n' "$SHELL_CFG" >"$OUTER_CFG"

$TMUX -f "$CFG" new -d -x40 -y10 -n one </dev/null || exit 1
$TMUX neww -d -n two || exit 1
$TMUX neww -n three || exit 1
$OUTER -f "$OUTER_CFG" new -d -x40 -y10 \
    "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach" </dev/null ||
    exit 1

attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }

status_row() {
	$OUTER capture-pane -p 2>/dev/null | tr -d '\r' | head -1
}
# The status row holds every word given, and none prefixed by "-".
ROW=
row_is() {
	ROW=$(status_row)
	for word in "$@"; do
		case "$word" in
		-*)	case "$ROW" in *"${word#-}"*) return 1;; esac;;
		*)	case "$ROW" in *"$word"*) ;; *) return 1;; esac;;
		esac
	done
}
expect_row() {
	label=$1
	shift
	wait_until row_is "$@" || { echo "$label: status row was '$ROW'"; exit 1; }
}

expect_row "fitting windows" one two '[three]' -◀ -▶

# Long names no longer fit 40 columns: only the current window is drawn.
$TMUX neww -d -n alpha-long-name || exit 1
$TMUX neww -d -n beta-long-name || exit 1
$TMUX neww -n gamma-long-name || exit 1
expect_row "overflowing windows" '[gamma-long-name]' -one -two -alpha -beta -◀ -▶

# The one window shown follows the current window.
$TMUX selectw -t :=two || exit 1
expect_row "overflowing after select" '[two]' -one -gamma -alpha -◀ -▶

# Back to windows that fit: every one again.
$TMUX killw -t :=alpha-long-name || exit 1
$TMUX killw -t :=beta-long-name || exit 1
$TMUX killw -t :=gamma-long-name || exit 1
expect_row "fitting again" one '[two]' three

# Single window mode shows only the current window although all fit.
$TMUX toggle-single-window || exit 1
[ "$($TMUX show -gv status-single-window | tr -d '\r')" = on ] ||
    { echo "toggle-single-window did not turn the option on"; exit 1; }
expect_row "single window" '[two]' -one -three
$TMUX selectw -t :=three || exit 1
expect_row "single window after select" '[three]' -one -two

$TMUX toggle-single-window || exit 1
[ "$($TMUX show -gv status-single-window | tr -d '\r')" = off ] ||
    { echo "toggle-single-window did not turn the option off"; exit 1; }
expect_row "every window" one two '[three]'

$OUTER kill-server 2>/dev/null
$TMUX kill-server 2>/dev/null

echo "ALL SINGLE WINDOW TESTS PASSED"
exit 0
