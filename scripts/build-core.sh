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
# ★ 转绝对路径:下面要 `cd "$ROOT/core"` 再往 $OUT 写,相对路径会在那儿再解一次 ——
#   产物静默落到 core/<你给的相对路径>/ 下,而**调用方看到的是「编译成功」**。
#   2026-08-31 真栽过:自检一直加载着一小时前的旧 lpcore.dll,查了半天以为是代码没生效。
OUT="$(cd "$OUT" && pwd)"

# shellcheck source=/dev/null
source "$ROOT/scripts/env.sh"

case "$(go env GOOS)" in
  windows) LIB="lpcore.dll" ;;
  darwin)  LIB="liblpcore.dylib" ;;
  *)       LIB="liblpcore.so" ;;
esac

# 编译期凭据(弹弹Play / TMDB)。**只有密文进 ldflags** —— 明文会原样出现在
# 构建日志和进程命令行里。一个都没配时 SEAL 是空串,本地构建照常出得来,
# 对应功能会明说「此构建没有凭据」(honest,不是装作没数据)。
SEAL="$( cd "$ROOT/core" && go run ./cmd/sealsecrets )"
if [ -n "$SEAL" ]; then
  echo "  已注入编译期凭据($(printf '%s' "$SEAL" | grep -o -- '-X' | wc -l) 项)"
fi

echo "== 编 $LIB =="
# 版本号注进核心层(system.Version,更新检查拿它和线上比)。
# 唯一权威是仓库根的 VERSION,见 docs/VERSIONING.md ——
# 写死字面量会让老用户静默收不到更新,本仓踩过三次。
LP_VER="${LP_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")-dev}"
VER_FLAG="-X linplayer/core/system.Version=$LP_VER"
echo "  版本: $LP_VER"
( cd "$ROOT/core" && go build -buildmode=c-shared -ldflags "-s -w $SEAL $VER_FLAG" -o "$OUT/$LIB" ./ffi )

# libmpv 得在 DLL 搜索路径上。Windows 拷一份到产物旁边;
# Linux **不拷** —— 那边依赖系统安装的 libmpv(SPEC §15.4)。
if [ "$(go env GOOS)" = "windows" ]; then
  cp -f "$ROOT/third_party/libmpv/libmpv-2.dll" "$OUT/" 2>/dev/null || \
    echo "  !! 没找到 libmpv-2.dll,运行时会起不来"
fi

echo "产物:"
ls -la "$OUT"
