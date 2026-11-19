#!/bin/sh

# at-protocol on macOS and Linux (TMUX-239, docs/at-protocol.md): the build speaks
# the version the portfile pins, says hello to a terminal, tells one of another
# version so, and sends one of the same version a virtual image once and its
# placeholders as a placement. The client runs in a pane of a second server; the
# test plays the terminal by answering the hello on the client's input, and reads
# what the client was sent from tmux's -vv output log. regress/win32-placed-images.sh
# covers the same on Windows, with the rest of placed images.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TEST_TMUX=$(cd "$(dirname "$TEST_TMUX")" && pwd)/$(basename "$TEST_TMUX")
PORT=$(cd "$(dirname "$0")/.." && pwd)/dep/vcpkg-overlay-ports/at-protocol/portfile.cmake
TMUX="$TEST_TMUX -Ltest-at"
OUTER="$TEST_TMUX -Ltest-at-outer"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
$OUTER kill-server 2>/dev/null
wait_gone

OUT=$(mktemp -d)
trap '$OUTER kill-server 2>/dev/null; $TMUX kill-server 2>/dev/null; cd /; rm -rf "$OUT"' 0 1 15
cd "$OUT" || exit 1

fail() {
	echo "FAIL: $*"
	echo "--- the server log's end:"
	tail -30 "$(ls -t tmux-server-*.log 2>/dev/null | head -1)" | cut -c1-200
	exit 1
}

# The build speaks the commit the portfile pins.
REF=$(sed -n 's/^set(REF \([0-9a-f]\{40\}\))$/\1/p' "$PORT")
[ -n "$REF" ] || fail "no REF in $PORT"

cat >outer.conf <<EOF
set -g status off
set -g window-size manual
set -g default-terminal xterm-256color
EOF
cat >test.conf <<EOF
set -as terminal-features ',xterm-256color:sixel'
set -g status off
EOF
# The image a pane shows: a 2x2 picture over 2x1 cells as a virtual placement
# (kitty graphics U=1), then its two placeholders, coloured with its ID.
P=$(printf '\364\216\273\256')
cat >image.sh <<EOF
printf '\033_Ga=T,U=1,i=5,f=32,s=2,v=2,c=2,r=1,q=2;/////////////////////w==\033\\\\'
printf '\033[38;5;5m$P\314\205\314\205$P\314\205\314\215\033[m image-done\n'
exec sleep 100
EOF

$TMUX -vv -f test.conf new -d -x60 -y20 "exec sleep 100" </dev/null || exit 1
V=$($TMUX display -p '#{at_protocol_version}')
[ "$V" = "$REF" ] || fail "the build speaks at-protocol '$V', the portfile pins $REF"

$OUTER -f outer.conf new -d -x60 -y20 "$TMUX attach" </dev/null || exit 1
attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
wait_until attached || fail "client never attached"

ESC=$(printf '\033')
log() { ls -t tmux-out-*.log 2>/dev/null | head -1; }
srv() { ls -t tmux-server-*.log 2>/dev/null | head -1; }
at_msgs() { LC_ALL=C grep -a -o "${ESC}_at;" "$(log)" | wc -l; }
said_hello() { [ -n "$(log)" ] && [ "$(at_msgs)" -ge 1 ]; }
wait_until said_hello || fail "the server said no hello to the terminal"

# hello VERSION: the APC string a terminal answers with, as hex for send-keys -H.
hello() {
	printf '\033_at;%s\033\\' "$(printf '\001%s%s' "$(printf "\\$(printf '%03o' ${#1})")" "$1" | base64 | tr -d '\n')" |
	    od -An -tx1 | tr -d ' \n' | sed 's/../& /g'
}

# Another version is told so, and gets nothing in at-protocol.
BEFORE=$(at_msgs)
$OUTER send-keys -t 0 -H $(hello nope)
told() { $OUTER capture-pane -p | grep -q 'speaks at-protocol nope'; }
wait_until told || fail "a hello of another version wasn't told so: $($OUTER capture-pane -p | tail -2)"

# The same version speaks it: a virtual image's picture goes once, and its
# placeholders as a placement.
$OUTER send-keys -t 0 -H $(hello "$V")
same() { grep -q "at-protocol $V, the same as this build" "$(srv)"; }
wait_until same || fail "a hello of this version wasn't taken"
[ "$(at_msgs)" -eq "$BEFORE" ] || fail "a terminal of another version was sent at-protocol"
$TMUX respawn-pane -k "sh $OUT/image.sh" || fail "respawn-pane"
shows() { $TMUX capture-pane -p | grep -q image-done; }
wait_until shows || fail "the pane never drew its image"
placed() { [ "$(at_msgs)" -ge $((BEFORE + 2)) ]; }
wait_until placed || fail "the image went as $(($(at_msgs) - BEFORE)) at-protocol messages, want its picture and a placement"
grep -q 'sent image 5 as' "$(srv)" || fail "the server log has no picture sent for image 5"

echo "PASS: at-protocol"
exit 0
