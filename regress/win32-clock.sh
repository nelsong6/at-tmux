#!/bin/sh

# Clock mode draws in every clock-mode-style and the server keeps running. The
# 12-hour styles pad the hour with a space and take AM or PM from the 24-hour
# hour, checked where that can go wrong: 12 AM, 12 PM, and a one-digit hour on
# either side. Before TMUX-43 they used %l, on which the C runtime on Windows
# ends the process.
# capture-pane can't read clock mode, so the client runs in a pane of a second
# server, whose copy shows what it drew.

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

CFG="$OUT/clock.conf"
cat >"$CFG" <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
set -g status off
EOF

fail() {
	echo "FAIL: $label: $1"
	exit 1
}

# zone HOUR: a TZ value that makes it half past HOUR now, so the test can't
# cross an hour however slowly it runs. TZ is the minutes west of UTC, as
# hours and minutes.
zone() {
	_west=$(($(date -u +%s) / 60 % 1440 - $1 * 60 - 30))
	[ $_west -gt 720 ] && _west=$((_west - 1440))
	[ $_west -lt -720 ] && _west=$((_west + 1440))
	_sign=+
	[ $_west -lt 0 ] && { _sign=-; _west=$((-_west)); }
	printf 'CLK%s%d:%02d' $_sign $((_west / 60)) $((_west % 60))
}

attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}

# alive: the server hasn't ended, which is how a style failed before TMUX-43.
alive() {
	$TMUX has-session 2>/dev/null || fail "server ended"
}

# text: the row a window under 6 rows high shows the time on, as text.
text() {
	$OUTER capture-pane -p 2>/dev/null | tr -d '\r' | sed -n 2p |
	    sed 's/ *$//'
}
text_is() {
	alive
	text | grep -qx -- "$1"
}

# text_style STYLE PATTERN: in STYLE the clock draws the row matching PATTERN,
# its leading blanks counted, which is where the padding shows. The clock
# redraws each second.
text_style() {
	$TMUX set -g clock-mode-style "$1" || fail "set $1"
	wait_until text_is "$2" || fail "$1 drew '$(text)', expected '$2'"
}

# large_column: the leftmost column of the large digits, the blanks before the
# first coloured cell of any row.
large_column() {
	$OUTER capture-pane -p -e 2>/dev/null | tr -d '\r' |
	    grep "$(printf '\033')\[4" |
	    sed "s/$(printf '\033').*//" | awk '{
		if (min == "" || length($0) < min)
			min = length($0)
	    } END { print min }'
}
large_is() {
	alive
	[ "$(large_column)" = "$1" ]
}

# large_style STYLE COLUMN: in STYLE the large digits start at COLUMN.
large_style() {
	$TMUX set -g clock-mode-style "$1" || fail "set $1"
	wait_until large_is "$2" ||
	    fail "$1 drew from column '$(large_column)', expected $2"
}

# hour HOUR HOUR12 SUFFIX HOUR24 FIRST: a server where it is half past HOUR.
# Text rows are centred, so each style's leading blanks are fixed: 4 for the 8
# characters of the 12-hour style (the padded hour is the fifth), 3 for 11
# with seconds, 6 for 5 and 4 for 8 in 24-hour styles. In a window 70 wide the
# 8 characters start at column 11 and the 11 at column 2, and the digits start
# at FIRST further on: past a blank first character, or inside a 1.
hour() {
	label="$1:30"
	TZ=$(zone "$1") $TMUX -f "$CFG" new -d -s clock -x16 -y3 </dev/null ||
	    fail "new-session"
	$OUTER -f "$CFG" new -d -x16 -y3 \
	    "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" </dev/null ||
	    fail "outer new-session"
	wait_until attached || fail "client never attached"

	$TMUX clock-mode -t clock
	text_style 12 "    $2:3[0-9] $3"
	text_style 12-with-seconds "   $2:3[0-9]:[0-9][0-9] $3"
	text_style 24 "      $4:3[0-9]"
	text_style 24-with-seconds "    $4:3[0-9]:[0-9][0-9]"

	$OUTER resize-window -x70 -y8 || fail "resize"
	large_style 12 $((11 + $5))
	large_style 12-with-seconds $((2 + $5))

	$OUTER kill-server 2>/dev/null
	$TMUX kill-server 2>/dev/null
	wait_gone
}

hour 0 12 AM 00 4
hour 9 ' 9' AM 09 6
hour 12 12 PM 12 4
hour 15 ' 3' PM 15 6

echo "ALL CLOCK TESTS PASSED"
exit 0
