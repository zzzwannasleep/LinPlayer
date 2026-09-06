#!/usr/bin/env bash
# 交叉编译核心层 lpcore 给 Android(每个 ABI 一份 liblpcore.so)。
#
#   bash scripts/build-core-android.sh [abi ...]      # 默认只有 arm64-v8a(x86_64 要显式传)
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
# ★ 默认只编 arm64-v8a【用户定 2026-09-06】。x86_64 只有模拟器用得上,
#   32 位留给 TV。要别的 ABI 就当参数传进来,映射表都还在。
[ ${#ABIS[@]} -eq 0 ] && ABIS=(arm64-v8a)

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
# ★★ 打印**注入了哪几个**(只打变量名,不打值)。
#   没这一行的时候,「排行榜空白」到底是 CI 漏配、sealsecrets 封错,
#   还是运行时解不开,**三者在日志里长得一模一样**(都是一片安静)。
#   这行把第一种当场排掉。值绝不能打 —— CI 日志是公开的。
echo "编译期凭据: $(sed -E 's/=[^ ]*//g; s/-X //g' <<< "$SEAL" | tr ' ' '\n' | sed 's/.*\.//' | paste -sd' ' -)"
LP_VER="${LP_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")-dev}"
VER_FLAG="-X linplayer/core/system.Version=$LP_VER"
echo "版本: $LP_VER"

# 必须导出的符号:五个 C ABI 入口 + 五个 JNI 桥。
# libass 那七个也在表里:它们是 **Exo 内核特效字幕的全部入口**,
# 漏掉任何一个的表现是「装得上、能播、就是没有字幕」,而 APK 照样出得来。
LP_REQUIRED_SYMS="lp_abi_version lp_init lp_call lp_next_event lp_set_surface
Java_xyz_linplayer_app_core_Native_abiVersion
Java_xyz_linplayer_app_core_Native_init
Java_xyz_linplayer_app_core_Native_call
Java_xyz_linplayer_app_core_Native_nextEvent
Java_xyz_linplayer_app_core_Native_setSurface
Java_xyz_linplayer_app_core_Native_assOpen
Java_xyz_linplayer_app_core_Native_assOpenFile
Java_xyz_linplayer_app_core_Native_assChunk
Java_xyz_linplayer_app_core_Native_assSetSize
Java_xyz_linplayer_app_core_Native_assRender
Java_xyz_linplayer_app_core_Native_assClose
Java_xyz_linplayer_app_core_Native_assVersion
Java_xyz_linplayer_app_core_Native_assAddFont"

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
  # ☠ 符号表**先落到变量**再匹配,不要 `llvm-nm | grep -q`:
  #   `set -o pipefail` 下 grep -q 命中即退出,llvm-nm 写管道吃 SIGPIPE(141),
  #   整条管道判失败 —— **命中反而报「缺符号」**。中招的只有排在符号表前面的
  #   那个(lp_abi_version),靠后的匹配时 llvm-nm 已写完,所以看起来像「只缺一个」。
  #   管道缓冲的大小和输出量跟宿主有关:Linux CI 上红,Windows 上永远复现不了。
  syms="$("$TOOLBIN/llvm-nm" -D --defined-only "$OUT/liblpcore.so")"
  miss=0
  for s in $LP_REQUIRED_SYMS; do
    grep -q " T $s$" <<< "$syms" || { echo "  !! 缺符号 $s"; miss=1; }
  done
  if [ "$miss" != 0 ]; then
    echo "  -- 实际导出的 lp_/Java_ 符号 --"
    grep -E " (T|t|W) (lp_|Java_)" <<< "$syms" || true
    exit 1
  fi
  echo "  -> $OUT/liblpcore.so($(stat -c %s "$OUT/liblpcore.so") 字节)+ libmpv.so"
done

echo "完成。"
