# A slow terminal for win32-whole-sequences.sh: runs $Command in a pseudo-console
# from the conpty.dll beside tmux (OpenConsole beside it), as Rio and other
# terminals that ship it do, and writes everything the console sends to $Out.
# It reads 4 KB at a time, $DelayMs apart, so a large message takes a while to
# pass and the console's own writes have time to land in it. It answers the
# console's cursor position requests and size in pixels (CSI 14 t, for cells
# of 10x20), as a terminal does, answers tmux's
# at-protocol hello with $ReplyHex (the bytes of its own hello, in hex), and
# stops once $Out holds $Marker or after $Seconds.
param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$ConptyDll,
    [Parameter(Mandatory)][string]$Marker,
    [int]$DelayMs = 5,
    [int]$Seconds = 60,
    [string]$ReplyHex = ''
)
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class SlowTerminal {
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
        public int cb; public string r, d, t; public int x, y, xs, ys, xc, yc, fa, f; public short sw, r2; public IntPtr r3, i, o, e; }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO si; public IntPtr attr; }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr hp, ht; public int pid, tid; }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int CreateFn(COORD s, IntPtr i, IntPtr o, uint f, out IntPtr pc);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate void CloseFn(IntPtr pc);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryW(string p);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr m, string n);
    [DllImport("kernel32.dll")] static extern bool CreatePipe(out IntPtr r, out IntPtr w, IntPtr a, int s);
    [DllImport("kernel32.dll")] static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr s);
    [DllImport("kernel32.dll")] static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr a, IntPtr v, IntPtr s, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string a, string c, IntPtr pa, IntPtr ta, bool ih, uint f, IntPtr env, string dir, ref STARTUPINFOEX si, out PI pi);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint c);
    public static void Run(string cmd, string outPath, string dll, string marker, int delayMs, int seconds, string replyHex) {
        var reply = new byte[replyHex.Length / 2];
        for (int k = 0; k < reply.Length; k++) reply[k] = Convert.ToByte(replyHex.Substring(k * 2, 2), 16);
        var replied = reply.Length == 0;
        IntPtr inR, inW, outR, outW, pc;
        CreatePipe(out inR, out inW, IntPtr.Zero, 0);
        CreatePipe(out outR, out outW, IntPtr.Zero, 0);
        var m = LoadLibraryW(dll);
        if (m == IntPtr.Zero) throw new Exception("can't load " + dll + ": " + Marshal.GetLastWin32Error());
        var create = Marshal.GetDelegateForFunctionPointer<CreateFn>(GetProcAddress(m, "ConptyCreatePseudoConsole"));
        var close = Marshal.GetDelegateForFunctionPointer<CloseFn>(GetProcAddress(m, "ConptyClosePseudoConsole"));
        int hr = create(new COORD { X = 80, Y = 24 }, inR, outW, 0, out pc);
        if (hr != 0) throw new Exception("ConptyCreatePseudoConsole " + hr);
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        var list = Marshal.AllocHGlobal(size);
        InitializeProcThreadAttributeList(list, 1, 0, ref size);
        UpdateProcThreadAttribute(list, 0, (IntPtr)0x20016, pc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);
        var si = new STARTUPINFOEX();
        si.si.cb = Marshal.SizeOf(si);
        // No standard handles but the pseudo-console's, whatever this
        // process was given.
        si.si.f = 0x100;
        si.attr = list;
        PI pi;
        if (!CreateProcessW(null, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, null, ref si, out pi))
            throw new Exception("CreateProcess: " + Marshal.GetLastWin32Error());
        var output = new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(outR, true), FileAccess.Read);
        var input = new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(inW, true), FileAccess.Write);
        var file = new FileStream(outPath, FileMode.Create, FileAccess.Write);
        var done = new ManualResetEvent(false);
        var reader = new Thread(() => {
            var b = new byte[4096];
            var tail = "";
            try {
                int n;
                while ((n = output.Read(b, 0, b.Length)) > 0) {
                    file.Write(b, 0, n);
                    file.Flush();
                    tail += Encoding.ASCII.GetString(b, 0, n);
                    int at;
                    while ((at = tail.IndexOf("\u001b[6n")) >= 0) {
                        tail = tail.Substring(at + 4);
                        var cpr = Encoding.ASCII.GetBytes("\u001b[1;1R");
                        input.Write(cpr, 0, cpr.Length);
                        input.Flush();
                    }
                    // The window's size in pixels, 10x20 cells, which tmux
                    // asks to place images.
                    while ((at = tail.IndexOf("\u001b[14t")) >= 0) {
                        tail = tail.Substring(at + 5);
                        var px = Encoding.ASCII.GetBytes("\u001b[4;480;800t");
                        input.Write(px, 0, px.Length);
                        input.Flush();
                    }
                    // tmux's hello, answered with $ReplyHex once.
                    if (!replied && tail.Contains("\u001b_at;")) {
                        replied = true;
                        input.Write(reply, 0, reply.Length);
                        input.Flush();
                    }
                    if (tail.Contains(marker)) done.Set();
                    if (tail.Length > 64) tail = tail.Substring(tail.Length - 64);
                    Thread.Sleep(delayMs);
                }
            } catch (Exception) { }
            done.Set();
        });
        reader.IsBackground = true;
        reader.Start();
        done.WaitOne(seconds * 1000);
        TerminateProcess(pi.hp, 0);
        close(pc);
        reader.Join(2000);
        file.Close();
    }
}
'@
[SlowTerminal]::Run($Command, $Out, $ConptyDll, $Marker, $DelayMs, $Seconds, $ReplyHex)
