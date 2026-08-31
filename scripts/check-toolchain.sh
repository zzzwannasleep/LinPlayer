#!/usr/bin/env bash
# 校验项目级工具链是**真的能用**,不是「文件在那儿」。
#
#   bash scripts/check-toolchain.sh
#
# 四关,任意一关红就退非零:
#   1. go / zig 起得来
#   2. go env 没有任何一项落在用户目录 —— 「项目级」的定义就是这条
#   3. 真编一个 c-shared DLL 并**用 ctypes 调进去**(编出文件不等于 C ABI 通)
#   4. 反向注入:把 CC 指到一个不存在的编译器,同一个构建**必须变红**。
#      不做这一步,第 3 关可能根本没走 cgo,那就是一条恒绿的假门禁。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/env.sh"

fail=0
ok()  { echo "  [通过] $*"; }
bad() { echo "  [不通过] $*"; fail=1; }

echo "== 1. 工具起得来 =="
if v=$(go version 2>&1); then ok "$v"; else bad "go: $v"; fi
if v=$(zig version 2>&1); then ok "zig $v"; else bad "zig: $v"; fi

echo "== 2. 什么都没落在用户目录 =="
for k in GOROOT GOPATH GOMODCACHE GOCACHE GOENV; do
  val=$(go env "$k" 2>/dev/null)
  case "$val" in
    */.toolchain/*) ok "$k = $val" ;;
    *)              bad "$k = $val  (应该在 .toolchain/ 下)" ;;
  esac
done

for k in ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR; do
  case "${!k:-}" in
    */.toolchain/*) ok "$k = ${!k}" ;;
    *)              bad "$k = ${!k:-<未设>}  (zig 默认往 %LocalAppData%\zig 写全局缓存)" ;;
  esac
done
# 遥测:Go 默认往用户配置目录写计数文件。
# ★ 这一项**挪不进项目**:GOTELEMETRYDIR 由操作系统的用户配置目录推导,没有覆盖入口 ——
#   环境变量 GOTELEMETRY 不被认(实测 `GOTELEMETRY=off go env GOTELEMETRY` 仍返回 local,
#   目录照建)。唯一的办法是 `go telemetry off`,它在那里留一个 14 字节的 "off" 标记,
#   而正是这个标记挡住了后续所有计数文件。所以这 14 字节不是泄漏,是堵漏的塞子。
tel=$(go env GOTELEMETRY 2>/dev/null)
if [ "$tel" = "off" ]; then ok "GOTELEMETRY = off"; else bad "GOTELEMETRY = ${tel:-<空>} (应为 off)"; fi

echo "== 3. c-shared 真的编得出来、也调得进去 =="
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/main.go" <<'EOF'
package main

import "C"

// 拿 SPEC §5.1 的第一个导出当探针:它也是宿主启动时第一个会调的符号。
//
//export lp_abi_version
func lp_abi_version() C.int { return 1 }

func main() {}
EOF
( cd "$tmp" && go mod init toolchaincheck >/dev/null 2>&1 )
if out=$( cd "$tmp" && go build -buildmode=c-shared -o probe.dll . 2>&1 ); then
  ok "go build -buildmode=c-shared"
  got=$(python -c "
import ctypes,sys
d=ctypes.CDLL(sys.argv[1]); d.lp_abi_version.restype=ctypes.c_int
print(d.lp_abi_version())" "$tmp/probe.dll" 2>&1)
  if [ "$got" = "1" ]; then ok "ctypes 调 lp_abi_version() 得到 $got"
  else bad "ctypes 调用失败或返回值不对: $got"; fi
else
  bad "go build -buildmode=c-shared 失败:"; echo "$out" | tail -5 | sed 's/^/      /'
fi

echo "== 4. 反向注入:CC 指向不存在的编译器,必须变红 =="
rm -f "$tmp/probe.dll"
if ( cd "$tmp" && CC="definitely-not-a-compiler-xyz" go build -buildmode=c-shared -o probe.dll . >/dev/null 2>&1 ); then
  bad "注入了坏 CC 居然还编过了 —— 说明第 3 关根本没走 cgo,那是条恒绿的假门禁"
else
  ok "坏 CC 下如期失败,第 3 关确实经过 cgo"
fi

echo
if [ $fail -eq 0 ]; then echo "全部通过。"; else echo "有不通过项,见上。"; fi
exit $fail
