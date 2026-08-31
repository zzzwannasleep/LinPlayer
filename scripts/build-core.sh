#!/usr/bin/env bash
# 编核心层 lpcore(C ABI 库)。
#
#   bash scripts/build-core.sh [输出目录]
#
# 前置:source scripts/env.sh(项目级工具链)。
# 产物:<输出目录>/lpcore.dll + lpcore.h(Windows)/ liblpcore.so(Linux)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/core}"
mkdir -p "$OUT"

# shellcheck source=/dev/null
source "$ROOT/scripts/env.sh"

case "$(go env GOOS)" in
  windows) LIB="lpcore.dll" ;;
  darwin)  LIB="liblpcore.dylib" ;;
  *)       LIB="liblpcore.so" ;;
esac

echo "== 编 $LIB =="
( cd "$ROOT/core" && go build -buildmode=c-shared -ldflags "-s -w" -o "$OUT/$LIB" ./ffi )

# libmpv 得在 DLL 搜索路径上。Windows 拷一份到产物旁边;
# Linux **不拷** —— 那边依赖系统安装的 libmpv(SPEC §15.4)。
if [ "$(go env GOOS)" = "windows" ]; then
  cp -f "$ROOT/crates/mpv/libmpv/libmpv-2.dll" "$OUT/" 2>/dev/null || \
    echo "  !! 没找到 libmpv-2.dll,运行时会起不来"
fi

echo "产物:"
ls -la "$OUT"
