param(
    [string]$Port = "COM9",
    [Parameter(Mandatory = $true)]
    [string]$Source
)

$ErrorActionPreference = "Stop"
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Source))
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

function Read-Available([int]$SettleMs = 150) {
    Start-Sleep -Milliseconds $SettleMs
    $text = ""
    while ($serial.BytesToRead -gt 0) {
        $text += $serial.ReadExisting()
        Start-Sleep -Milliseconds 30
    }
    return $text
}

function Send-Line([string]$Line, [int]$SettleMs = 150) {
    $data = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r")
    foreach ($value in $data) {
        $serial.Write([byte[]]@($value), 0, 1)
        Start-Sleep -Milliseconds 2
    }
    return Read-Available $SettleMs
}

try {
    $serial.Open()
    $serial.DiscardInBuffer()
    $serial.Write([byte[]]@(3), 0, 1)
    Start-Sleep -Milliseconds 300
    $serial.DiscardInBuffer()
    $initial = Send-Line "" 400
    if ($initial) { Write-Host -NoNewline $initial }

    $temporary = "/tmp/armctl.new"
    Write-Host -NoNewline (Send-Line ": > $temporary")

    for ($offset = 0; $offset -lt $bytes.Length; $offset += 48) {
        $count = [Math]::Min(48, $bytes.Length - $offset)
        $payload = ""
        for ($i = 0; $i -lt $count; $i++) {
            $octal = [Convert]::ToString($bytes[$offset + $i], 8).PadLeft(3, '0')
            $payload += "\$octal"
        }
        $out = Send-Line "printf '$payload' >> $temporary" 80
        if ($out -match "not found|syntax error") {
            throw "Target shell rejected a transfer command: $out"
        }
    }

    $verifyCommand = 'test "$(wc -c < ' + $temporary + ')" -eq ' + $bytes.Length + ' && echo ARMCTL_SIZE_OK || echo ARMCTL_SIZE_BAD'
    $verify = Send-Line $verifyCommand 300
    Write-Host -NoNewline $verify
    if ($verify -notmatch "ARMCTL_SIZE_OK") {
        throw "Target file size verification failed"
    }

    $install = Send-Line "if cp $temporary /usr/bin/armctl 2>/dev/null; then chmod 755 /usr/bin/armctl; echo ARMCTL_INSTALLED:/usr/bin/armctl; else cp $temporary /tmp/armctl; chmod 755 /tmp/armctl; echo ARMCTL_INSTALLED:/tmp/armctl; fi" 500
    Write-Host -NoNewline $install
    if ($install -notmatch "ARMCTL_INSTALLED:") {
        throw "armctl installation did not report success"
    }

    $help = Send-Line "armctl --help" 500
    Write-Host -NoNewline $help
    if ($help -notmatch "armctl x forward") {
        throw "Installed armctl did not pass its help test"
    }

    Write-Host "`nARMCTL_INSTALL_COMPLETE"
}
finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
