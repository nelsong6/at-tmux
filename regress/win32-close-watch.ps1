# Stands in for a program in a pane: records each console control event it
# gets in a file, then returns from its handler after -Hang seconds, so a
# program that takes too long to close can be imitated.
param([Parameter(Mandatory)][string]$Mark, [int]$Hang = 0)

Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class CloseWatch {
	public delegate bool Handler(uint ev);

	[DllImport("kernel32.dll")]
	static extern bool SetConsoleCtrlHandler(Handler h, bool add);

	static Handler keep;
	static string mark;
	static int hang;

	public static void Start(string m, int h) {
		mark = m;
		hang = h;
		keep = On;
		SetConsoleCtrlHandler(keep, true);
	}

	static bool On(uint ev) {
		File.AppendAllText(mark, "event " + ev + "\n");
		Thread.Sleep(hang * 1000);
		File.AppendAllText(mark, "handled\n");
		return true;
	}
}
"@
[CloseWatch]::Start($Mark, $Hang)
"watching"
while ($true) { Start-Sleep -Milliseconds 200 }
