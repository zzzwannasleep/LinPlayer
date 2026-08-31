# LinPlayer 项目级工具链 —— bash / Git Bash 用
#
#   用法:  source scripts/env.sh
#   校验:  bash scripts/check-toolchain.sh
#
# 「项目级」的意思是**什么都不写进用户目录**:GOROOT / GOPATH / 模块缓存 / 构建缓存
# 全在 .toolchain/ 下,`.gitignore` 掉。换台机器 = 重跑 scripts/fetch-toolchain.sh,
# 不需要在系统里装任何东西,也不会和别的项目抢一个全局 Go 版本。
#
# ★ 为什么还带一个 C 编译器:Go 编 `c-shared`(SPEC §5.1 那个 lpcore.dll)**必须走 cgo**,
#   cgo 要 gcc/clang 口径的编译器 —— MSVC 不行。这台机器上原本一个都没有。
#   选 zig 是因为它一个包同时能当 Windows 和 Linux 的 cc(核心层要出三平台产物),
#   而且发布带 sha256、是纯 zip。安卓那边另走已装的 NDK clang。

_lp_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_lp_win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

export GOROOT="$(_lp_win "$_lp_root/.toolchain/go")"
export GOPATH="$(_lp_win "$_lp_root/.toolchain/gopath")"
export GOMODCACHE="$GOPATH/pkg/mod"
export GOCACHE="$(_lp_win "$_lp_root/.toolchain/gocache")"
export GOBIN="$GOPATH/bin"

# 下面三处是实测抓出来的「偷偷写用户目录」,不堵住的话「项目级」就是个说法:
#   GOENV          默认落在 %AppData%/Roaming/go/env
#   Go 遥测         默认在 %AppData%/Roaming/go/telemetry 下写计数文件
#   ZIG_*_CACHE    zig 默认往 %LocalAppData%/zig 写全局缓存(跑一次就有几百 KB)
export GOENV="$(_lp_win "$_lp_root/.toolchain/goenv")"
export ZIG_GLOBAL_CACHE_DIR="$(_lp_win "$_lp_root/.toolchain/zigcache")"
export ZIG_LOCAL_CACHE_DIR="$ZIG_GLOBAL_CACHE_DIR"

# GOTOOLCHAIN=local:不许 Go 因为某个 go.mod 写了更高版本就**自己下一个工具链**。
# 那会静默换掉编译器版本,而且下到 GOMODCACHE 里,再也说不清产物是谁编的。
export GOTOOLCHAIN=local

export CGO_ENABLED=1
export CC="$(_lp_win "$_lp_root/.toolchain/zig/zig.exe") cc"
export CXX="$(_lp_win "$_lp_root/.toolchain/zig/zig.exe") c++"

export PATH="$_lp_root/.toolchain/go/bin:$_lp_root/.toolchain/gopath/bin:$_lp_root/.toolchain/zig:$PATH"

unset -f _lp_win
unset _lp_root
