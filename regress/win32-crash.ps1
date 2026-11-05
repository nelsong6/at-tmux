# Make the tmux server PID fault inside one of its own functions, for
# regress/win32-crash-log.sh: a new thread runs xstrdup on a bad pointer. Exe is
# a tmux.exe of the same build, with its PDB beside it, where this finds the
# function; the server's crash handler has to find the PDB by itself.
param([int]$Id, [string]$Exe)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Crash {
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateRemoteThread(IntPtr proc, IntPtr attrs, UIntPtr stack, IntPtr start, IntPtr param, uint flags, IntPtr id);
    [DllImport("dbghelp.dll", SetLastError = true)] public static extern bool SymInitialize(IntPtr proc, string path, bool invade);
    [DllImport("dbghelp.dll", SetLastError = true)] public static extern ulong SymLoadModuleEx(IntPtr proc, IntPtr file, string image, string module, ulong dllBase, uint size, IntPtr data, uint flags);
    [DllImport("dbghelp.dll", SetLastError = true)] public static extern bool SymFromName(IntPtr proc, string name, byte[] symbol);
}
'@

$me = [Crash]::GetCurrentProcess()
if (-not [Crash]::SymInitialize($me, (Split-Path $Exe), $false)) { throw 'SymInitialize failed' }
$base = [Crash]::SymLoadModuleEx($me, [IntPtr]::Zero, $Exe, $null, 0, 0, [IntPtr]::Zero, 0)
if ($base -eq 0) { throw 'SymLoadModuleEx failed' }

# SYMBOL_INFO: SizeOfStruct at 0, Address at 56, Name at 84.
$symbol = New-Object byte[] 512
[BitConverter]::GetBytes([uint32]88).CopyTo($symbol, 0)
$symbol[80] = 64
if (-not [Crash]::SymFromName($me, 'xstrdup', $symbol)) { throw 'no xstrdup in the PDB' }
$rva = [BitConverter]::ToUInt64($symbol, 56) - $base

$start = [IntPtr]([Int64](Get-Process -Id $Id).MainModule.BaseAddress + [Int64]$rva)
$proc = [Crash]::OpenProcess(0x43A, $false, $Id)
if ($proc -eq [IntPtr]::Zero) { throw 'OpenProcess failed' }
if ([Crash]::CreateRemoteThread($proc, [IntPtr]::Zero, [UIntPtr]::Zero, $start, [IntPtr]1, 0, [IntPtr]::Zero) -eq [IntPtr]::Zero) { throw 'CreateRemoteThread failed' }
