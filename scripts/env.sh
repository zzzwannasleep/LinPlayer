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

# ★ 工具链**不在**时不要硬钉 GOROOT/CC。
#   `fetch-toolchain.sh` 只拉 Windows 的 Go 与 zig(第 17/25 行写死了 windows-amd64),
#   而 CI 的安卓 job 跑在 ubuntu 上、Go 由 actions/setup-go 装。
#   无条件 export 一个不存在的 GOROOT 的表现是 `go: command not found` ——
#   而那看起来像「机器没装 Go」,不像「这个脚本假设了 Windows」。
#   缓存目录仍然留在项目里:那几条在哪个平台都成立。
if [ -x "$_lp_root/.toolchain/go/bin/go" ] || [ -x "$_lp_root/.toolchain/go/bin/go.exe" ]; then
  export GOROOT="$(_lp_win "$_lp_root/.toolchain/go")"
  export PATH="$_lp_root/.toolchain/go/bin:$PATH"
fi
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
# 同上:zig 只有 Windows 那一份。安卓走 NDK 的 clang(build-core-android.sh 里 export),
# Linux CI 上没有 zig 时**不要**把 CC 指到一个不存在的可执行文件
# ★ 先定下**真实存在的那个文件**再转路径。反过来(先转再拼 .exe)在 MSYS 上会
#   拼出 `zig.exe.exe` —— 而 cgo 报的只是「找不到编译器」。
_lp_zig=""
[ -f "$_lp_root/.toolchain/zig/zig.exe" ] && _lp_zig="$_lp_root/.toolchain/zig/zig.exe"
[ -z "$_lp_zig" ] && [ -f "$_lp_root/.toolchain/zig/zig" ] && _lp_zig="$_lp_root/.toolchain/zig/zig"
if [ -n "$_lp_zig" ]; then
  export CC="$(_lp_win "$_lp_zig") cc"
  export CXX="$(_lp_win "$_lp_zig") c++"
  export PATH="$_lp_root/.toolchain/zig:$PATH"
fi
unset _lp_zig

export PATH="$_lp_root/.toolchain/gopath/bin:$PATH"

unset -f _lp_win
unset _lp_root
