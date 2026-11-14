#!/bin/sh

# Setting a user option, or an option only the status line, borders and title
# read, redraws what shows it and leaves pane contents alone (TMUX-198): until
# then every set-option redrew each client in full, clearing every pane row and
# sending every sixel image again, and Claude's hooks set @claude on every tool
# call, so images flashed. Each place a user option can show still updates: the
# status line, a border's status line, border styles, a pane footer and its
# condition, the terminal title. A pane is redrawn only when window-style now
# gives it other colours. The client runs in a pane of a second server, which
# stands in for Windows Terminal; what it sent its terminal is read from tmux's
# -vv output log, and what it drew from the outer pane.

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

# The outer server answers device attributes as a VT100, so the inner client is
# given sixel and titles by hand. Every surface reads @probe; window-style does
# too, and gives a blue background only for "blue".
cat >outer.conf <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
# The outer server stands in for Windows Terminal, whose TERM is xterm-256color.
set -g default-terminal xterm-256color
set -g status off
set -g window-size manual
EOF
cat >test.conf <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
set -as terminal-features ',xterm-256color:sixel:title'
set -g status-left ''
set -g status-right 'S:#{@probe}:#{@claude}'
set -g set-titles on
set -g set-titles-string 'T:#{@probe}'
set -g pane-border-status top
set -g pane-border-format 'B:#{@probe}'
set -g pane-border-style '#{?#{==:#{@probe},two},fg=red,fg=green}'
set -g pane-active-border-style '#{?#{==:#{@probe},two},fg=red,fg=green}'
set -g pane-footer 'F#{pane_index}:#{@probe}'
set -g pane-footer-condition 1
set -g window-style '#{?#{==:#{@probe},blue},bg=blue,default}'
EOF

# A red block 20 pixels wide and 12 high, on a cleared screen. The double quote
# is [char]34: the pane's command line loses a literal one.
E='[string][char]27'
Q='[string][char]34'
PRINT="[Console]::Write($E + '[H' + $E + '[2J' + $E + 'Pq' + $Q + '1;1;20;12#1;2;100;0;0#1!20~-!20~' + $E + '\\' + 'AFTER-IMAGE')"
$TMUX -vv -f test.conf new -d -x60 -y16 \
    "while (-not (Test-Path '$(cygpath -m "$OUT/go")')) { Start-Sleep -Milliseconds 50 }; $PRINT; Start-Sleep 120" \
    </dev/null || exit 1
LEFT=$($TMUX list-panes -F '#{pane_id}' | tr -d '\r')
RIGHT=$($TMUX split-window -h -d -P -F '#{pane_id}' "Start-Sleep 120" | tr -d '\r')
[ -n "$RIGHT" ] || { echo "split-window failed"; exit 1; }
# The right pane's footer comes and goes with a user option, as the strip's does.
$TMUX set -p -t "$RIGHT" pane-footer-condition '#{@footer-on}' || exit 1
$OUTER -f outer.conf new -d -x60 -y16 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
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

LOG=$(ls tmux-out-*.log 2>/dev/null | head -1)
[ -n "$LOG" ] || { echo 'no output log'; exit 1; }
ESC=$(printf '\033')

