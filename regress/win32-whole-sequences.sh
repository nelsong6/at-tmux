#!/bin/sh

# A picture tmux sends a terminal in at-protocol reaches it whole (TMUX-240).
#
# - The client's console is a pseudoconsole, which writes to the terminal
#   itself between the client's writes: a cursor position request (ESC [ 6 n)
#   when the size poll asks for the console's size and it thinks its cursor may
#   be wrong. Inside a message, that ESC ended it in the terminal, which dropped
#   it and showed the rest as text. The client now writes each sequence whole.
# - A terminal that can't keep up has tmux discard its output until it can.
#   A message cut off by that, or discarded with the picture counted as sent,
#   was never drawn. Now one is sent whole or not at all, and again later.
#
# The client runs in win32-slow-terminal.ps1, a terminal on the shipped
# conpty.dll that reads slowly and speaks at-protocol, and a pane places a
# 200x200 picture. Every at-protocol message the terminal gets must be whole,
# ended by its ST right after its base64, and the picture among them.

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
. "$(dirname "$0")/win32-test.sh"
TEST_TMUX=$(cd "$(dirname "$TEST_TMUX")" && pwd)/$(basename "$TEST_TMUX")
TMUX="$TEST_TMUX -L$TEST_SOCKET"
. "$(dirname "$0")/win32-wait.sh"
$TMUX kill-server 2>/dev/null
wait_gone

CONPTY=$(dirname "$TEST_TMUX")/conpty.dll
SLOW=$(cygpath -w "$(cd "$(dirname "$0")" && pwd)/win32-slow-terminal.ps1")
[ -f "$CONPTY" ] || { echo "FAIL: no conpty.dll beside $TEST_TMUX"; exit 1; }

OUT=$(mktemp -d)
remove() { rm -rf "$OUT" 2>/dev/null; [ ! -e "$OUT" ]; }
trap '$TMUX kill-server 2>/dev/null; cd /; wait_until remove' 0 1 15
cd "$OUT" || exit 1
ESC=$(printf '\033')

fail() {
	echo "FAIL: $*"
	echo "--- the at-protocol messages the terminal got (base64 length, then what follows):"
	LC_ALL=C grep -a -o "${ESC}_at;[A-Za-z0-9+/=]*.\{0,12\}" got.bin 2>/dev/null |
	    awk '{ print length($0) - 17, substr($0, length($0) - 11) }' | cat -v
	exit 1
}

printf 'set -g default-shell "%s"\nset -g status off\n' "$(cygpath -m "$POWERSHELL_EXE")" >test.conf
$TMUX -f test.conf new -d -x80 -y24 </dev/null || exit 1

# The terminal's hello: this build's at-protocol version, as hex.
V=$($TMUX display -p '#{at_protocol_version}' | tr -d '\r')
[ -n "$V" ] || fail "no at_protocol_version"
HELLO=$(printf '\033_at;%s\033\\' "$(printf '\001%s%s' "$(printf "\\$(printf '%03o' ${#V})")" "$V" | base64 -w0)" |
    od -An -tx1 | tr -d ' \n')

# The pane's program: a 200x200 picture as a kitty virtual placement over 10x5
# cells, sent in 4096-character chunks as programs do, a placeholder for its
# first cell, then a marker as text.
cat >send.ps1 <<'EOF'
$e = [char]27
$px = New-Object byte[] (200 * 200 * 4)
(New-Object Random 7).NextBytes($px)
$data = [Convert]::ToBase64String($px)
$out = [Console]::OpenStandardOutput()
function Send([string]$s) {
    $b = [Text.Encoding]::UTF8.GetBytes($s)
    $out.Write($b, 0, $b.Length)
    $out.Flush()
}
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$n = [Math]::Ceiling($data.Length / 4096)
for ($i = 0; $i -lt $n; $i++) {
    $chunk = $data.Substring($i * 4096, [Math]::Min(4096, $data.Length - $i * 4096))
    $m = if ($i -lt $n - 1) { 1 } else { 0 }
    if ($i -eq 0) {
        Send ("$($e)_Ga=T,U=1,f=32,s=200,v=200,i=5,c=10,r=5,q=2,m=$m;$chunk$($e)\")
    } else {
        Send ("$($e)_Gm=$m;$chunk$($e)\")
    }
}
$cell = [char]::ConvertFromUtf32(0x10EEEE) + [char]0x0305 + [char]0x0305
Send ("$e[3;3H$e[38;2;0;0;5m$cell$e[0m$e[10;1HWHOLE-DONE")
Start-Sleep -Seconds 120
EOF
# Once the client is attached, the pane runs it.
(
	attached() { [ -n "$($TMUX list-clients 2>/dev/null)" ]; }
	WAIT_TIMEOUT=30 wait_until attached &&
	    $TMUX respawn-pane -k "& '$(cygpath -m "$POWERSHELL_EXE")' -NoProfile -ExecutionPolicy Bypass -File '$(cygpath -w "$OUT/send.ps1")'"
) &
"$POWERSHELL_EXE" -NoProfile -ExecutionPolicy Bypass -File "$SLOW" \
    -Command "\"$(cygpath -w "$TEST_TMUX")\" -L$TEST_SOCKET attach" \
    -Out "$(cygpath -w "$OUT/got.bin")" -ConptyDll "$(cygpath -w "$CONPTY")" \
    -Marker WHOLE-DONE -ReplyHex "$HELLO" -Seconds 60 || fail "the slow terminal didn't run"
wait

LC_ALL=C grep -a -q WHOLE-DONE got.bin || fail "the marker never arrived"
# A message is whole when its base64 runs straight into its ST.
all=$(LC_ALL=C grep -a -o "${ESC}_at;" got.bin | wc -l)
whole=$(LC_ALL=C grep -a -o "${ESC}_at;[A-Za-z0-9+/=]*${ESC}\\\\" got.bin | wc -l)
[ "$all" -eq "$whole" ] || fail "$whole of $all at-protocol messages arrived whole"
# The picture: 160000 bytes of pixels are over 213000 base64 characters.
big=$(LC_ALL=C grep -a -o "${ESC}_at;[A-Za-z0-9+/=]*${ESC}\\\\" got.bin | awk 'length($0) > 213000' | wc -l)
[ "$big" -ge 1 ] || fail "the picture never arrived"
exit 0
