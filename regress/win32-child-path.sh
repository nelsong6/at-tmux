#!/bin/sh
# Executable selection and the child environment agree after PATH updates,
# including a managed directory with spaces and session overrides.
PATH=/bin:/usr/bin
TERM=screen
[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
OUT=$(mktemp -d)
NATIVE=$(cygpath -ma "$OUT")
cleanup() {
	$TMUX kill-server 2>/dev/null
	rm -f "$OUT/old/tmux-old-probe.exe" "$OUT/managed tools/tmux-child-probe.exe" "$OUT/session/tmux-session-probe.exe"
	rmdir "$OUT/old" "$OUT/managed tools" "$OUT/session" "$OUT"
}
trap cleanup 0 1 15
fail(){ echo "FAIL: $1"; exit 1; }
mkdir "$OUT/old" "$OUT/managed tools" "$OUT/session"
SOURCE="$(cygpath -u "$SYSTEMROOT")/System32/where.exe"
cp "$SOURCE" "$OUT/old/tmux-old-probe.exe"
cp "$SOURCE" "$OUT/managed tools/tmux-child-probe.exe"
cp "$SOURCE" "$OUT/session/tmux-session-probe.exe"
PATH="$OUT/old:/bin:/usr/bin" $TMUX -fNUL new -d -s probe "$COMSPEC" //d //q || fail "new server"
$TMUX setenv -g PATH "$NATIVE/managed tools;$SYSTEMROOT/System32"
# A non-attached new-window caller supplies its own PATH, as upstream does.
PATH="$OUT/managed tools:/bin:/usr/bin" $TMUX new-window -d -t probe: -n found -o remain-on-exit=on tmux-child-probe.exe tmux-child-probe.exe || fail "pane executable from child PATH"
finished() { [ "$($TMUX display-message -p -t probe:found '#{pane_dead}:#{pane_dead_status}')" = '1:0' ]; }
wait_until finished || { $TMUX capture-pane -t probe:found -p; fail "selected pane program didn't run successfully"; }
$TMUX pipe-pane -t probe:^ 'tmux-child-probe.exe cmd.exe' || fail "pipe executable from global PATH"
# The original OS PATH must not resurrect a program removed from the child PATH.
if $TMUX pipe-pane -t probe:^ 'tmux-old-probe.exe cmd.exe' 2>/dev/null;then fail "pipe inherited the old executable search path";fi
if PATH=/bin:/usr/bin $TMUX new-window -d -t probe: tmux-old-probe.exe cmd.exe 2>/dev/null;then fail "pane inherited the old executable search path";fi
$TMUX setenv -t probe PATH "$NATIVE/session;$SYSTEMROOT/System32"
$TMUX pipe-pane -t probe:^ 'tmux-session-probe.exe cmd.exe' || fail "pipe executable from session PATH"
if $TMUX pipe-pane -t probe:^ 'tmux-child-probe.exe cmd.exe' 2>/dev/null;then fail "global PATH overrode the session PATH";fi
# An explicitly addressed program remains independent of PATH lookup.
$TMUX pipe-pane -t probe:^ "\"$NATIVE/old/tmux-old-probe.exe\" cmd.exe" || fail "explicit executable path"
echo 'ALL CHILD PATH TESTS PASSED'
