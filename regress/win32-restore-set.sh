#!/bin/sh

# restore-set runs a window at a time with the server free between windows: the
# client that asked waits for the end, other clients are answered with the true
# state, and commands that make what the restore is making wait. A window that
# fails loses only itself, a client that dies or a hook that runs tmux doesn't stop
# it, and a server that dies part way through leaves the set to be offered again.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

DIR=$(mktemp -d)
WDIR=$(cygpath -m "$DIR")
CFG=$(mktemp)
printf "set -g default-shell '%s'\n" "$COMSPEC" >$CFG
trap "$TMUX kill-server 2>/dev/null; rm -rf $DIR $CFG" 0 1 15

fail() {
	echo "FAIL: $1"
	$TMUX lsw -a -F '#{session_name}:#{window_index} #{window_name} #{window_panes}' 2>&1
	$TMUX show-messages 2>&1 | tail -20
	cat "$DIR"/out 2>/dev/null
	exit 1
}

PS="$(cygpath -m "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe"

# A pane that stays up, doing nothing, with {id} in a comment.
SYS=$(cygpath -w "$SYSTEMROOT")
RESUME="$SYS\System32\cmd.exe /c \"$SYS\System32\PING.EXE -n 300 127.0.0.1 >nul & rem {id}\""

start_server() {
	$TMUX -f"$(cygpath -m $CFG)" new -d -s main -n one || fail "start server"
	$TMUX set -g @session-set-dir "$WDIR" || fail "set dir"
	$TMUX set -g @session-set-resume "$RESUME" || fail "set resume"
	$TMUX set -g @session-set-resume-codex "$RESUME" || fail "set codex resume"
	SOCKET=$(basename "$($TMUX display -p '#{socket_path}' | tr -d '\r')")
	SNAP="$DIR/live/$SOCKET.set"
}
option_is() {
	[ "$($TMUX show -pv -t "$1" "$2" 2>/dev/null | tr -d '\r')" = "$3" ]
}
status_has() {
	$TMUX display -p '#{server_restore}' 2>/dev/null | tr -d '\r' |
	    grep -q -- "$1"
}
restoring() { status_has '^restoring '; }
restored() { [ -z "$($TMUX display -p '#{server_restore}' | tr -d '\r')" ]; }
slow_restore() { $TMUX set-hook -g after-new-window 'run-shell -d 0.3'; }
quick_restore() { $TMUX set-hook -gu after-new-window; }
snap_has() { grep -q -- "$1" "$SNAP" 2>/dev/null; }

start_server

# The set: four windows, one split between a Claude and a Codex pane.
for i in 1 2 3; do
	$TMUX new-window -d -t main -n w$i "$SYS\System32\PING.EXE -n 300 127.0.0.1" ||
	    fail "make w$i"
	$TMUX set -p -t main:w$i @claude-session id$i
	$TMUX set -p -t main:w$i @claude-cwd "$WDIR"
done
$TMUX set -w -t main:w1 automatic-rename on
$TMUX split-window -d -t main:w3 "$SYS\System32\PING.EXE -n 300 127.0.0.1" ||
    fail "split w3"
$TMUX set -p -t main:w3.1 @codex-session cid
$TMUX set -p -t main:w3.1 @codex-cwd "$WDIR"
renamed() { [ "$($TMUX display -p -t main:1 '#{window_name}' | tr -d '\r')" != w1 ]; }
wait_until renamed || fail "the window wasn't named automatically"
wait_until snap_has "id3" || fail "the snapshot has no IDs"
wait_until snap_has "cid" || fail "the snapshot has no Codex ID"
cp "$SNAP" "$DIR/saved"
WIN1=$($TMUX display -p -t main:1 '#{window_name}' | tr -d '\r')

# 1. With no restore running or run, it says so.
[ "$($TMUX restore-set | tr -d '\r')" = "no restore running" ] ||
    fail "restore-set with no file, before any restore"

