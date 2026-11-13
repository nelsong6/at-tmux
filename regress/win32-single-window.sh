#!/bin/sh

# The window bar shows every window while they all fit, and once they don't,
# the current one with the window either side, or the current one alone if
# those don't fit either; toggle-single-window shows only the current one
# however many fit, and every one again (TMUX-202). Whenever windows are left
# out, the number before is on the left (◀ N) and the number after on the
# right (N ▶), and a side with none has neither (TMUX-205). The client runs in
# a pane of a second server, whose copy shows the status row it drew.

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
printf '%s\nset -g status-position top\nset -g status-right ""\n' "$SHELL_CFG" >"$CFG"
OUTER_CFG="$OUT/outer.conf"
printf '%s\nset -g status off\n' "$SHELL_CFG" >"$OUTER_CFG"

$TMUX -f "$CFG" new -d -x60 -y10 -n one </dev/null || exit 1
$TMUX neww -d -n two || exit 1
$TMUX neww -n three || exit 1
$OUTER -f "$OUTER_CFG" new -d -x60 -y10 \
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

# Long names no longer fit 60 columns: the current window and its neighbours
# are drawn, the last window with nothing on its right.
$TMUX neww -d -n alpha-long-name || exit 1
$TMUX neww -d -n beta-long-name || exit 1
$TMUX neww -n gamma-long-name || exit 1
expect_row "overflowing windows" '◀ 4  beta-long-name •[gamma-long-name]' \
    -one -two -alpha -▶

# The windows shown follow the current window.
$TMUX selectw -t :=alpha-long-name || exit 1
expect_row "overflowing after select" '◀ 2  three •[alpha-long-name]• beta-long-name  1 ▶' \
    -one -two -gamma

# The first window has nothing on its left, and its neighbour is shown.
$TMUX selectw -t :=one || exit 1
expect_row "overflowing at the first" '[one]• two  4 ▶' -◀ -three

# With a neighbour too long to fit beside it, the current window is drawn alone.
$TMUX neww -d -n delta-a-name-far-too-long-to-sit-beside || exit 1
$TMUX selectw -t :=gamma-long-name || exit 1
expect_row "neighbours too wide" '◀ 5 [gamma-long-name] 1 ▶' -beta -delta
$TMUX killw -t :=delta-a-name-far-too-long-to-sit-beside || exit 1
$TMUX selectw -t :=two || exit 1

# Back to windows that fit: every one again.
$TMUX killw -t :=alpha-long-name || exit 1
$TMUX killw -t :=beta-long-name || exit 1
$TMUX killw -t :=gamma-long-name || exit 1
expect_row "fitting again" one '[two]' three -◀ -▶

# Single window mode shows only the current window although all fit.
$TMUX toggle-single-window || exit 1
[ "$($TMUX show -gv status-single-window | tr -d '\r')" = on ] ||
    { echo "toggle-single-window did not turn the option on"; exit 1; }
expect_row "single window" '◀ 1 [two] 1 ▶' -one -three
$TMUX selectw -t :=three || exit 1
expect_row "single window after select" '◀ 2 [three]' -▶ -one -two

$TMUX toggle-single-window || exit 1
[ "$($TMUX show -gv status-single-window | tr -d '\r')" = off ] ||
    { echo "toggle-single-window did not turn the option off"; exit 1; }
expect_row "every window" one two '[three]' -◀ -▶

$OUTER kill-server 2>/dev/null
$TMUX kill-server 2>/dev/null

echo "ALL SINGLE WINDOW TESTS PASSED"
exit 0
