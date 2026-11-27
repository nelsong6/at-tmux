# Runs in a pane for win32-placed-images.sh and win32-spare-space.sh: reads
# commands appended to a file, one a line, and writes what each says to the
# pane, so the test drives the pane's program without a shell's prompt in the
# way. Rows and columns are 1-based, except spare's row.
#
#   place ID ROW COL COLSxROWS   kitty a=T of a 20x20 red square, C=1
#   chunked ID ROW COL           the same in three chunks (m=1)
#   query ID                     kitty a=q that tmux can take
#   badquery ID                  kitty a=q of a PNG, which it can't
#   delete ID                    kitty a=d,d=i
#   text ROW COL TEXT            the text there
#   clearline ROW                erase the whole row (EL 2)
#   cls                          erase the screen (ED 2)
#   sixel ROW COL                a sixel image (DCS q), not a placed one
#   scroll                       a newline on the last row
#   sync ROW COL TEXT            the text inside a synchronized update
#   virtual ID COLSxROWS         kitty a=T with U=1: a virtual placement
#   holder ID ROW COL IR IC      a placeholder at ROW COL for image cell
#                                row IR, column IC (0-based) of image ID
#   spare ROW|none               at-protocol spare-space above pane row
#                                ROW (0-based), or none (ATT-37)
param([Parameter(Mandatory)][string]$Commands)

# The first of kitty's row/column diacritics.
$diacritics = @(0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F)

$e = [char]27
$st = "$e\"
# The console passes bytes on as its output code page says: UTF-8, so a
# placeholder's bytes reach tmux as written.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$out = [Console]::OpenStandardOutput()
function Send([string]$s) {
    $b = [Text.Encoding]::UTF8.GetBytes($s)
    $out.Write($b, 0, $b.Length)
    $out.Flush()
}

$pixels = New-Object byte[] (20 * 20 * 4)
for ($i = 0; $i -lt $pixels.Length; $i += 4) {
    $pixels[$i] = 220; $pixels[$i + 1] = 30; $pixels[$i + 2] = 30; $pixels[$i + 3] = 255
}
$data = [Convert]::ToBase64String($pixels)

$done = 0
while ($true) {
    if (Test-Path $Commands) {
        $lines = @(Get-Content $Commands)
        for (; $done -lt $lines.Count; $done++) {
            $a = $lines[$done].Split(' ')
            switch ($a[0]) {
                'place' {
                    $cells = $a[4].Split('x')
                    Send ("$e[$($a[2]);$($a[3])H$($e)_Ga=T,f=32,s=20,v=20,i=$($a[1]),c=$($cells[0]),r=$($cells[1]),C=1,q=2;$data$st")
                }
                'chunked' {
                    $third = [int]($data.Length / 3 / 4) * 4
                    Send ("$e[$($a[2]);$($a[3])H$($e)_Ga=T,f=32,s=20,v=20,i=$($a[1]),c=2,r=1,C=1,q=2,m=1;$($data.Substring(0, $third))$st")
                    Send ("$($e)_Gm=1;$($data.Substring($third, $third))$st")
                    Send ("$($e)_Gm=0;$($data.Substring(2 * $third))$st")
                }
                'query' { Send ("$($e)_Ga=q,i=$($a[1]),s=1,v=1,f=24;AAAA$st") }
                'badquery' { Send ("$($e)_Ga=q,i=$($a[1]),s=1,v=1,f=100;AAAA$st") }
                'delete' { Send ("$($e)_Ga=d,d=i,i=$($a[1])$st") }
                'text' { Send ("$e[$($a[1]);$($a[2])H" + ($a[3..($a.Count - 1)] -join ' ')) }
                'clearline' { Send ("$e[$($a[1]);1H$e[2K") }
                'cls' { Send ("$e[2J") }
                'sixel' { Send ("$e[$($a[1]);$($a[2])H$($e)Pq#1;2;0;100;0#1!20~-!20~-!20~-!20~$st") }
                'scroll' { Send ("$e[999;1H`n") }
                'sync' { Send ("$e[?2026h$e[$($a[1]);$($a[2])H" + ($a[3..($a.Count - 1)] -join ' ') + "$e[?2026l") }
                'virtual' {
                    $cells = $a[2].Split('x')
                    Send ("$($e)_Ga=T,U=1,f=32,s=20,v=20,i=$($a[1]),c=$($cells[0]),r=$($cells[1]),q=2;$data$st")
                }
                'spare' {
                    $row = if ($a[1] -eq 'none') { [uint32]::MaxValue } else { [uint32]$a[1] }
                    $msg = [byte[]](@([byte]5) + [BitConverter]::GetBytes($row))
                    Send ("$($e)_at;$([Convert]::ToBase64String($msg))$st")
                }
                'holder' {
                    $id = [int]$a[1]
                    $fg = "$e[38;2;$(($id -shr 16) -band 255);$(($id -shr 8) -band 255);$($id -band 255)m"
                    $cell = [char]::ConvertFromUtf32(0x10EEEE) + [char]$diacritics[[int]$a[4]] + [char]$diacritics[[int]$a[5]]
                    Send ("$e[$($a[2]);$($a[3])H$fg$cell$e[0m")
                }
            }
        }
    }
    Start-Sleep -Milliseconds 50
}
