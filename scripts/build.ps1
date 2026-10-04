param(
    [string]$QuartusBin = 'D:\Development\QuartusPrime-25.1\quartus\bin64',
    [string]$QuestaBin = 'D:\Development\QuartusPrime-25.1\questa_fse\win64',
    [string]$LlvmBin = 'D:\Development\LLVM-23.1.1\bin',
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
& python (Join-Path $taskRoot 'tools/build_disc_firmware.py') --llvm-bin $LlvmBin
if ($LASTEXITCODE -ne 0) { throw 'Native disc firmware build failed.' }
if (-not $SkipTests) {
    & (Join-Path $PSScriptRoot 'test.ps1') -QuestaBin $QuestaBin -LlvmBin $LlvmBin
    if ($LASTEXITCODE -ne 0) { throw 'Verification failed.' }
}
Push-Location (Join-Path $taskRoot 'src/fpga')
try {
    & (Join-Path $QuartusBin 'quartus_sh.exe') --flow compile ap_core
    if ($LASTEXITCODE -ne 0) { throw 'Quartus compilation failed.' }
    & (Join-Path $QuartusBin 'quartus_sta.exe') -t '../../scripts/timing.tcl'
    if ($LASTEXITCODE -ne 0) { throw 'Timing report failed.' }
} finally { Pop-Location }
Push-Location $taskRoot
try {
    & python tools/package_core.py
    if ($LASTEXITCODE -ne 0) { throw 'Packaging failed.' }
} finally { Pop-Location }
