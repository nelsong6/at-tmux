#!/bin/sh

# record-output (TMUX-211): with the option on, every byte the server sends a
# client's terminal is written to <socket>.out in TMUX_OUTPUT_DIR as frames
# (W for sent, D for thrown away because the terminal couldn't keep up); a
# file that would pass record-output-limit becomes .out.1, so two files at
# most; off deletes both, as does a fresh server of the same name, while
# upgrade-server carries the option and the new process goes on recording.
# The client runs in a pane of a second server so its console is a real one.

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

SUSPEND=$(cygpath -w "$(cd "$(dirname "$0")" && pwd)/win32-suspend.ps1")
OUT=$(mktemp -d)
remove() { rm -rf "$OUT" 2>/dev/null; [ ! -e "$OUT" ]; }
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; cd /; wait_until remove' 0 1 15
cd "$OUT" || exit 1
EXE=$(cygpath -w "$TEST_TMUX")

TMUX_OUTPUT_DIR=$(cygpath -m "$OUT/rec")
export TMUX_OUTPUT_DIR

fail() {
	echo "FAIL: $*"
	exit 1
}

# The recording is named for the socket, as the server names it.
$TMUX -f /dev/null new -d </dev/null || exit 1
SOCKET=$($TMUX display -p '#{socket_path}' | tr -d '\r')
$TMUX kill-server
wait_gone
REC=$OUT/rec/${SOCKET##*[/\\]}.out

# A recording a server of this name left behind.
mkdir -p rec
echo leftover >"$REC"
echo leftover >"$REC.1"

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"
cat >outer.conf <<EOF
set -g default-shell "$PS"
set -g status off
EOF
cat >test.conf <<EOF
set -g default-shell "$PS"
set -g status-right 'P:#{@probe}'
EOF

$TMUX -f test.conf new -d -x60 -y16 "Start-Sleep 300" </dev/null || exit 1
$OUTER -f outer.conf new -d -x60 -y16 "& '$(cygpath -ma "$TEST_TMUX")' -L$TEST_SOCKET attach" \
    </dev/null || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || fail "client never attached"
CLIENT=$($TMUX list-clients -F '#{client_name}' | tr -d '\r')

# A fresh server deletes the recording an earlier one of its name left.
[ -e "$REC" ] && fail "a fresh server kept the old recording"
[ -e "$REC.1" ] && fail "a fresh server kept the old .1 file"

# Off: nothing is recorded.
shown() { $OUTER capture-pane -p 2>/dev/null | tr -d '\r' | grep -q -- "$1"; }
$TMUX set -g @probe OFF-MARK
wait_until shown 'P:OFF-MARK' || fail "the client never drew OFF-MARK"
[ -e "$REC" ] && fail "recorded with record-output off"

# frames FILE: check FILE is whole frames and print "kind client size"
# for each; exits 1 on anything else.
frames() {
	# Lines are read as bytes; a W frame's bytes and newline must end
	# exactly at a line's end.
	LC_ALL=C awk -v BINMODE=3 '
	need > 0 {
		need -= length($0) + 1
		if (need < 0) { print "a frame before line " NR " is cut short"; exit 1 }
		next
	}
	{
		if ($0 !~ /^[WD] [0-9]+ [^ ]+ [0-9]+x[0-9]+ [0-9]+$/) {
			print "bad header at line " NR ": " substr($0, 1, 60); exit 1
		}
		split($0, f, " ")
		if (f[1] == "W")
			need = f[5] + 1
		print f[1], f[3], f[4]
	}
	END { if (need > 0) { print "the last frame is cut short"; exit 1 } }' "$1"
}

# On: what reaches the terminal is recorded, under the client's name and size.
$TMUX set -s record-output on
$TMUX set -g @probe ON-MARK
wait_until shown 'P:ON-MARK' || fail "the client never drew ON-MARK"
recorded() { [ -e "$REC" ] && LC_ALL=C grep -q -a -- "$1" "$REC"; }
wait_until recorded 'P:ON-MARK' || fail "ON-MARK was not recorded"
frames "$REC" >frames.txt || fail "$(tail -1 frames.txt)"
grep -q "^W $CLIENT 60x16\$" frames.txt ||
    fail "no frame for $CLIENT at 60x16: $(sort -u frames.txt)"

# upgrade-server: the new process goes on recording into the same file.
PID=$($TMUX display -p '#{pid}' | tr -d '\r')
BEFORE=$(wc -c <"$REC")
$TMUX upgrade-server "$EXE" || fail "upgrade-server refused"
upgraded() {
	_p=$($TMUX display -p '#{pid}' 2>/dev/null | tr -d '\r')
	[ -n "$_p" ] && [ "$_p" != "$PID" ]
}
wait_until upgraded || fail "the server was never upgraded: $($TMUX display -p "#{server_upgrade}")"
[ "$($TMUX show -sv record-output | tr -d '\r')" = on ] ||
    fail "upgrade-server lost record-output"
$TMUX set -g @probe UPGRADE-MARK
wait_until recorded 'P:UPGRADE-MARK' || fail "nothing recorded after upgrade-server"
[ "$(head -c "$BEFORE" "$REC" | LC_ALL=C grep -c -a 'P:ON-MARK')" -gt 0 ] ||
    fail "upgrade-server started the recording again"
frames "$REC" >frames.txt || fail "after upgrade: $(tail -1 frames.txt)"

# Output the terminal can't take is thrown away and recorded as a D frame:
# the client is suspended while the pane prints, then resumed.
CPID=$($TMUX list-clients -F '#{client_pid}' | tr -d '\r')
resume() { "$PS" -NoProfile -ExecutionPolicy Bypass -File "$SUSPEND" -Id "$CPID"; }
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$SUSPEND" -Id "$CPID" -Suspend
$TMUX respawn-pane -k "1..5000 | % { 'flood line ' + \$_ + ' ' + ('x' * 40) }; Start-Sleep 300"
flooded() { $TMUX capture-pane -p | tr -d '\r' | grep -q 'flood line 5000 '; }
wait_until flooded || { resume; fail "the pane never printed its lines"; }
resume
discarded() { LC_ALL=C grep -a -q "^D [0-9]* $CLIENT " "$REC"; }
wait_until discarded ||
    fail "no D frame after the terminal fell behind (client_discarded=$($TMUX display -p '#{client_discarded}'))"
frames "$REC" >frames.txt || fail "after discarding: $(tail -1 frames.txt)"

# The limit: a file that would pass it becomes .out.1, replacing the last.
$TMUX set -s record-output-limit 64
$TMUX respawn-pane -k "1..4000 | % { 'limit line ' + \$_ + ' ' + ('y' * 40) }; Start-Sleep 300"
rolled() { [ -e "$REC.1" ] && LC_ALL=C grep -q -a 'limit line' "$REC.1"; }
wait_until rolled || fail "the recording never rolled over at 64 KB"
for f in "$REC" "$REC.1"; do
	[ "$(wc -c <"$f")" -le 65536 ] || fail "$f is $(wc -c <"$f") bytes, past 64 KB"
	frames "$f" >frames.txt || fail "$f: $(tail -1 frames.txt)"
done
[ "$(ls rec | wc -l)" -eq 2 ] || fail "more than two files: $(ls rec)"

# Off deletes both files and records nothing more.
$TMUX set -s record-output off
[ -e "$REC" ] && fail "record-output off kept the recording"
[ -e "$REC.1" ] && fail "record-output off kept the .1 file"
$TMUX set -g @probe AFTER-MARK
wait_until shown 'P:AFTER-MARK' || fail "the client never drew AFTER-MARK"
[ -e "$REC" ] && fail "recorded after record-output off"

echo "PASS: record-output"
exit 0
