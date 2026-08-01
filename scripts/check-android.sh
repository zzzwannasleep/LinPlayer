#!/usr/bin/env bash
# 只 cargo check 安卓目标,**不出 APK**。约 30 秒,用来在推之前挡住「只有安卓编不过」。
#   用法: bash scripts/check-android.sh [armv7-linux-androideabi|aarch64-linux-android]
#   默认两个都查。
#
# 为什么需要它:桌面侧的 `cargo check -p app` 只编 Windows 目标,而 crates/mpv 里
# `mod overlay` 有四个 cfg 变体(Windows / Linux-X11 / Android / 兜底桩)。给其中一个加了
# 函数、别的忘了补,桌面全绿、CI 上四个安卓 job 全红 —— 2026-08-02 连着三个提交栽在这。
# 出整个 APK 要好几分钟,于是就"下次再说",于是就没有下次。这个脚本把成本压到不用犹豫。
#
# 环境构造和 scripts/build-android-apk.sh 是同一批坑(见那个文件顶部的逐条说明),
# 外加两样只有直接调 cargo 才需要自己给的(平时由 cargo-ndk / tauri CLI 代劳):
#   · cc-rs 要 NDK 的 clang 包装脚本(CC_<target> / linker);
#   · rquickjs-sys 在 target 侧现跑 bindgen,要 NDK sysroot,否则 stdio.h 都找不到。
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

export ANDROID_HOME="$(cygpath -w "$SDK")"
export NDK_HOME="$(cygpath -w "$NDK")"
export ANDROID_NDK_HOME="$(cygpath -w "$NDK")"
export LIBCLANG_PATH="$(cygpath -w "$PB/bin")"
# host 侧的 bindgen(经 proc-macro rquickjs-macro 传导,永远编 host)要 builtin 头。
export BINDGEN_EXTRA_CLANG_ARGS="-resource-dir=$RES"
export PATH="$PB/bin:$PATH"

# host bindgen 还缺 WinSDK/CRT 头(stdio.h),从 vcvars64 灌 INCLUDE。
if [ -z "${INCLUDE:-}" ]; then
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
    [ -n "$INC" ] && export INCLUDE="$INC"
  fi
fi

check_one() {
  local T="$1" PFX API V U
  case "$T" in
    aarch64*) PFX=aarch64-linux-android ;;
    *)        PFX=armv7a-linux-androideabi ;;
  esac
  # NDK 只带部分 API 级别的包装脚本,挑一个真实存在的。
  API=""
  for a in 24 26 28 30 33 34 35 21; do
    if [ -f "$PB/bin/$PFX$a-clang.cmd" ]; then API=$a; break; fi
  done
  [ -z "$API" ] && { echo "NDK 里没有 $PFX*-clang.cmd,装的 NDK 不完整?"; exit 1; }

  V="$(echo "$T" | tr '-' '_')"
  U="$(echo "$T" | tr 'a-z-' 'A-Z_')"
  export CC_$V="$PB/bin/$PFX$API-clang.cmd"
  export AR_$V="$PB/bin/llvm-ar.exe"
  export CARGO_TARGET_${U}_LINKER="$PB/bin/$PFX$API-clang.cmd"
  # 带 target 后缀的这个优先级高于通用的那个(通用的给 host bindgen 用)。
  export BINDGEN_EXTRA_CLANG_ARGS_$V="--sysroot=$SYSROOT --target=$PFX$API -resource-dir=$RES"

  echo "== cargo check --target $T =="
  cargo check -p linplayer-android --target "$T" --lib
}

if [ $# -gt 0 ]; then
  check_one "$1"
else
  check_one armv7-linux-androideabi
  check_one aarch64-linux-android
fi
echo "安卓两个目标都编得过。"