# 2. The client gets its answer at the end, and the windows a restore removes
#    aren't closed windows.
closed_count() {
	if [ -f "$DIR/closed-windows" ]; then
		wc -l <"$DIR/closed-windows" | tr -d ' '
	else
		echo 0
	fi
}
CLOSED=$(closed_count)
cp "$DIR/saved" "$DIR/one.set"
$TMUX restore-set -d one.set || fail "restore-set"
[ ! -f "$DIR/one.set" ] || fail "the source stayed after the restore"
$TMUX has-session -t =main-2 || fail "restore-set made no set"
WINDOWS=$($TMUX lsw -t =main-2 | wc -l | tr -d ' ')
[ "$WINDOWS" = "$($TMUX lsw -t =main | wc -l | tr -d ' ')" ] ||
    fail "restore-set made $WINDOWS windows"
[ "$(closed_count)" = "$CLOSED" ] ||
    fail "the restore's stand-in windows went on closed-windows"
$TMUX restore-set | tr -d '\r' | grep -q "^no restore running; last restored $WINDOWS of $WINDOWS windows$" ||
    fail "the last restore isn't reported"
$TMUX kill-session -t =main-2 || fail "clean up"

# 3. While it runs: progress, reads answered, a second restore refused with the
#    state, a command that makes a window waits, and the source is still there.
slow_restore
cp "$DIR/saved" "$DIR/two.set"
cp "$DIR/saved" "$DIR/three.set"
$TMUX restore-set -d two.set >"$DIR/out" 2>&1 &
RESTORE=$!
wait_until restoring || fail "#{server_restore} showed no restore"
$TMUX restore-set | tr -d '\r' | grep -q '^restoring [0-9]* of [0-9]* windows$' ||
    fail "restore-set with no file during a restore"
$TMUX has-session -t =main || fail "a read wasn't answered during a restore"
[ -f "$DIR/two.set" ] || fail "the source went before the restore ended"
snap_has '^restoring	0' || fail "a restore beside live windows marked the snapshot"
if $TMUX restore-set -d three.set 2>"$DIR/refused"; then
	fail "a second restore started"
fi
grep -q '^restoring ' "$DIR/refused" || fail "the refusal doesn't say why"
$TMUX new-window -d -t =main -n beside ||
    fail "a window in a session the restore isn't making"
[ -n "$($TMUX display -p '#{server_restore}' | tr -d '\r')" ] ||
    fail "the restore ended before the window beside it"
(
	$TMUX new-window -d -t =main-2 -n held
	[ "$($TMUX display -p '#{server_restore}' | tr -d '\r')" = "" ] &&
	    touch "$DIR/after-restore"
	touch "$DIR/made"
) &
HELD=$!
sleep 0.2
[ ! -f "$DIR/made" ] || fail "a window was made during the restore"
wait "$RESTORE" || fail "restore-set failed"
wait "$HELD"
[ -f "$DIR/made" ] || fail "the held command never ran"
[ -f "$DIR/after-restore" ] || fail "the held command ran before the end"
$TMUX lsw -t =main-2 -F '#{window_name}' | tr -d '\r' | grep -qx held ||
    fail "the held window wasn't made"
$TMUX kill-window -t =main:beside || fail "clean up"
[ ! -f "$DIR/two.set" ] || fail "the source wasn't archived"
wait_until sh -c "! grep -q '^restoring	1' '$SNAP'" ||
    fail "the snapshot stayed marked restoring"
$TMUX kill-session -t =main-2 || fail "clean up"
quick_restore

# 4. Windows keep their order however a client moves about during the restore.
slow_restore
cp "$DIR/saved" "$DIR/four.set"
$TMUX restore-set -d four.set &
RESTORE=$!
wait_until restoring || fail "no restore to move about in"
wait_until $TMUX has-session -t =main-2 || fail "no session yet"
wait_until sh -c "[ \$($TMUX lsw -t =main-2 | wc -l) -ge 2 ]" ||
    fail "no second window"
