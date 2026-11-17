# Open tty channels to a server that no client will claim, as a client that
# ends before the server accepts its channel leaves one: each goes through
# the discovery pipe for a port and a nonce, then sends "TTY:<token>:<nonce>".
param(
    [Parameter(Mandatory)][string]$Label,
    [int]$Count = 1
)
$ErrorActionPreference = 'Stop'
$sockets = @()
for ($i = 0; $i -lt $Count; $i++) {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Label,
        [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $buf = New-Object byte[] 128
    $n = $pipe.Read($buf, 0, $buf.Length)
    $pipe.Dispose()
    $port, $nonce = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim().Split(':', 2)

    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect('127.0.0.1', [int]$port)
    $token = -join (1..32 | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
    $line = [Text.Encoding]::ASCII.GetBytes("TTY:${token}:${nonce}`n")
    $tcp.GetStream().Write($line, 0, $line.Length)
    $sockets += $tcp
}
# Closing sends the line ahead of the end, so the server still reads it.
$sockets | ForEach-Object { $_.Dispose() }
