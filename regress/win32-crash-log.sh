#!/bin/sh

# A crash of the release package explains itself: tmux-crash-<pid>.log names
# function, file and line from the PDB beside the exe. The server runs through
# a junction as home-sync's `current` is, and the junction moves on before the
# crash, as it does when a release lands (TMUX-114). TEST_TMUX is a tmux.exe
# with its PDB beside it and no PDB at the path stored in it, as on a home PC.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"

system=$(cygpath "$SYSTEMROOT")/System32
powershell=$system/WindowsPowerShell/v1.0/powershell.exe
cmd=$system/cmd.exe

dir=$(dirname "$0")
package=$(cd "$(dirname "$TEST_TMUX")" && pwd)
OUT=$(mktemp -d) || exit 1
winout=$(cygpath -aw "$OUT")
TMUX="$OUT/current/tmux.exe -L$TEST_SOCKET"
TMUX_FLIGHT_DIR=$(cygpath -m "$OUT/flight")
export TMUX_FLIGHT_DIR
. "$dir/win32-wait.sh"

# wer_listed NAME: whether this user's list of crash helpers has that path.
wer_key='HKCU:\Software\Microsoft\Windows\Windows Error Reporting\RuntimeExceptionHelperModules'
wer_listed() {
	"$powershell" -NoProfile -Command "(Get-Item '$wer_key').GetValue('$1') -ne \$null" |
	    tr -d '\r' | grep -q True
}
wer_stale="$winout\\gone\\tmux-wer.dll"
wer_helper="$(cygpath -aw "$package")\\tmux-wer.dll"
wer_forget() {
	"$powershell" -NoProfile -Command "
		Remove-ItemProperty '$wer_key' -Name '$wer_stale' -ErrorAction SilentlyContinue
		Remove-ItemProperty '$wer_key' -Name '$wer_helper' -ErrorAction SilentlyContinue"
}

# Junctions go first: rm -rf would follow one into the package.
cleanup() {
	$TMUX kill-server 2>/dev/null
	"$powershell" -NoProfile -Command "
		Get-CimInstance Win32_Process |
		    Where-Object { \$_.ExecutablePath -like '$(cygpath -aw "$package")\\*' -or
		        \$_.ExecutablePath -like '$winout\\*' } |
		    ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }"
	"$cmd" //c rmdir "$winout\\current" 2>/dev/null
	rm -rf "$OUT"
	wer_forget
}
trap cleanup 0 1 15

fail() {
	echo "FAIL: $1"
	[ -f "$log" ] && cat "$log"
	exit 1
}

[ -f "$package/tmux.pdb" ] || fail "no tmux.pdb beside $TEST_TMUX"

"$cmd" //c mklink //J "$winout\\current" "$(cygpath -aw "$package")" >/dev/null ||
    fail "making the junction"

wer_forget
"$powershell" -NoProfile -Command "New-ItemProperty '$wer_key' -Name '$wer_stale' -PropertyType DWord -Value 0 -Force" >/dev/null ||
    fail "listing a helper that is gone"

# The server's %TEMP% is GetTempPath's, which reads TMP first.
TMP=$winout $TMUX -fNUL new -d </dev/null || fail "new-session"
server=$($TMUX display-message -p '#{pid}' | tr -d '\r')
[ -n "$server" ] || fail "no server pid"
log=$OUT/tmux-crash-$server.log

wer_listed "$wer_helper" || fail "the helper is not listed for this user"
! wer_listed "$wer_stale" || fail "a helper that is gone stayed listed"

mkdir "$OUT/next"
"$cmd" //c rmdir "$winout\\current"
"$cmd" //c mklink //J "$winout\\current" "$winout\\next" >/dev/null ||
    fail "moving the junction"

"$powershell" -NoProfile -ExecutionPolicy Bypass \
    -File "$(cygpath -aw "$dir/win32-crash.ps1")" \
    -Id "$server" -Exe "$(cygpath -aw "$package/tmux.exe")" || fail "crashing the server"

log_done() {
	grep -q 'RtlUserThreadStart' "$log" 2>/dev/null
}
WAIT_TIMEOUT=30 wait_until log_done || fail "no finished crash log"

tr -d '\r' <"$log" | grep -q '^tmux crashed: exception 0xc0000005' ||
    fail "the log names no access violation"
tr -d '\r' <"$log" | grep -q '^  #[0-9]* xstrdup .*xmalloc\.c:[0-9]*$' ||
    fail "the log names no function, file and line"

# abort() and a bad C runtime argument raise no exception, and each still logs,
# and the next server reports how the last one ended (TMUX-40). The junction
# has moved on, so these run from the package.
TMUX="$package/tmux.exe -L$TEST_SOCKET"
gone() {
	! $TMUX list-sessions >/dev/null 2>&1
}
crash_with() {
	WAIT_TIMEOUT=30 wait_until gone || fail "the crashed server is still up"
	last=$server
	TMP=$winout $TMUX -fNUL new -d </dev/null || fail "new-session"
	server=$($TMUX display-message -p '#{pid}' | tr -d '\r')
	[ -n "$server" ] || fail "no server pid"
	tr -d '\r' <"$OUT/flight/ended/tmux-$last.log" | grep -q "^ended: *crashed: $3" ||
	    fail "the next server did not report how $last ended"
	log=$OUT/tmux-crash-$server.log
	"$powershell" -NoProfile -ExecutionPolicy Bypass \
	    -File "$(cygpath -aw "$dir/win32-crash.ps1")" -Id "$server" \
	    -Exe "$(cygpath -aw "$package/tmux.exe")" -Function "$1" ||
	    fail "crashing the server with $1"
	WAIT_TIMEOUT=30 wait_until log_done || fail "no finished crash log for $1"
	tr -d '\r' <"$log" | grep -q "^tmux crashed: $2" ||
	    fail "the log does not say $2"
}
crash_with abort abort 'exception 0xc0000005'
crash_with _invalid_parameter_noinfo 'invalid argument to a C runtime function' abort

# A fail-fast runs nothing in the process: Windows' error reporting loads
# tmux-wer.dll, which writes the log from outside (TMUX-150). This one starts
# through the junction, as a release's server does.
WAIT_TIMEOUT=30 wait_until gone || fail "the crashed server is still up"
"$cmd" //c rmdir "$winout\\current"
"$cmd" //c mklink //J "$winout\\current" "$(cygpath -aw "$package")" >/dev/null ||
    fail "moving the junction back"
TMUX="$OUT/current/tmux.exe -L$TEST_SOCKET"
fail_fast='exception 0xc0000409 (fail-fast code 2)'
crash_with __report_gsfailure "$fail_fast" 'invalid argument to a C runtime function'
tr -d '\r' <"$log" | grep -q '^  #[0-9]* __report_gsfailure' ||
    fail 'the fail-fast log names no function'
WAIT_TIMEOUT=30 wait_until gone || fail 'the failed server is still up'
TMP=$winout $TMUX -fNUL new -d </dev/null || fail 'new-session after the fail-fast'
tr -d '\r' <"$OUT/flight/ended/tmux-$server.log" | grep -q "^ended: *crashed: $fail_fast" ||
    fail 'the next server did not report the fail-fast'

echo PASS
exit 0