$TMUX select-window -t "=main-2:^" || fail "select the first window"
wait "$RESTORE" || fail "restore-set failed"
[ "$($TMUX lsw -t =main -F '#{window_name}' | tr -d '\r' | tail -3 | tr '\n' ' ')" = \
  "$($TMUX lsw -t =main-2 -F '#{window_name}' | tr -d '\r' | tail -3 | tr '\n' ' ')" ] ||
    fail "the windows came back out of order"
$TMUX kill-session -t =main-2 || fail "clean up"
quick_restore

# 5. A window that can't start loses only itself, and the exit says which.
$TMUX set -g @session-set-restart-cmd "no-such-program.exe argument"
cp "$DIR/saved" "$DIR/five.set"
if $TMUX restore-set -d five.set 2>"$DIR/out"; then
	fail "a failed window wasn't reported"
fi
grep -q "^restored [0-9]* of $WINDOWS windows, failed: main-2:" "$DIR/out" ||
    fail "the failure doesn't name the window"
$TMUX lsw -t =main-2 -F '#{window_name}' | tr -d '\r' | grep -qx w3 ||
    fail "the windows after the failed one were lost"
$TMUX kill-session -t =main-2 || fail "clean up"
$TMUX set -gu @session-set-restart-cmd

# 7. upgrade-server waits for the restore, and says so.
slow_restore
cp "$DIR/saved" "$DIR/seven.set"
$TMUX restore-set -d seven.set &
RESTORE=$!
wait_until restoring || fail "no restore to upgrade during"
$TMUX upgrade-server "$(cygpath -m "$TEST_TMUX")" 2>/dev/null
upgrade_waits() {
	$TMUX display -p '#{server_upgrade}' | tr -d '\r' |
	    grep -q 'a restore is running'
}
wait_until upgrade_waits || fail "the upgrade doesn't say it waits for the restore"
wait "$RESTORE" || fail "restore-set failed"
$TMUX kill-session -t =main-2 2>/dev/null
quick_restore

# 8. The client that asked dies during a restore with a window failing: the
#    server carries on, and the failure stays on record.
$TMUX set -g @session-set-restart-cmd "no-such-program.exe argument"
slow_restore
cp "$DIR/saved" "$DIR/dead.set"
$TMUX restore-set -d dead.set >/dev/null 2>&1 &
RESTORE=$!
wait_until restoring || fail "no restore for the client to die in"
"$(cygpath -u "$SYSTEMROOT")/System32/taskkill.exe" //F //PID \
    "$(cat /proc/$RESTORE/winpid)" >/dev/null
wait "$RESTORE"
wait_until restored || fail "the restore never ended"
$TMUX has-session -t =main 2>/dev/null ||
    fail "a dead client's failed restore ended the server"
$TMUX restore-set | tr -d '\r' | grep -q "failed: main-2:" ||
    fail "the failure isn't on record"
$TMUX kill-session -t =main-2 || fail "clean up"
$TMUX set -gu @session-set-restart-cmd
quick_restore

# 9. restore-set from a hook runs on the queue its own steps use, so nothing
#    waits for it there.
hook_restored() { $TMUX has-session -t =main 2>/dev/null && restored; }
hook_clean() {
	$TMUX set-hook -gu session-renamed
	$TMUX kill-session -t =main || fail "clean up"
	$TMUX rename-session -t =moved main || fail "clean up"
}
cp "$DIR/saved" "$DIR/hook.set"
$TMUX set-hook -g session-renamed 'restore-set -d hook.set'
$TMUX rename-session -t =main moved || fail "rename"
wait_until hook_restored || fail "restore-set from a hook never finished"
hook_clean

