param(
    [string]$Port = "COM9",
    [Parameter(Mandatory = $true)]
    [string]$Line,
    [int]$CharacterDelayMs = 12,
    [int]$WaitMs = 5000
)

$ErrorActionPreference = "Stop"
$serial = [System.IO.Ports.SerialPort]::new(
    $Port,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.ReadTimeout = 200
$serial.WriteTimeout = 2000
$serial.DtrEnable = $false
$serial.RtsEnable = $false

try {
    $serial.Open()

    # Cancel any partial command left by a previous burst, then request a
    # clean PMON/Linux prompt before sending the requested line.
    $serial.Write([byte[]]@(3, 13), 0, 2)
    Start-Sleep -Milliseconds 400
    if ($serial.BytesToRead -gt 0) {
        Write-Host -NoNewline $serial.ReadExisting()
    }

    $data = [System.Text.Encoding]::ASCII.GetBytes($Line)
    foreach ($value in $data) {
        $serial.Write([byte[]]@($value), 0, 1)
        Start-Sleep -Milliseconds $CharacterDelayMs
    }
    $serial.Write([byte[]]@(13), 0, 1)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMs)
    do {
        Start-Sleep -Milliseconds 100
        if ($serial.BytesToRead -gt 0) {
            Write-Host -NoNewline $serial.ReadExisting()
        }
    } while ([DateTime]::UtcNow -lt $deadline)
}
finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
