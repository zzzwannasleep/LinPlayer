#!/usr/bin/env bash
# 拉 Android 的 libmpv.so(每个 ABI 一份),落到 third_party/libmpv/android/<abi>/。
#
#   bash scripts/fetch-libmpv-android.sh [abi ...]     # 默认 arm64-v8a x86_64
#
# 产物**不进版本库**(.gitignore),和 Windows 侧 libmpv-2.dll 一个待遇:
# 大二进制由脚本现拉,CI 也跑这个脚本。
#
# 上游是 media-kit/libmpv-android-video-build 的 release —— 它把 mpv + ffmpeg 全静态
# 链进一个 .so,不需要再拉一堆依赖库。旧 Rust 栈用的就是它的产物。
#
# ★ 变体选 full 不选 default:default 砍掉了一批解码器。判据是「蓝光 PGS 字幕一片空白」
#   那类问题 —— 能编译、能播放、就是某一类轨道静默没有,和 Windows 侧选 shinchiro 完整版同因。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${LP_LIBMPV_TAG:-v1.1.11}"
VARIANT="${LP_LIBMPV_VARIANT:-full}"
BASE="https://github.com/media-kit/libmpv-android-video-build/releases/download/$TAG"
DEST="$ROOT/third_party/libmpv/android"
ABIS=("$@")
[ ${#ABIS[@]} -eq 0 ] && ABIS=(arm64-v8a x86_64)

# ELF 机器类型:LFS 指针 / 下错 ABI 都是「装得上、一跑就 UnsatisfiedLinkError」,
# 而错误信息里那串 76657273 是 "vers"(指针文本的开头),不是机器码。所以逐个校验。
elf_machine() {
  case "$1" in
    arm64-v8a)   echo "AArch64" ;;
    armeabi-v7a) echo "ARM" ;;
    x86_64)      echo "X86-64" ;;
    x86)         echo "80386" ;;
    *) echo "?" ;;
  esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for abi in "${ABIS[@]}"; do
  out="$DEST/$abi/libmpv.so"
  if [ -f "$out" ] && [ "${LP_LIBMPV_FORCE:-0}" != "1" ]; then
    echo "已有 $out($(stat -c %s "$out") 字节),跳过。LP_LIBMPV_FORCE=1 可强拉"
    continue
  fi
  jar="$VARIANT-$abi.jar"
  echo "== 拉 $jar =="
  curl -fL --retry 3 -o "$tmp/$jar" "$BASE/$jar"
  ( cd "$tmp" && unzip -o -q "$jar" )
  src="$tmp/lib/$abi/libmpv.so"
  [ -f "$src" ] || { echo "!! 包里没有 lib/$abi/libmpv.so"; exit 1; }

  mkdir -p "$DEST/$abi"
  cp -f "$src" "$out"

  # 校验:魔数 + 机器类型。不校验的话下错包在这里悄悄过去,到运行时才炸。
  head -c 4 "$out" | od -An -tx1 | tr -d ' \n' | grep -qi '^7f454c46$' \
    || { echo "!! $out 不是 ELF(多半是 LFS 指针或 HTML 错误页)"; exit 1; }
  want="$(elf_machine "$abi")"
  if command -v readelf >/dev/null 2>&1; then
    readelf -h "$out" | grep -q "$want" || { echo "!! $out 的机器类型不是 $want"; exit 1; }
  fi
  echo "   -> $out($(stat -c %s "$out") 字节,$want)"
done

echo "完成。libmpv.so 不入版本库,构建前跑本脚本。"