# 10. A foreground run-shell in a hook holds that queue until its program ends.
#     The tmux it runs can't be left waiting for the restore behind it, whether
#     that tmux starts the restore or runs a command that waits for one.
SHELL_TMUX="\"$(cygpath -w "$(readlink -f "$TEST_TMUX")")\" -L$TEST_SOCKET"
cp "$DIR/saved" "$DIR/shell.set"
$TMUX set-hook -g session-renamed "run-shell '$SHELL_TMUX restore-set -d shell.set'"
$TMUX rename-session -t =main moved || fail "rename"
wait_until hook_restored || fail "restore-set from a hook's run-shell never finished"
hook_clean
cp "$DIR/saved" "$DIR/inner.set"
$TMUX set-hook -g after-new-window "run-shell '$SHELL_TMUX new-session -d -s inner'"
$TMUX restore-set -d inner.set || fail "a restore with a hook's tmux in it"
wait_until restored || fail "a hook's tmux held the restore up"
$TMUX set-hook -gu after-new-window
$TMUX has-session -t =inner || fail "the hook's tmux never ran"
$TMUX kill-session -t =inner || fail "clean up"
[ "$($TMUX lsw -t =main-2 | wc -l | tr -d ' ')" = "$WINDOWS" ] ||
    fail "a hook's tmux cost the restore windows"
$TMUX kill-session -t =main-2 || fail "clean up"

# 11. kill-server during a restore ends the server and the waiting client, and
#     leaves the source.
$TMUX kill-server
wait_gone
start_server
slow_restore
cp "$DIR/saved" "$DIR/eight.set"
$TMUX restore-set -d eight.set >/dev/null 2>&1 &
RESTORE=$!
wait_until restoring || fail "no restore to kill"
$TMUX kill-server
wait_gone
wait "$RESTORE"
[ -f "$DIR/eight.set" ] || fail "kill-server lost the source"

# A client in a pseudo-console: a server that showed nobody leaves nothing to
# offer, whatever its snapshot says.
attach() {
	"$PS" -NoProfile -ExecutionPolicy Bypass 	    -File "$(cygpath -w "$(dirname "$0")/win32-pty.ps1")" 	    -Command "\"$(cygpath -wa "$TEST_TMUX")\" -L$TEST_SOCKET attach" 	    -Cols 100 -Rows 30 -ResizeFile "$(cygpath -w "$DIR/resize")" &
	CLIENT=$!
	wait_until snap_has "^attached	main$" || fail "the client wasn't saved"
}
# The server and its panes die, as in a crash. The client ends with it.
die() {
	PID=$($TMUX display -p '#{pid}' | tr -d '')
	PANES=$($TMUX list-panes -a -F '#{pane_pid}' | tr -d '')
	"$(cygpath -u "$SYSTEMROOT")/System32/taskkill.exe" //F //PID "$PID" >/dev/null
	wait_gone
	for pane in $PANES; do
		"$(cygpath -u "$SYSTEMROOT")/System32/taskkill.exe" //F //T //PID "$pane" >/dev/null 2>&1
	done
	wait "$RESTORE"
	wait "$CLIENT"
}

# 12. A server that dies restoring the set it was offered leaves that set where
#     the next server offers it, with the partly restored snapshot in the archive.
start_server
attach
slow_restore
PREVIOUS="$DIR/live/$SOCKET-previous.set"
cp "$DIR/saved" "$PREVIOUS"
$TMUX restore-set -d "live/$SOCKET-previous.set" >/dev/null 2>&1 &
RESTORE=$!
wait_until restoring || fail "no restore to die in"
wait_until snap_has '^restoring	1' || fail "the snapshot isn't marked"
die
start_server
wait_until sh -c "! grep -q '^restoring	1' '$SNAP'" ||
    fail "the new server's snapshot is marked restoring"
cmp -s "$DIR/saved" "$PREVIOUS" || fail "the set wasn't left to be offered"

# 13. A server that dies restoring anything else leaves its own windows offered.
rm "$PREVIOUS"
attach
slow_restore
cp "$DIR/saved" "$DIR/beside.set"
$TMUX restore-set -d beside.set >/dev/null 2>&1 &
RESTORE=$!
wait_until restoring || fail "no restore to die beside"
wait_until snap_has 'main-2' || fail "the snapshot has no restored window"
snap_has '^restoring	0' || fail "a restore beside live windows marked the snapshot"
die
start_server
wait_until test -f "$PREVIOUS" || fail "the server's windows weren't left to be offered"
[ -f "$DIR/beside.set" ] || fail "the source went with the server"

exit 0
