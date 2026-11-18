# Connect to a server as a client that never identifies itself, as every
# client is between connecting and its identify messages: it goes through the
# discovery pipe for a port and a nonce, sends the nonce and then nothing.
# Writes "connected" to the file Ready once it has sent the nonce, and
# holds the connection until the file Release exists (60 seconds at most).
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Ready,
    [Parameter(Mandatory)][string]$Release
)
$ErrorActionPreference = 'Stop'
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Label,
    [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(5000)
$buf = New-Object byte[] 128
$n = $pipe.Read($buf, 0, $buf.Length)
$pipe.Dispose()
$port, $nonce = [Text.Encoding]::ASCII.GetString($buf, 0, $n).Trim().Split(':', 2)

$tcp = New-Object System.Net.Sockets.TcpClient
$tcp.Connect('127.0.0.1', [int]$port)
$line = [Text.Encoding]::ASCII.GetBytes("${nonce}`n")
$tcp.GetStream().Write($line, 0, $line.Length)
Set-Content -LiteralPath $Ready -Value connected

$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path -LiteralPath $Release) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
}
$tcp.Dispose()
