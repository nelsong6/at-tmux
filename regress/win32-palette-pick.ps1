# A picker for display-palette's tests, in place of fzt. It saves the rows it
# is given to Dir/rows, then follows Dir/pick, lines of name=value (UTF-8, so
# non-ASCII text survives): it prints the id of the first row named pick
# (under the top-level row named under, when given), with a tab and text when
# text is given, and exits with status. Dir/done appears as it exits. With
# stderr given, it saves its standard error handle's kind to Dir/stderr
# (console, invalid, or another type) and writes the text there first.
param(
    [Parameter(Mandatory)][string]$Dir
)
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

$rows = [Console]::In.ReadToEnd()
[IO.File]::WriteAllText("$Dir/rows", $rows, $utf8)

$spec = @{ status = '0' }
foreach ($line in [IO.File]::ReadAllLines("$Dir/pick", $utf8)) {
    $key, $value = $line -split '=', 2
    $spec[$key] = $value
}

if ($spec.ContainsKey('stderr')) {
    Add-Type -Namespace PalettePick -Name Std -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern uint GetFileType(IntPtr h);
'@
    $h = [PalettePick.Std]::GetStdHandle(-12)
    $kind = if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]-1) { 'invalid' }
        elseif ([PalettePick.Std]::GetFileType($h) -eq 2) { 'console' } else { 'other' }
    [IO.File]::WriteAllText("$Dir/stderr", $kind, $utf8)
    [Console]::Error.WriteLine($spec.stderr)
}

$parent = $null
foreach ($row in $rows -split "`n") {
    $depth, $name, $desc, $hint, $id, $tags = $row -split "`t"
    if ($depth -eq '0') { $parent = $name }
    if ($name -ne $spec.pick) { continue }
    if ($spec.under -and ($depth -eq '0' -or $parent -ne $spec.under)) { continue }
    $out = $id.Trim()
    if ($spec.ContainsKey('text')) { $out += "`t$($spec.text)" }
    [Console]::Out.Write($out + "`n")
    break
}
[IO.File]::WriteAllText("$Dir/done", '')
exit [int]$spec.status
