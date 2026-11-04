#!/bin/sh

# A pane changing behind a popup leaves the popup alone and still changes
# beside it (TMUX-103). Each step is something the pane does to rows the popup
# covers. A popup is only repainted when something asks for it, so a row a step
# damaged stays damaged for the check after the step. The last step ended the
# server before: a wide character across the popup's edge in a colour of its
# own never ended the line being drawn. The client runs in a pane of a second
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

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"

cat >"$OUT/popup.ps1" <<'EOF'
# Numbered rows, then nothing: any change after this came from outside.
$esc = [char]27
[Console]::Write("$esc[?25l$esc[2J$esc[H")
foreach ($i in 0..21) {
	$row = 'ROW{0:d2} ' -f $i
	$row += 'x' * (88 - $row.Length)
	if ($i -lt 21) { $row += "`r`n" }
	[Console]::Write($row)
}
Start-Sleep 300
EOF

cat >"$OUT/pane.ps1" <<'EOF'
param([string]$Dir)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
$esc = [char]27
$kanji = [string][char]0x6F22
function go($row) { "$esc[$row;1H" }
function fill {
	foreach ($r in 1..30) { [Console]::Write((go $r) + ('p' * 99)) }
}
function step($name) {
	while (-not (Test-Path -LiteralPath "$Dir\$name")) {
		Start-Sleep -Milliseconds 20
	}
	[Console]::Write("$esc[?1049h$esc[2J")
	fill
	switch ($name) {
		'el' {
			foreach ($r in 1..30) { [Console]::Write((go $r) + "s$esc[K") }
		}
		'ed' { [Console]::Write((go 12) + "$esc[J") }
		'dch' {
			foreach ($r in 1..30) { [Console]::Write((go $r) + "$esc[3P") }
		}
		'ich' {
			foreach ($r in 1..30) { [Console]::Write((go $r) + "$esc[3@") }
		}
		'region' {
			[Console]::Write("$esc[5;10r" + (go 10) + "`n$esc[r")
		}
		'wide' {
			foreach ($r in 1..30) {
				[Console]::Write((go $r) + ($kanji * 49))
				[Console]::Write("$esc[$r;2Hab")
			}
		}
		'widebg' {
			foreach ($r in 1..30) {
				[Console]::Write((go $r) + ($kanji * 2) + "$esc[41m" +
				    ($kanji * 47) + "$esc[m")
			}
			[Console]::Write((go 30) + "`n`n`n")
		}
	}
	[Console]::Write((go 30) + "$esc[2Kdone $name")
}
foreach ($name in 'el', 'ed', 'dch', 'ich', 'region', 'wide', 'widebg') {
	step $name
}
Start-Sleep 300
EOF

CFG="$OUT/test.conf"
cat >"$CFG" <<EOF
set -g default-shell "$PS"
set -g status off
EOF

$TMUX -f "$(cygpath -m "$CFG")" new -d -x100 -y30 \
    "& '$PS' -NoProfile -ExecutionPolicy Bypass -File '$(cygpath -m "$OUT/pane.ps1")' -Dir '$(cygpath -w "$OUT")'" \
    </dev/null || exit 1
$OUTER -f "$(cygpath -m "$CFG")" new -d -x100 -y30 \
    "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" </dev/null || exit 1

attached() {
	[ -n "$($TMUX list-clients 2>/dev/null)" ]
}
wait_until attached || { echo "client never attached"; $OUTER capture-pane -p; exit 1; }

$TMUX display-popup -E -w 90 -h 24 -x 5 -y 3 \
    "& '$PS' -NoProfile -ExecutionPolicy Bypass -File '$(cygpath -m "$OUT/popup.ps1")'" &

screen() {
	$OUTER capture-pane -p 2>/dev/null | tr -d '\r'
}
popup_rows() {
	screen | grep -c 'ROW[0-9][0-9] xxx'
}
popup_up() {
	[ "$(popup_rows)" = 22 ]
}
wait_until popup_up || { echo "popup never drew"; screen; exit 1; }

# step NAME: run a step; the popup keeps every row and its border.
step() {
	: >"$OUT/$1"
	NAME=$1
	wait_until step_done || { echo "$1: pane never finished"; screen; exit 1; }
	if [ "$(popup_rows)" != 22 ] || [ "$(screen | grep -c '│ROW')" != 22 ]; then
		echo "$1: popup damaged:"
		screen
		exit 1
	fi
}
step_done() {
	screen | sed -n 30p | grep -q "^done $NAME"
}

step el
# Row 20 was cleared after its first cell, on both sides of the popup.
ROW=$(screen | sed -n 20p)
LEFT=$(printf '%s' "$ROW" | cut -c1-5)
[ "$LEFT" = "s" ] || [ "$LEFT" = "s    " ] || { echo "el: left of the popup: '$ROW'"; exit 1; }
case "$ROW" in
*p*) echo "el: pane text left beside the popup: '$ROW'"; exit 1 ;;
esac

step ed
ROW=$(screen | sed -n 20p)
case "$ROW" in
*p*) echo "ed: pane text left beside the popup: '$ROW'"; exit 1 ;;
esac

step dch
step ich
step region
step wide
step widebg

# Closing the popup shows the pane as it now stands, and the server is alive.
$TMUX display-popup -C || exit 1
gone() {
	[ "$(popup_rows)" = 0 ]
}
wait_until gone || { echo "popup never closed"; screen; exit 1; }
$TMUX list-sessions >/dev/null || { echo "server gone"; exit 1; }

$OUTER kill-server 2>/dev/null
$TMUX kill-server 2>/dev/null

echo "ALL POPUP OUTPUT TESTS PASSED"
exit 0
