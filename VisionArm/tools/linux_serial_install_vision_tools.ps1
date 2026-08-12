param(
    [string]$Port = "COM9",
    [int]$CharacterDelayMs = 12
)

$ErrorActionPreference = "Stop"
$workspace = Split-Path -Parent $PSScriptRoot
$files = @(
    @{ Source = Join-Path $workspace "linux_armctl\armctl"; Name = "armctl"; AppName = "arm" },
    @{ Source = Join-Path $workspace "linux_camctl\camctl"; Name = "camctl"; AppName = "cam" }
)

$serial = [System.IO.Ports.SerialPort]::new(
    $Port,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)
$serial.Handshake = [System.IO.Ports.Handshake]::None
$serial.ReadTimeout = 200
$serial.WriteTimeout = 3000
$serial.DtrEnable = $false
$serial.RtsEnable = $false

function Read-Available([int]$SettleMs = 150) {
    Start-Sleep -Milliseconds $SettleMs
    $text = ""
    while ($serial.BytesToRead -gt 0) {
        $text += $serial.ReadExisting()
        Start-Sleep -Milliseconds 25
    }
    return $text
}

function Send-Line([string]$Line, [int]$SettleMs = 150) {
    $data = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r")
    foreach ($value in $data) {
        $serial.Write([byte[]]@($value), 0, 1)
        # The FPGA UART receive path is deliberately paced. Sending faster can
        # trigger ttyS0 input overruns and silently corrupt an upload.
        Start-Sleep -Milliseconds $CharacterDelayMs
    }
    return Read-Available $SettleMs
}

function Install-File([string]$Source, [string]$Name, [string]$AppName) {
    $resolved = (Resolve-Path -LiteralPath $Source).Path
    $bytes = [System.IO.File]::ReadAllBytes($resolved)
    $temporary = "/tmp/$Name.new"

    Write-Host "Installing $Name ($($bytes.Length) bytes)..."
    Write-Host -NoNewline (Send-Line ": > $temporary")

    $chunkSize = 32
    $lastPercent = -1
    for ($offset = 0; $offset -lt $bytes.Length; $offset += $chunkSize) {
        $count = [Math]::Min($chunkSize, $bytes.Length - $offset)
        $payload = ""
        for ($i = 0; $i -lt $count; $i++) {
            $octal = [Convert]::ToString($bytes[$offset + $i], 8).PadLeft(3, '0')
            $payload += "\$octal"
        }
        $out = Send-Line "printf '$payload' >> $temporary" 100
        if ($out -match "not found|syntax error") {
            throw "Target shell rejected a transfer command for ${Name}: $out"
        }

        $done = [Math]::Min($offset + $count, $bytes.Length)
        $percent = [int][Math]::Floor(($done * 100.0) / $bytes.Length)
        if ($percent -ge ($lastPercent + 10) -or $percent -eq 100) {
            Write-Host ("  {0,3}% ({1}/{2} bytes)" -f $percent, $done, $bytes.Length)
            $lastPercent = $percent
        }
    }

    $verifyCommand = 'test "$(wc -c < ' + $temporary + ')" -eq ' + $bytes.Length + ' && echo SIZE_OK || echo SIZE_BAD'
    $verify = Send-Line $verifyCommand 1000
    if ($verify -notmatch "SIZE_OK|SIZE_BAD") {
        $verify += Read-Available 1000
    }
    if ($verify -notmatch "SIZE_OK") {
        throw "$Name target size verification failed: $verify"
    }

    $installCommand = "mkdir -p /vision && cp $temporary /vision/$AppName && chmod 755 /vision/$AppName" +
        " && ln -sf /vision/$AppName /usr/bin/$Name" +
        " && ln -sf /vision/$AppName /usr/bin/$AppName" +
        " && echo INSTALLED:$Name"
    $install = Send-Line $installCommand 800
    Write-Host -NoNewline $install
    if ($install -notmatch "INSTALLED:$Name") {
        throw "$Name installation did not report success"
    }
}

try {
    $serial.Open()
    $serial.DiscardInBuffer()
    $serial.Write([byte[]]@(3), 0, 1)
    Start-Sleep -Milliseconds 300
    $serial.DiscardInBuffer()
    Write-Host -NoNewline (Send-Line "" 400)

    foreach ($file in $files) {
        Install-File -Source $file.Source -Name $file.Name -AppName $file.AppName
    }

    $check = Send-Line "ls -l /vision; command -v arm; command -v cam; cam --help" 1000
    Write-Host -NoNewline $check
    if ($check -notmatch "/usr/bin/arm" -or
        $check -notmatch "/usr/bin/cam" -or
        $check -notmatch "camctl status") {
        throw "Installed tools did not pass the command check"
    }

    Write-Host "`nVISION_TOOLS_INSTALL_COMPLETE"
}
finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
