# Suspend a process, or resume it, as a stand-in for a hung console.
param(
    [Parameter(Mandatory)][int]$Id,
    [switch]$Suspend
)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Proc {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
}
'@
$p = Get-Process -Id $Id
if ($Suspend) { [void][Proc]::NtSuspendProcess($p.Handle) } else { [void][Proc]::NtResumeProcess($p.Handle) }
