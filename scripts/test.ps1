param(
    [string]$QuestaBin = 'D:\Development\QuartusPrime-25.1\questa_fse\win64',
    [string]$LlvmBin = 'D:\Development\LLVM-23.1.1\bin'
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
Push-Location $taskRoot
$previousDiscLlvm = $env:DISC_FIRMWARE_LLVM_BIN
$env:DISC_FIRMWARE_LLVM_BIN = $LlvmBin
try {
    & python -m unittest discover -s tests -p 'test_*.py' -v
    if ($LASTEXITCODE -ne 0) { throw 'Native CUE/BIN tests failed.' }
    & python tools/make_disc_test_fixture.py
    if ($LASTEXITCODE -ne 0) { throw 'Native disc fixture generation failed.' }
    $simDir = Join-Path $taskRoot 'build/sim'
    New-Item -ItemType Directory -Force -Path $simDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $simDir 'apf') | Out-Null
    Copy-Item -LiteralPath 'src/fpga/apf/build_id.mif' -Destination (Join-Path $simDir 'apf/build_id.mif')
    Push-Location $simDir
    try {
        & (Join-Path $QuestaBin 'vlib.exe') work
        if ($LASTEXITCODE -ne 0) { throw 'Cannot create simulation library.' }
        $quartusDir = Split-Path -Parent (Split-Path -Parent $QuestaBin)
        $vendor = Join-Path $quartusDir 'quartus/eda/sim_lib/altera_mf.v'
        & (Join-Path $QuestaBin 'vlog.exe') -sv '+incdir+.' '+incdir+../../src/fpga/core/cdi' $vendor '../../src/fpga/core/pocket_support.sv' '../../src/fpga/core/pocket_native_disc.sv' '../../src/fpga/core/native_disc/picorv32.v' '../../src/fpga/core/pocket_memory.sv' '../../src/fpga/core/cdi/sdram.sv' '../../src/fpga/core/cdi/video_timing.sv' '../../src/fpga/core/cdi/flag_cross_domain.sv' '../../tests/tb_adapters.sv' '../../tests/tb_memory.sv' '../../tests/tb_video.sv' '../../tests/tb_native_disc.sv' '../../tests/tb_pause.sv'
        if ($LASTEXITCODE -ne 0) { throw 'Adapter compilation failed.' }
        & (Join-Path $QuestaBin 'vlog.exe') -sv '../../src/fpga/apf/common.v' '../../src/fpga/apf/io_bridge_peripheral.v' '../../src/fpga/apf/mf_datatable.v' '../../src/fpga/core/core_bridge_cmd.v' '../../src/fpga/core/pocket_platform_io.sv' '../../tests/tb_framework.sv' '../../tests/tb_boot.sv' '../../tests/tb_startup.sv'
        if ($LASTEXITCODE -ne 0) { throw 'Framework compilation failed.' }
        & (Join-Path $QuestaBin 'vlog.exe') -sv '+incdir+../../src/fpga/core/cdi' '../../src/fpga/core/cdi/servo_hle.sv' '../../tests/tb_servo.sv'
        if ($LASTEXITCODE -ne 0) { throw 'Servo compilation failed.' }
        & (Join-Path $QuestaBin 'vlog.exe') -sv -mfcu '+incdir+../../src/fpga/core/cdi' '../../src/fpga/core/cdi/ica_dca_ctrl.sv' '../../src/fpga/core/cdi/display_file_reader.sv' '../../src/fpga/core/cdi/clut_rle.sv' '../../src/fpga/core/cdi/delta_yuv_decoder.sv' '../../src/fpga/core/cdi/mcd212.sv' '../../tests/tb_mcd_video.sv'
        if ($LASTEXITCODE -ne 0) { throw 'MCD video compilation failed.' }
        foreach ($test in @(
            @{ Top = 'tb_pause'; Marker = 'ALL PAUSE TESTS PASSED' },
            @{ Top = 'tb_framework'; Marker = 'ALL FRAMEWORK TESTS PASSED' },
            @{ Top = 'tb_video'; Marker = 'ALL VIDEO TESTS PASSED' },
            @{ Top = 'tb_mcd_video'; Marker = 'ALL MCD VIDEO TESTS PASSED' },
            @{ Top = 'tb_startup'; Marker = 'ALL STARTUP TESTS PASSED' },
            @{ Top = 'tb_startup'; Log = 'tb_startup_failure'; Parameters = @('-gBIOS_FAILURE=1'); Marker = 'ALL STARTUP FAILURE TESTS PASSED' },
            @{ Top = 'tb_adapters'; Marker = 'ALL ADAPTER TESTS PASSED' },
            @{ Top = 'tb_memory'; Marker = 'ALL MEMORY TESTS PASSED' },
            @{ Top = 'tb_servo'; Marker = 'ALL SERVO TESTS PASSED' },
            @{ Top = 'tb_boot'; Marker = 'ALL BOOT TESTS PASSED' },
            @{ Top = 'tb_native_disc'; Marker = 'ALL NATIVE DISC TESTS PASSED' }
        )) {
            $logName = if ($test.ContainsKey('Log')) { $test.Log } else { $test.Top }
            $transcript = Join-Path $simDir ($logName + '.log')
            $simArguments = @('-batch', '-L', 'cyclonev_ver', '-onfinish', 'exit', '-l', $transcript, ('work.' + $test.Top), '-do', '../../tests/run.do')
            if ($test.ContainsKey('Parameters')) { $simArguments += $test.Parameters }
            & (Join-Path $QuestaBin 'vsim.exe') @simArguments
            $exitCode = $LASTEXITCODE
            $result = Get-Content -LiteralPath $transcript -Raw
            if ($exitCode -ne 0 -or $result -notmatch [regex]::Escape($test.Marker) -or $result -match '\*\* (Fatal|Error):') {
                throw ($test.Top + ' simulation failed. See ' + $transcript)
            }
        }
    } finally { Pop-Location }
} finally { $env:DISC_FIRMWARE_LLVM_BIN = $previousDiscLlvm; Pop-Location }
