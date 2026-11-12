# A picker for display-palette -R's tests, in place of fzt. It saves the rows
# it is given to Dir/rows and says it is reading keys with Dir/ready, then
# appends each key its console gives it to Dir/keys, a line each: Down, Up,
# Enter, or the key's virtual key number. Enter prints the id of the first row
# named in Dir/pick and exits.
param(
    [Parameter(Mandatory)][string]$Dir
)
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

$rows = [Console]::In.ReadToEnd()
[IO.File]::WriteAllText("$Dir/rows", $rows, $utf8)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PaletteKeys {
    public static class Con {
        [StructLayout(LayoutKind.Explicit, Size = 20)]
        struct Record {
            [FieldOffset(0)] public ushort EventType;
            [FieldOffset(4)] public int KeyDown;
            [FieldOffset(10)] public ushort VirtualKey;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFile(string name, uint access, uint share,
            IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", EntryPoint = "ReadConsoleInputW", SetLastError = true)]
        static extern bool ReadConsoleInput(IntPtr h, [Out] Record[] records, uint n, out uint read);
        static IntPtr conin = IntPtr.Zero;
        public static void Open() {
            conin = CreateFile("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        }
        // The virtual key number of the next key pressed, or -1.
        public static int Next() {
            Record[] r = new Record[1];
            uint read;
            for (;;) {
                if (!ReadConsoleInput(conin, r, 1, out read))
                    return -1;
                if (read == 1 && r[0].EventType == 1 && r[0].KeyDown != 0)
                    return r[0].VirtualKey;
            }
        }
    }
}
'@

# Standard input is the rows, so the keys are read from the console itself.
[PaletteKeys.Con]::Open()
[IO.File]::WriteAllText("$Dir/ready", '')
while ($true) {
    $vk = [PaletteKeys.Con]::Next()
    if ($vk -lt 0) { exit 1 }
    $name = switch ($vk) {
        0x28 { 'Down' }
        0x26 { 'Up' }
        0x0D { 'Enter' }
        default { "$vk" }
    }
    [IO.File]::AppendAllText("$Dir/keys", "$name`n", $utf8)
    if ($name -ne 'Enter') { continue }
    $pick = [IO.File]::ReadAllText("$Dir/pick", $utf8).Trim()
    foreach ($row in $rows -split "`n") {
        $depth, $rname, $desc, $hint, $id, $tags = $row -split "`t"
        if ($rname -eq $pick) {
            [Console]::Out.Write($id.Trim() + "`n")
            break
        }
    }
    exit 0
}
