param([string]$Cmd)
$env:LP_DEBUG_CMDS='1'
$env:LP_PROBE_CMD=$Cmd
& .\CsHost\bin\Release\net10.0\CsHost.exe out\lpcore.dll --probe-only 2>&1 | Select-Object -Last 6
"退出码 = $LASTEXITCODE"
