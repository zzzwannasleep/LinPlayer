#!/usr/bin/env bash
# 交叉编译核心层 lpcore 给 Android(每个 ABI 一份 liblpcore.so)。
#
#   bash scripts/build-core-android.sh [abi ...]      # 默认 arm64-v8a x86_64
#
# 前置:
#   · source scripts/env.sh(Go 工具链)
#   · bash scripts/fetch-libmpv-android.sh(libmpv.so —— cgo 要拿它来链)
#   · Android NDK(ANDROID_NDK_HOME 或 %LOCALAPPDATA%/Android/Sdk/ndk/<版本>)
#
# 产物:apps/android/app/src/main/jniLibs/<abi>/liblpcore.so
#
# ★ 安卓侧**不用 zig**(env.sh 里那个是给 Windows/Linux 的),走 NDK 自带的 clang ——
#   NDK 的 clang 包装脚本已经把 sysroot、目标三元组、API level 都钉好了,
#   拿 zig 去凑等于自己重写一遍那些参数,错了的表现是链接期找不到 __android_log_print 这类符号。
#
# ★ strip:不 strip 的 .so 带着全部调试信息,APK 会从 21MB 涨到 105MB(栽过)。
#   `-ldflags "-s -w"` 去掉 Go 侧的符号表与 DWARF,再用 llvm-strip 扫一遍 C 侧留下的。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/env.sh"

MIN_API="${LP_ANDROID_MIN_API:-24}"
ABIS=("$@")
[ ${#ABIS[@]} -eq 0 ] && ABIS=(arm64-v8a x86_64)

# ---- 找 NDK ----------------------------------------------------------------
find_ndk() {
  # GitHub 的 ubuntu runner 设的是 ANDROID_NDK_ROOT / ANDROID_NDK,不是 ANDROID_NDK_HOME
  for v in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}"; do
    if [ -n "$v" ] && [ -d "$v" ]; then echo "$v"; return; fi
  done
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${LOCALAPPDATA:-}/Android/Sdk}}"
  # 默认钉 r28:装了多个 NDK 时「用哪个」不能靠运气 —— 靠运气的表现是换台机器
  # 编出来的 .so 链的是另一个 libc++,而两边都编得过。目录里没有它才退回最高版本。
  local pref="${LP_ANDROID_NDK:-28.2.13676358}"
  if [ -d "$sdk/ndk/$pref" ]; then echo "$sdk/ndk/$pref"; return; fi
  local v
  v="$(ls -1 "$sdk/ndk" 2>/dev/null | sort -V | tail -1)"
  [ -n "$v" ] && echo "$sdk/ndk/$v"
}
NDK="$(find_ndk)"
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "!! 找不到 Android NDK。设 ANDROID_NDK_HOME"; exit 1; }

case "$(uname -s)" in
  Linux*)  HOST_TAG=linux-x86_64 ;;
  Darwin*) HOST_TAG=darwin-x86_64 ;;
  *)       HOST_TAG=windows-x86_64 ;;
esac
TOOLBIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
[ -d "$TOOLBIN" ] || { echo "!! NDK 里没有 $TOOLBIN"; exit 1; }
echo "NDK: $NDK(API $MIN_API)"

# ---- 编译期凭据与版本号(和 build-core.sh 同口径)-----------------------------
SEAL="$( cd "$ROOT/core" && go run ./cmd/sealsecrets )"
LP_VER="${LP_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")-dev}"
VER_FLAG="-X linplayer/core/system.Version=$LP_VER"
echo "版本: $LP_VER"

for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a)   GOARCH=arm64; TRIPLE=aarch64-linux-android ;;
    armeabi-v7a) GOARCH=arm;   TRIPLE=armv7a-linux-androideabi; export GOARM=7 ;;
    x86_64)      GOARCH=amd64; TRIPLE=x86_64-linux-android ;;
    x86)         GOARCH=386;   TRIPLE=i686-linux-android ;;
    *) echo "!! 不认识的 ABI: $abi"; exit 1 ;;
  esac

  MPVDIR="$ROOT/third_party/libmpv/android/$abi"
  [ -f "$MPVDIR/libmpv.so" ] || {
    echo "!! 缺 $MPVDIR/libmpv.so —— 先跑 bash scripts/fetch-libmpv-android.sh $abi"; exit 1; }

  OUT="$ROOT/apps/android/app/src/main/jniLibs/$abi"
  mkdir -p "$OUT"

  echo "== 编 $abi($GOARCH)=="
  # -landroid:ANativeWindow_* 在这里(视频通道 A,SPEC §7.2)
  # -Wl,-rpath 之类不写:安卓的动态链接器只认 APK 里的 lib/<abi>/,rpath 是噪音
  (
    cd "$ROOT/core"
    export CGO_ENABLED=1 GOOS=android GOARCH="$GOARCH"
    export CC="$TOOLBIN/$TRIPLE$MIN_API-clang"
    export CXX="$TOOLBIN/$TRIPLE$MIN_API-clang++"
    export CGO_CFLAGS="-I$ROOT/third_party/libmpv"
    export CGO_LDFLAGS="-L$MPVDIR -landroid -llog"
    go build -buildmode=c-shared -ldflags "-s -w $SEAL $VER_FLAG" -o "$OUT/liblpcore.so" ./ffi
  )

  "$TOOLBIN/llvm-strip" --strip-unneeded "$OUT/liblpcore.so"
  cp -f "$MPVDIR/libmpv.so" "$OUT/libmpv.so"

  # 判据:ELF 机器类型对得上 + 五个导出符号都在。
  # 少了任何一个,APK 照样打得出来,装上去才 UnsatisfiedLinkError。
  "$TOOLBIN/llvm-readelf" -h "$OUT/liblpcore.so" | grep -E '^\s+Machine:'
  # ★ JNI 桥也要查。只查 lp_* 的话,漏编 JNI 的那个 ABI 装上去才炸:
  #   UnsatisfiedLinkError: No implementation found for ... Native.abiVersion()
  #   —— 而 .so 是加载成功的,所以「库没打进去」那条思路会把人带偏。真栽过一次。
  miss=0
  for s in lp_abi_version lp_init lp_call lp_next_event lp_set_surface            Java_xyz_linplayer_app_core_Native_abiVersion            Java_xyz_linplayer_app_core_Native_init            Java_xyz_linplayer_app_core_Native_call            Java_xyz_linplayer_app_core_Native_nextEvent            Java_xyz_linplayer_app_core_Native_setSurface; do
    "$TOOLBIN/llvm-nm" -D --defined-only "$OUT/liblpcore.so" | grep -q " T $s\$" || { echo "  !! 缺符号 $s"; miss=1; }
  done
  [ "$miss" = 0 ] || exit 1
  echo "  -> $OUT/liblpcore.so($(stat -c %s "$OUT/liblpcore.so") 字节)+ libmpv.so"
done

echo "完成。"
