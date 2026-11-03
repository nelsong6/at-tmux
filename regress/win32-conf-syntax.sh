#!/bin/sh

# Parse the upstream fixtures without executing their commands or plugins.
PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
. "$(dirname "$0")/win32-wait.sh"
TMUX="timeout --foreground --kill-after=1 $WAIT_TIMEOUT $TEST_TMUX -L$TEST_SOCKET"
trap "$TMUX kill-server 2>/dev/null" 0 1 15

COUNT=0
for i in regress/conf/*.conf; do
	BASENAME=$(basename "$i")
	echo "Parsing $BASENAME"
	ERR=$($TMUX -fNUL start \; source-file -n "$(cygpath -ma "$i")" </dev/null 2>&1)
	RC=$?
	if [ $RC -ne 0 ]; then
		echo "FAIL: $BASENAME (parse exited $RC: $ERR)"
		exit 1
	fi
	$TMUX kill-server 2>/dev/null
	wait_gone || { echo "FAIL: $BASENAME (server did not exit)"; exit 1; }
	COUNT=$((COUNT + 1))
done

echo "ALL $COUNT CONFIG SYNTAX TESTS PASSED"
