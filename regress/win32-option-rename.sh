#!/bin/sh

# A window's automatic name follows a user option its format reads, even when
# its program prints nothing more (TMUX-231). tmux works a name out again only
# after the window's active pane changes, which output does; a Claude session's
# start hook set @claude-title after its program had drawn and gone quiet, so
# after a restore every at-claude window kept the name it had before the hook
# ran until something in it was drawn again. Setting a user option, at any
# scope, or the format itself has every automatic name checked again; a window
# renamed by hand keeps its name.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

CFG=$(mktemp)
cleanup() {
	$TMUX kill-server 2>/dev/null
	rm -f $CFG
}
trap cleanup 0 1 15

FAIL=0
fail() {
	echo "FAIL: $1"
	FAIL=1
}

# The program draws once as its console starts and then prints nothing.
PING=$(cygpath -w "$SYSTEMROOT/System32/PING.EXE")
QUIET="\"$PING\" -n 120 127.0.0.1 >nul"
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
printf "set -g automatic-rename-format '#{?@title,#{@title},idle}'\n" >>$CFG
$TMUX -f$CFG new -d -s w -x 80 -y 24 "$QUIET" </dev/null || exit 1
PANE=$($TMUX display -p -t w '#{pane_id}' | tr -d '\r')
HAND=$($TMUX new-window -d -P -F '#{window_id}' -t w "$QUIET" | tr -d '\r')
$TMUX rename-window -t "$HAND" by-hand

name() {
	$TMUX display -p -t "${2:-$PANE}" '#{window_name}' 2>/dev/null | tr -d '\r'
}
named() {
	[ "$(name)" = "$1" ]
}
# expect WHAT NAME: the quiet window comes to be called NAME.
expect() {
	wait_until named "$2" || fail "$1: the window is called '$(name)', not '$2'"
}

expect "first draw" idle
# Its console has finished drawing: no output for a second.
activity() {
	$TMUX display -p -t "$PANE" '#{window_activity}' 2>/dev/null | tr -d '\r'
}
quiet() {
	_was=$(activity)
	sleep 1
	[ "$(activity)" = "$_was" ]
}
wait_until quiet || fail "the window never stopped printing"

$TMUX set -p -t "$PANE" @title from-pane
expect "a pane option" from-pane

$TMUX set -p -t "$PANE" -u @title
expect "a pane option unset" idle

$TMUX set -w -t "$PANE" @title from-window
expect "a window option" from-window
$TMUX set -w -t "$PANE" -u @title

$TMUX set -g @title global
expect "a global option" global

$TMUX set -g automatic-rename-format 'format-#{@title}'
expect "the format" format-global

[ "$(name x "$HAND")" = by-hand ] ||
    fail "a window renamed by hand is called '$(name x "$HAND")'"

[ $FAIL -eq 0 ] && echo "ALL OPTION RENAME TESTS PASSED"
exit $FAIL
