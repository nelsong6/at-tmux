#!/bin/sh

# The at system's settings on every platform (docs/built-in-settings.md, TMUX-210):
# a server with no config file starts with them, as win32-at-defaults.sh checks on
# Windows. Its keys are the at system's, and the terminal at-terminal presents
# (xterm-256color) is asked for the kitty keyboard protocol, without which
# Ctrl+Tab reaches tmux as a bare Tab (ATT-31).

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest-atd"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone
trap '$TMUX kill-server 2>/dev/null' 0 1 15
FAIL=0
fail() {
	echo "FAIL: $1"
	FAIL=1
}

$TMUX -f /dev/null new -d -x80 -y24 </dev/null || exit 1

[ "$($TMUX show -gv base-index)" = 1 ] || fail "windows aren't numbered from 1"
[ "$($TMUX show -gv prefix)" = None ] || fail "there is a prefix: $($TMUX show -gv prefix)"
$TMUX show -g terminal-overrides | grep -q 'xterm-256color:Eneks=' ||
	fail "xterm-256color isn't asked for the kitty keyboard protocol"
$TMUX show -g terminal-features | grep -q 'xterm-256color:extkeys' ||
	fail "xterm-256color has no extended keys"
$TMUX list-keys -T root C-Tab 2>/dev/null | grep -q 'next-window$' ||
	fail "Ctrl+Tab isn't the next window"
$TMUX list-keys -T root C-b 2>/dev/null | grep -q '@at-menu' ||
	fail "Ctrl+B isn't the at menu"
$TMUX list-keys -T ctrl-t C-c 2>/dev/null | grep -q 'launch-claude' ||
	fail "Ctrl+T Ctrl+C doesn't start Claude through fzt-automate"
[ "$($TMUX show -gv @fzt-automate)" = fzt-automate ] ||
	fail "fzt-automate isn't found on the PATH: $($TMUX show -gv @fzt-automate)"

[ $FAIL -eq 0 ] && echo "PASS: at-defaults" && exit 0
exit 1