# sent FROM: what the client sent its terminal from byte FROM of the log.
sent() {
	tail -c +"$(($1 + 1))" "$LOG" >sent.txt
}
# shown TEXT...: the outer pane, what the client drew, holds every TEXT.
shown() {
	$OUTER capture-pane -p >shown.txt 2>/dev/null || return 1
	for _text in "$@"; do
		grep -q -F -- "$_text" shown.txt || return 1
	done
}
# changed WHAT TEXT...: after setting something, the client drew every TEXT.
changed() {
	_what=$1
	shift
	if ! wait_until shown "$@"; then
		echo "$_what: the client never drew $*"
		cat shown.txt
		exit 1
	fi
	sent "$before"
}
# erased: each erase the client sent (ED, EL or ECH) as the row of the cursor
# move before it, the screen's 1-based row; tmux moves the cursor by CUP.
erased() {
	awk 'BEGIN { RS = "\033\\[" }
	NR > 1 && match($0, /^[0-9]*(;[0-9]*)?H/) {
		split(substr($0, 1, RLENGTH - 1), a, ";")
		row = (a[1] == "") ? 1 : a[1]
	}
	NR > 1 && match($0, /^[0-9]*J/) { print "screen"; next }
	NR > 1 && match($0, /^[0-9]*[KX]/) { print row }' sent.txt
}
# pane_kept WHAT: the client sent nothing of the left pane: not its text, not
# its image, no erase in its rows and no erase of the screen.
pane_kept() {
	if grep -a -q AFTER-IMAGE sent.txt; then
		echo "$1: the pane's text was sent again"
		exit 1
	fi
	if grep -a -q "${ESC}P0;[0-9]*q" sent.txt; then
		echo "$1: the pane's image was sent again"
		exit 1
	fi
	for _row in $(erased); do
		if [ "$_row" = screen ] ||
		    { [ "$_row" -ge "$TOP" ] && [ "$_row" -le "$BOTTOM" ]; }; then
			echo "$1: the client erased in the pane (row $_row)"
			cat -v sent.txt
			exit 1
		fi
	done
}

# The first draw: the image as a sixel, and every surface with no @probe.
before=0
touch "$OUT/go"
changed "first draw" AFTER-IMAGE 'S::' 'F0:' 'B:'
grep -a -q "${ESC}P0;[0-9]*q" sent.txt || { echo "first draw: no sixel image"; exit 1; }
# The left pane's rows on the client's screen, below a status line at the top.
set -- $($TMUX display -p -t "$LEFT" \
    '#{pane_top} #{pane_bottom} #{?#{==:#{status-position},top},1,0}' | tr -d '\r')
TOP=$(($1 + 1 + $3))
BOTTOM=$(($2 + 1 + $3))

# A user option: the status line, the border status lines, the footer and the
# title update; the pane is not touched.
before=$(wc -c <"$LOG")
$TMUX set -g @probe one || exit 1
changed "@probe one" 'S:one:' 'B:one' 'F0:one' AFTER-IMAGE
pane_kept "@probe one"
wait_until grep -a -q 'T:one' "$LOG" || { echo "@probe one: the title was not set"; exit 1; }

# Border styles that are formats are drawn again with the new value.
before=$(wc -c <"$LOG")
$TMUX set -g @probe two || exit 1
changed "@probe two" 'S:two:' 'B:two' 'F0:two'
grep -a -q "${ESC}\[31m" sent.txt || { echo "@probe two: the borders were not drawn red"; exit 1; }
pane_kept "@probe two"

# set-window-status, which Claude's hooks run, is a user option too.
before=$(wc -c <"$LOG")
$TMUX set-window-status working || exit 1
changed "set-window-status" 'S:two:working'
pane_kept "set-window-status"

# An option only the status line reads.
before=$(wc -c <"$LOG")
$TMUX set -g status-right 'R:#{@probe}:#{@other}' || exit 1
changed "status-right" 'R:two:'
pane_kept "status-right"

# window-style is a format reading user options, but it gives the same colours.
before=$(wc -c <"$LOG")
$TMUX set -g @other x || exit 1
changed "@other x" 'R:two:x'
pane_kept "@other x"

# Now it gives a blue background: the pane is drawn again, image and all.
before=$(wc -c <"$LOG")
$TMUX set -g @probe blue || exit 1
changed "@probe blue" 'R:blue:x' AFTER-IMAGE
wait_until eval 'sent "$before"; grep -a -q "${ESC}P0;[0-9]*q" sent.txt' ||
    { echo "@probe blue: the pane was not drawn again with its image"; exit 1; }
grep -a -q "${ESC}\[44m" sent.txt || { echo "@probe blue: no blue background"; exit 1; }

# A footer whose condition reads a user option appears.
$TMUX set -p -t "$RIGHT" @footer-on 1 || exit 1
before=0
changed "@footer-on" 'F1:blue'

echo "ALL OPTION REDRAW TESTS PASSED"
exit 0
