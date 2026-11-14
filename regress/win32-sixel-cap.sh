#!/bin/sh

# Each pane keeps its own 20 sixel images, and a pane storing a 21st frees its
# own oldest, never another pane's (TMUX-197). The cap was one for the whole
# server, so a few at-claude windows freed each other's avatars, and a pane
# whose image was freed showed nothing there until it drew those rows again.
# The images a pane's main screen puts aside for the alternate screen stay its
# own, and the alternate screen has a cap of its own.
# What tmux still holds is read from a full redraw of an attached client, which
# draws every image it holds: the client runs in a pane of a second server, as
# in win32-sixel.sh, and what it sent its terminal is read from tmux's -vv
# output log. Each image is told apart by its colour.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TEST_TMUX=$(cd "$(dirname "$TEST_TMUX")" && pwd)/$(basename "$TEST_TMUX")
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
$OUTER kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
# The server's own logs stay open until it has gone.
remove() { rm -rf "$OUT" 2>/dev/null; [ ! -e "$OUT" ]; }
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; cd /; wait_until remove' 0 1 15
cd "$OUT" || exit 1

cat >test.conf <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
# The outer server stands in for Windows Terminal, whose TERM is xterm-256color.
set -g default-terminal xterm-256color
set -g status off
set -g window-size manual
set -as terminal-features ',xterm-256color:sixel'
EOF

# A pane's program: Draw N R G B draws image N, a pixel of colour R, G, B (out
# of 100), at the start of row N; Await NAME waits for the test to make the
# file NAME. The double quote is [char]34: the pane's command line loses a
# literal one.
DIR=$(cygpath -m "$OUT")
PROGRAM="\$e = [string][char]27; \$q = [string][char]34; "\
"function Draw(\$n, \$r, \$g, \$b) { [Console]::Write(\$e + '[' + \$n + ';1H' + \$e + 'Pq' + \$q + '1;1;1;6#1;2;' + \$r + ';' + \$g + ';' + \$b + '#1~' + \$e + '\\') }; "\
"function Await(\$f) { while (-not (Test-Path ('$DIR/' + \$f))) { Start-Sleep -Milliseconds 50 } }; "\
"[Console]::Write(\$e + '[H' + \$e + '[2J'); "
ALTERNATE="[Console]::Write(\$e + '[?1049h')"
MAIN="[Console]::Write(\$e + '[?1049l')"

# Pane a draws 20 red images, then a 21st. Pane b draws 20 green ones, then
# turns on the alternate screen and draws 21 blue ones there, then turns it off.
$TMUX -vv -f test.conf new -d -x60 -y30 "$PROGRAM"\
"Await a; foreach (\$n in 1..20) { Draw \$n \$n 0 0 }; "\
"Await a-more; Draw 21 21 0 0; Start-Sleep 120" </dev/null || exit 1
$TMUX splitw -h -t:^.0 "$PROGRAM"\
"Await b; foreach (\$n in 1..20) { Draw \$n 0 \$n 0 }; "\
"Await b-alternate; $ALTERNATE; foreach (\$n in 1..21) { Draw \$n 0 0 \$n }; "\
"Await b-main; $MAIN; Start-Sleep 120" </dev/null || exit 1
$OUTER -f test.conf new -d -x60 -y30 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1

attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }
cell_known() {
	case "$($TMUX list-clients -F '#{client_cell_width}x#{client_cell_height}' | tr -d '\r')" in
	[1-9]*x[1-9]*) return 0 ;;
	esac
	return 1
}
wait_until cell_known || { echo "the client never learned its cell size"; exit 1; }
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')

LOG=$(ls tmux-out-*.log 2>/dev/null | head -1)
[ -n "$LOG" ] || { echo 'no output log'; exit 1; }

# colour SET N: image N of a set (red, green or blue) as its colour register
# reads when the client draws it.
colour() {
	case $1 in
	red) echo "#1;2;$2;0;0#" ;;
	green) echo "#1;2;0;$2;0#" ;;
	blue) echo "#1;2;0;0;$2#" ;;
	esac
}

# sent FROM SET N: from byte FROM of the log, the client drew image N of SET.
sent() {
	tail -c +"$(($1 + 1))" "$LOG" | grep -a -q -F "$(colour "$2" "$3")"
}

# missing FROM SET:FIRST-LAST ...: from byte FROM, the client left out one of
# images FIRST to LAST of a SET.
missing() {
	from=$1
	shift
	for range; do
		set=${range%%:*}
		range=${range#*:}
		for n in $(seq "${range%-*}" "${range#*-}"); do
			sent "$from" "$set" "$n" || return 0
		done
	done
	return 1
}
complete() {
	! missing "$@"
}

# drawn SET:FIRST-LAST ...: from byte FROM, the client draws images FIRST to
# LAST of each SET.
drawn() {
	if ! wait_until complete "$FROM" "$@"; then
		echo "$WHAT: the client left out images tmux should hold:"
		for set in red green blue; do
			for n in $(seq 1 21); do
				sent "$FROM" $set "$n" || echo "  $set $n"
			done
		done
		exit 1
	fi
}

# redraw SET:FIRST-LAST ...: a full redraw of the client draws them, so tmux
# holds them all at once.
redraw() {
	FROM=$(wc -c <"$LOG")
	$TMUX refresh-client -t "$CLIENT" || exit 1
	drawn "$@"
}

# not SET N: the last redraw drew no image N of SET.
not() {
	if sent "$FROM" "$1" "$2"; then
		echo "$WHAT: tmux still holds $1 $2"
		exit 1
	fi
}

# Two panes with 20 images each keep all 40, more than the server held before.
WHAT="two panes of 20"
FROM=0
touch "$OUT/a"
drawn red:20-20
touch "$OUT/b"
drawn green:20-20
redraw red:1-20 green:1-20

# Pane a's 21st frees its own first image and none of pane b's.
WHAT="a pane's 21st"
touch "$OUT/a-more"
drawn red:21-21
redraw red:2-21 green:1-20
not red 1

# The alternate screen's 21st frees its own first image, not one of those the
# main screen put aside, and turning it off brings back the main screen's 20.
WHAT="the alternate screen's 21st"
touch "$OUT/b-alternate"
drawn blue:21-21
redraw red:2-21 blue:2-21
not blue 1
WHAT="leaving the alternate screen"
FROM=$(wc -c <"$LOG")
touch "$OUT/b-main"
drawn green:1-20
redraw red:2-21 green:1-20
not blue 2
not blue 21

echo "ALL SIXEL CAP TESTS PASSED"
exit 0
