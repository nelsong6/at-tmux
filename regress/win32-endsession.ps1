# Say to the tmux server PID what Windows says when the session ends, through the
# hidden window it keeps for that, for regress/win32-flight.sh. -Cancelled is the
# shutdown that was called off; -Installer is Restart Manager closing the program.
param([int]$Id, [switch]$Cancelled, [switch]$Installer)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EndSession {
    public delegate bool Found(IntPtr window, IntPtr arg);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Found found, IntPtr arg);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int size);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
}
'@

$script:window = [IntPtr]::Zero
[void][EndSession]::EnumWindows({
    param($hwnd, $arg)
    $pid2 = [uint32]0
    [void][EndSession]::GetWindowThreadProcessId($hwnd, [ref]$pid2)
    $name = New-Object System.Text.StringBuilder 64
    [void][EndSession]::GetClassName($hwnd, $name, 64)
    if ($pid2 -eq $Id -and $name.ToString() -eq 'tmux-flight') {
        $script:window = $hwnd
        return $false
    }
    return $true
}, [IntPtr]::Zero)
if ($script:window -eq [IntPtr]::Zero) {
    Write-Error "server $Id has no tmux-flight window"
    exit 1
}

$WM_QUERYENDSESSION = 0x11
$WM_ENDSESSION = 0x16
$ENDSESSION_CLOSEAPP = 1
$lparam = if ($Installer) { [IntPtr]$ENDSESSION_CLOSEAPP } else { [IntPtr]::Zero }
$willing = [EndSession]::SendMessage($script:window, $WM_QUERYENDSESSION, [IntPtr]::Zero, $lparam)
if ($willing -eq [IntPtr]::Zero) {
    Write-Error "server $Id refused to let the session end"
    exit 1
}
$ending = if ($Cancelled) { [IntPtr]::Zero } else { [IntPtr]1 }
[void][EndSession]::SendMessage($script:window, $WM_ENDSESSION, $ending, $lparam)
