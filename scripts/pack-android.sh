#!/usr/bin/env bash
# Android 出包。照 scripts/pack-win.sh 的形状。
#
#   bash scripts/pack-android.sh [abi ...]      # 默认 arm64-v8a x86_64
#
# ☠ **「编译通过」不是交付。** 这个脚本的判据是「装得上的、已签名的 APK」,
#   而验签必须看**产物本身**:
#     · `META-INF/*.RSA|*.EC|*.DSA` —— v1 证书
#     · "APK Sig Block 42" 魔数 —— v2/v3 签名块
#   ★ `keystore.properties` **写了 ≠ 用了**:release 变体没挂 signingConfig 会
#     静默出 `-unsigned.apk`,它长得和正常包一模一样,直到用户去装才报
#     「安装包无效」。所以下面第 3 步是硬闸门,不是提示。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${LOCALAPPDATA:-}/Android/Sdk}}"
OUT="$ROOT/build/android"
ABIS=("$@")
[ ${#ABIS[@]} -eq 0 ] && ABIS=(arm64-v8a x86_64)

fail=0
bad() { fail=$((fail + 1)); echo "  ✗ $1"; }
ok()  { echo "  ✓ $1"; }

echo "== 1. native =="
bash scripts/fetch-libmpv-android.sh "${ABIS[@]}" >/dev/null || { bad "libmpv 拉不到"; exit 1; }
bash scripts/build-core-android.sh "${ABIS[@]}" >/dev/null || { bad "核心层编不出来"; exit 1; }
ok "liblpcore.so + libmpv.so × ${#ABIS[@]}"

echo "== 2. assembleRelease =="
( cd apps/android && ANDROID_HOME="$SDK" ./gradlew --no-daemon assembleRelease -q ) \
  || { bad "assembleRelease 失败"; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/*.apk
shopt -s nullglob
found=0
for apk in apps/android/app/build/outputs/apk/release/*.apk; do
  found=1
  base="$(basename "$apk")"
  cp -f "$apk" "$OUT/$base"

  echo "== 3. 验签 $base =="
  # ☠ 名字里带 unsigned = 没挂 signingConfig。这是硬闸门
  case "$base" in
    *unsigned*) bad "$base 是未签名包 —— release 变体没挂 signingConfig" ; continue ;;
  esac

  if unzip -l "$OUT/$base" | grep -qE 'META-INF/.*\.(RSA|EC|DSA)$'; then
    ok "v1 证书在"
  else
    bad "$base 里没有 META-INF 证书"
  fi

  # v2/v3 的签名块在 ZIP 的 Central Directory 之前,魔数是 "APK Sig Block 42"
  if grep -aqs "APK Sig Block 42" "$OUT/$base"; then
    ok "APK Sig Block 42 在"
  else
    bad "$base 里没有 APK Sig Block 42(v2/v3 签名缺失)"
  fi

  # .so 必须已 strip:不 strip 的话包会从 21MB 涨到 105MB(栽过)
  sz=$(( $(stat -c %s "$OUT/$base") / 1024 / 1024 ))
  echo "  体积 ${sz} MB"
  [ "$sz" -le 60 ] || bad "$base ${sz}MB 超预算(先看 .so 有没有 strip)"
done
[ "$found" = 1 ] || bad "release 目录里一个 APK 都没有"

printf '\n'
[ "$fail" = 0 ] && { echo "出包完成:$OUT"; ls -la "$OUT"; exit 0; }
echo "$fail 项没过。"
exit 1
