# LinPlayer 项目级工具链 —— PowerShell 用
#
#   用法:  . .\scripts\env.ps1
#   校验:  bash scripts/check-toolchain.sh
#
# 说明与 scripts/env.sh 一致,改一边必须改另一边。

$LpRoot = Split-Path -Parent $PSScriptRoot
$Tc     = Join-Path $LpRoot '.toolchain'

$env:GOROOT     = Join-Path $Tc 'go'
$env:GOPATH     = Join-Path $Tc 'gopath'
$env:GOMODCACHE = Join-Path $env:GOPATH 'pkg\mod'
$env:GOCACHE    = Join-Path $Tc 'gocache'
$env:GOBIN      = Join-Path $env:GOPATH 'bin'

# 三处实测抓出来的「偷偷写用户目录」,说明见 env.sh
$env:GOENV                = Join-Path $Tc 'goenv'
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $Tc 'zigcache'
$env:ZIG_LOCAL_CACHE_DIR  = $env:ZIG_GLOBAL_CACHE_DIR

# 不许 Go 自己下工具链,理由见 env.sh
$env:GOTOOLCHAIN = 'local'

$env:CGO_ENABLED = '1'
$zig = Join-Path $Tc 'zig\zig.exe'
$env:CC  = "$zig cc"
$env:CXX = "$zig c++"

$env:PATH = (Join-Path $env:GOROOT 'bin') + ';' + $env:GOBIN + ';' + (Join-Path $Tc 'zig') + ';' + $env:PATH

Write-Host "工具链已激活: $(& (Join-Path $env:GOROOT 'bin\go.exe') version)  |  zig $(& $zig version)"
