#!/bin/sh

# A respawned pane keeps showing what it showed until its new program first
# puts something on the screen, then shows that in one step (TMUX-193). It was
# erased at once, so an attached client showed it blank while the new program
# started: at-claude's update and home-sync's restarts flashed the screen.
# Output that puts nothing on the screen (a title, the alternate screen) keeps
# the old picture; a program that ends without drawing shows that.
PATH=/bin:/usr/bin
TERM=screen
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
OUTER="$TEST_TMUX -L$TEST_SOCKET-outer"
OUT=$(mktemp -d)
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; rm -rf "$OUT"' 0 1 15
PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"

fail() {
	echo "FAIL: $1"
	$OUTER capture-pane -p 2>/dev/null | tr -d '\r' | head -5
	exit 1
}

# old.ps1 draws OLD and waits.
cat >"$OUT/old.ps1" <<'EOF'
[Console]::Write("$([char]27)[H$([char]27)[2JOLD")
while ($true) { Start-Sleep -Seconds 1 }
EOF
# new.ps1 sets its title and takes the alternate screen, which put nothing on
# it, then draws NEW once the signal file exists (or ends, with -Quit).
cat >"$OUT/new.ps1" <<'EOF'
param([string]$Signal, [string]$Title, [switch]$Quit)
$esc = [char]27
[Console]::Write("$esc]2;$Title$([char]7)$esc[?1049h$esc[H$esc[2J")
if ($Quit) { exit 0 }
while (-not (Test-Path -LiteralPath $Signal)) { Start-Sleep -Milliseconds 25 }
[Console]::Write("NEW")
while ($true) { Start-Sleep -Seconds 1 }
EOF
cat >"$OUT/tmux.conf" <<EOF
set -g status off
set -g remain-on-exit on
EOF
OLD=$(cygpath -ma "$OUT/old.ps1")
NEW=$(cygpath -ma "$OUT/new.ps1")
SIGNAL=$(cygpath -ma "$OUT/signal")

PANE=$($TMUX -f "$OUT/tmux.conf" new -d -x60 -y12 -P -F '#{pane_id}' \
    "$PS" -NoProfile -File "$OLD" </dev/null | tr -d '\r') || exit 1
$OUTER -f "$OUT/tmux.conf" new -d -x60 -y12 \
    "$(cygpath -ma "$TEST_TMUX")" -L"$TEST_SOCKET" attach </dev/null || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || fail 'client never attached'

# shows PATTERN: the attached client's first row matches.
shows() {
	$OUTER capture-pane -p 2>/dev/null | head -1 | tr -d '\r' | grep -q "$1"
}
titled() {
	[ "$($TMUX display -p -t "$PANE" '#{pane_title}' 2>/dev/null |
	    tr -d '\r')" = "$1" ]
}

wait_until shows '^OLD' || fail 'OLD never drawn'

# The new program's title and alternate screen have been read (its title is
# the pane's), yet the client still shows OLD.
$TMUX respawn-pane -k -t "$PANE" "$PS" -NoProfile -File "$NEW" "$SIGNAL" \
    started || fail 'respawn'
wait_until titled started || fail 'the new program never set its title'
shows '^OLD' || fail 'the pane went blank before the new program drew'

# Its first drawing replaces the old picture.
touch "$OUT/signal"
wait_until shows '^NEW' || fail 'NEW never replaced OLD'

# A program that ends without drawing: the pane shows remain-on-exit's line,
# not the picture it held.
rm -f "$OUT/signal"
$TMUX respawn-pane -k -t "$PANE" "$PS" -NoProfile -File "$NEW" "$SIGNAL" \
    quit -Quit || fail 'respawn of a program that ends'
dead() {
	$OUTER capture-pane -p 2>/dev/null | tr -d '\r' |
	    grep -q '^Pane is dead'
}
wait_until dead || fail 'no dead line after a program that drew nothing'
shows '^NEW' && fail 'the held picture stayed after the program ended'

echo 'ALL RESPAWN HOLD TESTS PASSED'
