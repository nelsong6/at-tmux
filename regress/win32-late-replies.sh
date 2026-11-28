#!/bin/sh

# A terminal reply that comes after the one the client used is dropped, never
# typed into the pane (TMUX-258). Over SSH to a Windows PC, the pseudo-console
# there could send what the client wrote as it started twice, so the terminal
# answered the pixel size (CSI 14 t) and version (XTVERSION) queries twice, and
# the second answers landed in the pane as keys: at-claude's message box got
# "|tmux 3.6a-win32". The client runs in a pane of a second server, which
# answers it as its terminal; the second answers are sent through that pane
# once the first have been read, followed by a word typed after them, and the
# pane's program records every key it gets.

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
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; wait; rm -rf "$OUT"' 0 1 15
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=1
}

# escape-time is long so a reply split across reads is still one sequence:
# what is tested is what a whole reply does, not how long tmux waits for one.
CFG="$OUT/test.conf"
cat >"$CFG" <<EOF
set -g default-shell "$(cygpath -m "$POWERSHELL_EXE")"
set -g status off
set -s escape-time 2000
# The outer server stands in for Windows Terminal, whose TERM is xterm-256color.
set -g default-terminal xterm-256color
EOF

# The pane's program writes the code of each key it reads, so nothing a
# console or shell does with a key (an Escape clearing the line) hides one.
KEYS="$OUT/keys.txt"
cat >"$OUT/keys.ps1" <<EOF
while (\$true) {
	\$k = [Console]::ReadKey(\$true)
	[IO.File]::AppendAllText('$(cygpath -w "$KEYS")', [string][int]\$k.KeyChar + ' ')
}
EOF
$TMUX -f "$CFG" new -d -x80 -y24 \
    "& '$(cygpath -m "$POWERSHELL_EXE")' -NoProfile -ExecutionPolicy Bypass -File '$(cygpath -m "$OUT/keys.ps1")'" \
    </dev/null || exit 1
$OUTER -f "$CFG" new -d -x80 -y24 -e TERM=xterm-256color \
    "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" </dev/null || exit 1

client_has() {
	[ -n "$($TMUX list-clients -F "$1" 2>/dev/null | tr -d '\r')" ]
}
attached() {
	client_has '#{client_name}'
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }

# The first answers have been read: the version (XTVERSION) as the terminal's
# type and the pixel size as a cell size.
answered() {
	client_has '#{?client_termtype,1,}' &&
	    case "$(cell)" in [1-9]*x[1-9]*) ;; *) return 1 ;; esac
}
cell() {
	$TMUX list-clients -F '#{client_cell_width}x#{client_cell_height}' | tr -d '\r'
}
term() {
	$TMUX list-clients -F '#{client_termtype}|#{client_termfeatures}' | tr -d '\r'
}
WAIT_TIMEOUT=20 wait_until answered ||
    { echo "the terminal never answered: $(term) $(cell)"; exit 1; }
CELL=$(cell)
TERMINAL=$(term)

# The second answers, then the word: the pixel size and the version, each of
# another value than the first, and the primary and secondary device
# attributes. Nothing shows whether the console host has passed the first
# device attributes on yet, so the answers go twice: if the first of them is
# taken as the answer, the second is late. They name no features, so taking
# one changes nothing the client shows.
hex() {
	printf '%s' "$1" | od -An -tx1 | tr -s ' \n' '  '
}
E=$(printf '\033')
LATE="$E[4;990;1990t$E""P>|late-terminal 9.9$E\\$E[?1;2c$E[>1;99;0c"
# shellcheck disable=SC2046
$OUTER send-keys -H $(hex "$LATE$LATE")
$OUTER send-keys -l MARK

# 77 65 82 75 is MARK.
marked() {
	grep -q '77 65 82 75 $' "$KEYS" 2>/dev/null
}
wait_until marked || { echo "the word typed after the answers never arrived: $(cat "$KEYS" 2>/dev/null)"; exit 1; }

got=$(cat "$KEYS")
if [ "$got" = "77 65 82 75 " ]; then
	echo "PASS: the second answers reach the pane as no keys"
else
	fail "the pane got keys $got before MARK"
fi
if [ "$(cell)" = "$CELL" ]; then
	echo "PASS: the client keeps the cell size of the first answer"
else
	fail "the cell was $CELL, now $(cell)"
fi
if [ "$(term)" = "$TERMINAL" ]; then
	echo "PASS: the client keeps the terminal type and features of the first answers"
else
	fail "was $TERMINAL, now $(term)"
fi

exit $FAIL
