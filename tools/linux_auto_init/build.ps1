param(
    [string]$BaseVmlinux = "D:\openla500_run_linux\tftp-root\vmlinux_nand_disabled",
    [string]$OutputDirectory = "artifacts\linux"
)

$ErrorActionPreference = "Stop"
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Resolve-Path (Join-Path $ScriptDirectory "..\..")
$WorkspaceRoot = Resolve-Path (Join-Path $RepositoryRoot "..\..")
$ToolchainBin = Join-Path $WorkspaceRoot "downloads\toolchains\la32r-mingw-v2.0\loongson-gnu-toolchain-8.3-i686-mingw-loongarch32r-linux-gnusf-v2.0\bin"
$Compiler = Join-Path $ToolchainBin "loongarch32r-linux-gnusf-gcc.exe"
$Strip = Join-Path $ToolchainBin "loongarch32r-linux-gnusf-strip.exe"
$Nm = Join-Path $ToolchainBin "loongarch32r-linux-gnusf-nm.exe"
$Readelf = Join-Path $ToolchainBin "loongarch32r-linux-gnusf-readelf.exe"
$BundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
$PythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -ne $PythonCommand) {
    $Python = $PythonCommand.Source
} elseif (Test-Path -LiteralPath $BundledPython) {
    $Python = $BundledPython
} else {
    throw "Python 3 was not found"
}
$OutputDirectory = Join-Path $RepositoryRoot $OutputDirectory
$BuildDirectory = Join-Path $ScriptDirectory "build"
$InitElf = Join-Path $BuildDirectory "auto_init.elf"
$Initramfs = Join-Path $BuildDirectory "auto_initramfs.cpio.gz"
$Unstripped = Join-Path $BuildDirectory "vmlinux_auto_visionarm_nand_disabled"
$Final = Join-Path $OutputDirectory "vmlinux_auto_visionarm_nand_disabled_stripped"

foreach ($Required in @($Compiler, $Strip, $Nm, $Readelf, $BaseVmlinux)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Required file not found: $Required"
    }
}

New-Item -ItemType Directory -Force -Path $BuildDirectory, $OutputDirectory | Out-Null

$CompilerArguments = @(
    "-Os",
    "-static",
    "-fno-pie",
    "-no-pie",
    "-Wall",
    "-Wextra",
    "-Wl,--build-id=none",
    "-o",
    $InitElf,
    (Join-Path $ScriptDirectory "auto_init.c")
)
& $Compiler $CompilerArguments
if ($LASTEXITCODE -ne 0) { throw "auto_init compile failed" }

& $Python (Join-Path $ScriptDirectory "build_initramfs.py") `
    --init $InitElf --output $Initramfs
if ($LASTEXITCODE -ne 0) { throw "initramfs build failed" }

& $Python (Join-Path $ScriptDirectory "patch_vmlinux.py") `
    --nm $Nm --readelf $Readelf --base $BaseVmlinux `
    --archive $Initramfs --output $Unstripped
if ($LASTEXITCODE -ne 0) { throw "vmlinux patch failed" }

& $Strip --strip-all -o $Final $Unstripped
if ($LASTEXITCODE -ne 0) { throw "vmlinux strip failed" }

& $Readelf -h -l $InitElf
Get-FileHash -Algorithm SHA256 $InitElf, $Initramfs, $Final
Get-Item $InitElf, $Initramfs, $Final | Select-Object FullName, Length
