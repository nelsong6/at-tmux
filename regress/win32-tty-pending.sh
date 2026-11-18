#!/bin/sh

# A tty channel no client claims waits in the server's queue: the server
# closes it once 30 seconds old, or at once when 16 already wait, and keeps
# running. Before TMUX-229 both closed the socket with the C runtime's
# close(), which ended the server ("invalid argument to a C runtime
# function").

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

trap "$TMUX kill-server 2>/dev/null" 0 1 15

PS="$(cygpath -u "$POWERSHELL_EXE")"
CHANNEL=$(cygpath -w "$(dirname "$0")/win32-tty-channel.ps1")

fail() {
	echo "FAIL: $1"
	exit 1
}

# channels N: open N tty channels nobody will claim.
channels() {
	"$PS" -NoProfile -ExecutionPolicy Bypass -File "$CHANNEL" \
	    -Label "$LABEL" -Count "$1" || fail "opening $1 tty channels"
}

# alive WHAT: the server still answers a client, which it accepts after
# every channel opened before it.
alive() {
	out=$($TMUX display-message -p ok 2>&1 | tr -d '\r')
	[ "$out" = ok ] || fail "server ended after $1: '$out'"
}

$TMUX -fNUL new -d </dev/null || fail "new-session"
LABEL=$($TMUX display-message -p '#{socket_path}' | tr -d '\r')

# 16 fill the queue and the 17th is turned away.
channels 17
alive "a 17th unclaimed tty channel"

# Past 30 seconds the next channel's arrival expires the 16 waiting. There
# is no condition to poll: the expiry is the server's own clock.
sleep 31
channels 1
alive "unclaimed tty channels expired"

$TMUX kill-server 2>/dev/null
exit 0
