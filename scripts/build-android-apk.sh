#!/usr/bin/env bash
# 出 Android APK。
#   用法: bash scripts/build-android-apk.sh [--release|--debug] [--tv|--phone] [--arm64|--arm32]
#   默认: --release --tv --arm64
#
# TV 包和手机包是**两个包**,区别只有壳打开哪个 html:
#   --tv    → apps/android/tauri.conf.json 的默认入口 index-tv.html
#   --phone → 额外挂 --config tauri.phone.conf.json,覆盖成 index-mobile.html
# 别再找运行时分流的那个 shim,2026-07-27 删了(设备类型判不准,判反=用户拿到另一端的整套界面)。
#
# ⚠️ 这个脚本**不拉 libmpv.so**(CI 那步会拉)。本地第一次跑要手动放一份到
#    apps/android/gen/android/app/src/main/jniLibs/<abi>/libmpv.so,ABI 要和 --arm64/--arm32 对上,
#    否则包出得来、装得上、一播放就 UnsatisfiedLinkError。
#
# 为什么不能直接 `npx tauri android build`:
# gradle 会转手调 cargo 去编安卓目标,而 rquickjs-sys 在安卓要现跑 bindgen ——
# 那一整套 libclang/resource-dir/sysroot/INCLUDE 的坑和 scripts/build-android.sh 里
# 写的是同一批(见那个文件顶部的逐条说明)。所以这里复用它导出的环境,
# 只把最后一步从 `cargo ndk build` 换成 tauri CLI。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${ANDROID_HOME:-$LOCALAPPDATA/Android/Sdk}"
NDK=""
for d in $(ls -d "$SDK"/ndk/* 2>/dev/null | sort -rV); do
  if [ -f "$d/toolchains/llvm/prebuilt/windows-x86_64/bin/libclang.dll" ]; then NDK="$d"; break; fi
done
[ -z "$NDK" ] && { echo "找不到带 libclang.dll 的 NDK(装一个 NDK 30+):$SDK/ndk/*"; exit 1; }
PB="$NDK/toolchains/llvm/prebuilt/windows-x86_64"
RES="$(cygpath -m "$(ls -d "$PB"/lib/clang/* | sort -rV | head -1)")"
SYSROOT="$(cygpath -m "$PB/sysroot")"

ENVV=(
  # ★ 关掉行号表,只对安卓这一次构建生效。
  # 根 Cargo.toml 的 [profile.release] debug="line-tables-only" 是为 Windows 上的 Sentry
  # 加的 —— MSVC 把调试信息全放进独立的 .pdb,exe 体积**不变**,那笔账很划算。
  # ELF 不是这样:调试信息留在 .so 里,一起被打进 APK。实测差别是 105MB → 25MB。
  # 用 CARGO_PROFILE_* 而不是改 Cargo.toml:那是全 workspace 的,一改就把桌面的崩溃报告
  # 打回"只知道在哪个函数"。cargo profile 没有 per-target 覆盖,只能在调用侧按住。
  "CARGO_PROFILE_RELEASE_DEBUG=false"
  "ANDROID_HOME=$(cygpath -w "$SDK")"
  "NDK_HOME=$(cygpath -w "$NDK")"
  "ANDROID_NDK_HOME=$(cygpath -w "$NDK")"
  "LIBCLANG_PATH=$(cygpath -w "$PB/bin")"
  # host 侧的 bindgen(经 proc-macro rquickjs-macro 传导,永远编 host)也要 builtin 头
  "BINDGEN_EXTRA_CLANG_ARGS=-resource-dir=$RES"
)
# host bindgen 还缺 WinSDK/CRT 头(stdio.h),从 vcvars64 灌 INCLUDE。
if [ -n "${INCLUDE:-}" ]; then
  ENVV+=( "INCLUDE=$INCLUDE" )
else
  for base in "/c/Program Files/Microsoft Visual Studio" "/c/Program Files (x86)/Microsoft Visual Studio"; do
    [ -d "$base" ] || continue
    VCVARS="$(find "$base" -name vcvars64.bat 2>/dev/null | head -1 || true)"
    [ -n "$VCVARS" ] && break
  done
  if [ -n "${VCVARS:-}" ]; then
    # 必须用临时批处理逐行跑:`cmd /c "call vcvars && echo %INCLUDE%"` 里 %INCLUDE%
    # 在解析期就展开了(那时还是空)。变量别叫 TMP —— 那是 Windows 临时目录环境变量。
    VCBAT="$(mktemp --suffix=.bat)"
    printf '@echo off\r\ncall "%s" >nul 2>&1\r\necho __B__\r\necho %%INCLUDE%%\r\necho __E__\r\n' \
      "$(cygpath -w "$VCVARS")" > "$VCBAT"
    INC="$(cmd //c "$(cygpath -w "$VCBAT")" 2>/dev/null | sed -n '/__B__/,/__E__/p' | sed '1d;$d' | tr -d '\r')"
    rm -f "$VCBAT"
    [ -n "$INC" ] && ENVV+=( "INCLUDE=$INC" )
  fi
fi

EXTRA=()
FLAVOR=()
TARGET="aarch64"
for a in "$@"; do
  case "$a" in
    --debug)   EXTRA+=(--debug) ;;
    --release) ;;
    --tv)      FLAVOR=() ;;
    --phone)   FLAVOR=(--config tauri.phone.conf.json) ;;
    --arm64)   TARGET="aarch64" ;;
    --arm32)   TARGET="armv7" ;;
    *) echo "未知参数: $a"; exit 1 ;;
  esac
done

# bindgen 的 per-target 变量名要跟着 --arm64/--arm32 走,写死 armv7 的话
# 换成 arm64 会退回宿主的 /usr/include,报一个和安卓毫无关系的 glibc 头找不到。
# (预置了 per-target 变量后 cargo-ndk 就不再补 sysroot,所以得自带 --sysroot。)
RT="armv7-linux-androideabi"
[ "$TARGET" = "aarch64" ] && RT="aarch64-linux-android"
ENVV+=(
  "BINDGEN_EXTRA_CLANG_ARGS_$RT=--sysroot=$SYSROOT -resource-dir=$RES"
  "BINDGEN_EXTRA_CLANG_ARGS_${RT//-/_}=--sysroot=$SYSROOT -resource-dir=$RES"
)

CLI="$(pwd)/node_modules/@tauri-apps/cli/tauri.js"
cd apps/android
exec env "${ENVV[@]}" node "$CLI" android build --apk --target "$TARGET" "${FLAVOR[@]}" "${EXTRA[@]}"
