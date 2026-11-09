#!/bin/sh

# pane-hidden-text draws as blanks the first of its texts a row starts with,
# after any spaces, and nothing else: not the same text later in a row, and
# not the row's other text. A change to a row that had hidden text redraws it
# whole, so a row that no longer matches shows every cell (the ones the
# program left alone too), and one that matches again hides it. capture-pane
# still reads the text, and unsetting the option shows it (TMUX-183). The
# client runs in a pane of a second server, whose copy shows what it drew.

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

DOT=$(printf '\302\267')
CFG="$OUT/hidden.conf"
cat >"$CFG" <<EOF
set -g default-shell "$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
set -g status off
EOF
INNER_CFG="$OUT/inner.conf"
cat "$CFG" >"$INNER_CFG"
cat >>"$INNER_CFG" <<EOF
set -g pane-hidden-text[0] 'mode on $DOT '
set -g pane-hidden-text[1] 'mode on'
EOF

# Each step waits for its file, so it is drawn while the client is attached.
# Two spaces are written as (' ' * 2): the command line made one of them.
D=$(cygpath -m "$OUT")
STEP="function step(\$n) { while (-not (Test-Path \"$D/\$n\")) { Start-Sleep -Milliseconds 50 } }"
PROGRAM="[Console]::OutputEncoding = [Text.Encoding]::UTF8; \$e = [string][char]27; \$d = [char]0xB7; $STEP; \
step go1; [Console]::Write(\$e + '[H' + \$e + '[2J' + (' ' * 2) + 'mode on ' + \$d + ' esc ' + \$d + ' agents' + [char]13 + [char]10 + (' ' * 2) + 'mode on' + [char]13 + [char]10 + 'say mode on'); \
step go2; [Console]::Write(\$e + '[1;3HM'); \
step go3; [Console]::Write(\$e + '[1;3Hm'); \
Start-Sleep 60"

$TMUX -f "$INNER_CFG" new -d -x40 -y10 "$PROGRAM" </dev/null || exit 1
$OUTER -f "$CFG" new -d -x40 -y10 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1

attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }

rows() {
	$1 capture-pane -p 2>/dev/null | tr -d '\r' | head -3
}
FAILED=0
# check NAME SERVER EXPECTED: the server's pane shows EXPECTED in its first rows.
check() {
	_expected=$3
	_matches() {
		[ "$(rows "$2")" = "$_expected" ]
	}
	if wait_until _matches "$1" "$2"; then
		echo "PASS: $1"
	else
		echo "FAIL: $1; expected:"
		echo "$_expected"
		echo "drew:"
		rows "$2"
		FAILED=1
	fi
}

FULL="$(printf '  mode on %s esc %s agents\n  mode on\nsay mode on' "$DOT" "$DOT")"
HIDDEN="$(printf '            esc %s agents\n\nsay mode on' "$DOT")"
CHANGED="$(printf '  Mode on %s esc %s agents\n\nsay mode on' "$DOT" "$DOT")"

touch "$OUT/go1"
check "capture-pane reads hidden text" "$TMUX" "$FULL"
check "text a row starts with is drawn blank" "$OUTER" "$HIDDEN"

# One cell changes, and the row no longer starts with the text.
touch "$OUT/go2"
check "a row that stops matching shows every cell" "$OUTER" "$CHANGED"

touch "$OUT/go3"
check "a row that matches again hides it" "$OUTER" "$HIDDEN"

$TMUX set -gu pane-hidden-text
check "unsetting the option shows the text" "$OUTER" "$FULL"

$OUTER kill-server 2>/dev/null
$TMUX kill-server 2>/dev/null

[ $FAILED -eq 0 ] || exit 1
echo "ALL HIDDEN TEXT TESTS PASSED"
exit 0
