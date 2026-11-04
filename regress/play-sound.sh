#!/bin/sh

# play-sound runs the platform's player from the server, without waiting, and a
# new sound stops the one playing. Windows has its own check in win32-caller.sh.

TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest-play-sound"
$TMUX kill-server 2>/dev/null

DIR=$(mktemp -d)
trap '$TMUX kill-server 2>/dev/null; rm -rf "$DIR"' 0 1 15
mkdir "$DIR/bin" "$DIR/empty"
: >"$DIR/one.wav"
: >"$DIR/two.wav"

case $(uname) in
Darwin) player=afplay ;;
*) player=pw-play ;;
esac
cat >"$DIR/bin/$player" <<SCRIPT
#!/bin/sh
trap 'echo "stopped \$1" >>"$DIR/played"; exit 0' TERM
echo "started \$1" >>"$DIR/played"
case \$1 in
*one.wav) sleep 10 & wait ;;
esac
SCRIPT
chmod +x "$DIR/bin/$player"

fail() {
	echo "play-sound: $1" >&2
	exit 1
}

wait_for() {
	i=0
	while [ $i -lt 50 ]; do
		grep -q "$1" "$DIR/played" 2>/dev/null && return 0
		i=$((i + 1))
		sleep 0.1
	done
	fail "never saw \"$1\" in: $(cat "$DIR/played" 2>/dev/null)"
}

$TMUX -f/dev/null new -d -x 80 -y 24 || exit 1
$TMUX set-environment -g PATH "$DIR/bin:/bin:/usr/bin"

out=$($TMUX play-sound "$DIR/missing.wav" 2>&1) && fail "a missing file succeeded"
echo "$out" | grep -q "can't read" || fail "wrong error: $out"

$TMUX play-sound "$DIR/one.wav" || fail "the first sound failed"
wait_for "started $DIR/one.wav"
$TMUX play-sound "$DIR/two.wav" || fail "the second sound failed"
wait_for "stopped $DIR/one.wav"
wait_for "started $DIR/two.wav"

$TMUX set-environment -g PATH "$DIR/empty"
out=$($TMUX play-sound "$DIR/two.wav" 2>&1) && fail "no player succeeded"
echo "$out" | grep -q "no sound player" || fail "wrong error: $out"

exit 0
