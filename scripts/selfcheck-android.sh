#!/usr/bin/env bash
# Android 真机 / 模拟器自检。照 scripts/selfcheck-win.sh 的形状。
#
#   bash scripts/selfcheck-android.sh [页面 ...]     # 不给就走全套
#
# 干什么:编核心 → 编 APK → 起假 Emby → 装 → 灌账号 → 逐页直达 → 截图 → 查 logcat。
#
# ☠ **「编译通过」不是交付。** 布局 / 可见性 / 时序这一类只有真渲染才现形:
#   渲染抛错在 Compose 里是**一片空白不报错**、卡片漏了就绪态是**封面隐身**、
#   命令全绿但白名单空是**一张封面都没有**。所以这个脚本的产物是**截图**,
#   不是一行「BUILD SUCCESSFUL」。
#
# ☠ **screencap 抓不到视频层时不要下「没画面」的结论。** 某些合成路径下
#   SurfaceView 的内容不进 framebuffer。判有没有画面要看 dumpsys SurfaceFlinger
#   的图层 + player.* 属性回读 —— 这是 Windows 侧「截图截不到视频层、
#   要用 EnumWindows 量窗口类」的同类问题。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${LOCALAPPDATA:-}/Android/Sdk}}"
ADB="$SDK/platform-tools/adb.exe"
[ -x "$ADB" ] || ADB="$SDK/platform-tools/adb"
PKG=xyz.linplayer.app.debug
ACT="$PKG/xyz.linplayer.app.MainActivity"
OUT="$ROOT/build/android-shots"
FAKE_PORT=18096
# 模拟器里访问宿主机是 10.0.2.2;真机要换成同网段地址 —— **别写进任何提交**
HOST="${LP_SELFCHECK_HOST:-10.0.2.2}"

mkdir -p "$OUT"
fail=0
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
bad()  { fail=$((fail + 1)); echo "  ✗ $1"; }
ok()   { echo "  ✓ $1"; }

# ---- 1. 核心层 ----------------------------------------------------------
step "编核心层(两个 ABI)"
bash scripts/fetch-libmpv-android.sh >/dev/null || { bad "libmpv 拉不到"; exit 1; }
bash scripts/build-core-android.sh || { bad "核心层编不出来"; exit 1; }
ok "liblpcore.so + libmpv.so 就位"

# ---- 2. 设备(要先知道 ABI 才知道装哪个包)------------------------------------------------------------
step "找设备"
if ! "$ADB" devices | grep -qE "device$"; then
  echo "  没有设备。起模拟器:"
  echo "    \"$SDK/emulator/emulator\" -avd lp-phone -no-boot-anim -no-audio -gpu swiftshader_indirect &"
  echo "    \"$ADB\" wait-for-device"
  bad "没有可用设备"
  exit 1
fi
ok "$("$ADB" devices | grep -E 'device$' | head -1)"

# ---- 3. APK -------------------------------------------------------------
step "编 APK"
( cd apps/android && ANDROID_HOME="$SDK" ./gradlew --no-daemon assembleDebug -q ) \
  || { bad "assembleDebug 失败"; exit 1; }
# ABI 拆包之后每个 ABI 一个 APK。装哪个由**设备**说了算,不是由我们猜
ABI="$("$ADB" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d "[:space:]")"
# ☠ 现在默认只出 arm64-v8a 的包。x86_64 模拟器上跑自检要先自己编那份 ABI:
#   bash scripts/fetch-libmpv-android.sh x86_64 && bash scripts/build-core-android.sh x86_64
[ -n "$ABI" ] || ABI=arm64-v8a
APK="$ROOT/apps/android/app/build/outputs/apk/debug/app-$ABI-debug.apk"
[ -f "$APK" ] || APK="$ROOT/apps/android/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || { bad "APK 没出来"; exit 1; }
ok "APK $(( $(stat -c %s "$APK") / 1024 / 1024 )) MB"

# ---- 4. 假 Emby ---------------------------------------------------------
# ☠ -clip-secs 必须给**真实时长**。不给的话它报写死的假片长,
#   一切按百分比算的功能(看完阈值 / 进度条 / 片头片尾跳过)全在对着一个假数验。
step "起假 Emby"
CLIP="${LP_SELFCHECK_CLIP:-$ROOT/build/clip.mp4}"
FAKE_PID=""
# ★ 两条都是踩出来的:
#   ① 超时给足 —— 这个假服务器起手那几次响应能到 3 秒以上,-m 2 会把「在跑」误判成「没起来」
#   ② 用 `-o /dev/null` 而不是 shell 的 `>/dev/null` —— gzip 响应下 shell 重定向
#      会让 curl 以 23(write error)退出,于是「在跑」照样被判成「没起来」
alive() { [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FAKE_PORT/System/Info/Public")" = 200 ]; }
if alive; then
  ok "已经有一个在跑,复用"
else
  ( cd core && go build -o "$ROOT/build/fakeemby.exe" ./cmd/fakeemby ) || { bad "fakeemby 编不出来"; exit 1; }
  ARGS=(-addr "0.0.0.0:$FAKE_PORT" -gzip)
  if [ -f "$CLIP" ]; then
    SECS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CLIP" 2>/dev/null | cut -d. -f1)"
    [ -n "$SECS" ] && ARGS+=(-clip "$CLIP" -clip-secs "$SECS")
  fi
  "$ROOT/build/fakeemby.exe" "${ARGS[@]}" > "$ROOT/build/fakeemby.log" 2>&1 &
  FAKE_PID=$!
  sleep 2
  curl -s -m 10 "http://127.0.0.1:$FAKE_PORT/System/Info/Public" >/dev/null \
    && ok "起在 $FAKE_PORT" || bad "假 Emby 没起来"
fi
trap '[ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null' EXIT

# ---- 5. 装 + 灌账号 ------------------------------------------------------
step "装 APK 并登录"
"$ADB" install -r "$APK" >/dev/null 2>&1 || { bad "装不上"; exit 1; }
"$ADB" shell pm clear "$PKG" >/dev/null
"$ADB" logcat -c
"$ADB" shell "am start -n $ACT -e lp_login 'http://$HOST:$FAKE_PORT|demo|demo'" >/dev/null
sleep 10
ok "已登录"

# ---- 6. 逐页直达 + 截图 --------------------------------------------------
# 直达用 intent extra,**不用 input tap**:坐标随字号 / 数据变,
# 中间任何一步没点中后面全错位,而截图看起来还像是「那一页做坏了」。
PAGES=("$@")
if [ ${#PAGES[@]} -eq 0 ]; then
  PAGES=(home aggregate servers search favorites downloads plugins
         ranking calendar settings settingsSub:about browse addServer)
fi

shoot() {
  local name="$1"
  "$ADB" exec-out screencap -p > "$OUT/$name.png"
  local sz; sz="$(stat -c %s "$OUT/$name.png" 2>/dev/null || echo 0)"
  # 截图小于 20KB 基本就是纯色一片 —— 那正是「渲染抛错」的样子
  if [ "$sz" -lt 20000 ]; then bad "$name 截图只有 $sz 字节(多半是一片纯色)"; else
    ok "$name → $OUT/$name.png($((sz / 1024)) KB)"; fi
}

step "逐页截图"
for p in "${PAGES[@]}"; do
  if [ "$p" = home ]; then
    "$ADB" shell "am start -n $ACT" >/dev/null
  else
    "$ADB" shell am force-stop "$PKG" >/dev/null
    "$ADB" shell "am start -n $ACT -e lp_page '$p'" >/dev/null
  fi
  sleep 6
  shoot "${p//:/-}"
done

# ---- 7. 崩溃与异常 -------------------------------------------------------
step "查 logcat"
CRASH="$("$ADB" logcat -d -b crash 2>/dev/null | grep -c "FATAL EXCEPTION")"
[ "$CRASH" = 0 ] && ok "没有 FATAL" || bad "有 $CRASH 次 FATAL EXCEPTION"
"$ADB" logcat -d -s LinPlayer 2>/dev/null | grep -E "图片加载失败|图片地址为空" | head -5

# 核心层报的 error 一条都不该有(它是「图片全空」「起播失败」唯一的出口)
COREERR="$("$ADB" logcat -d -s LinPlayer 2>/dev/null | grep -c "核心层:error")"
[ "$COREERR" = 0 ] && ok "核心层没报 error" || bad "核心层报了 $COREERR 条 error"

# ---- 8. 视频层(截图看不到,要问 SurfaceFlinger)---------------------------
step "视频层可见性"
if "$ADB" shell dumpsys SurfaceFlinger --list 2>/dev/null | grep -q "$PKG"; then
  ok "SurfaceFlinger 里有本应用的图层"
else
  echo "  (当前不在播放页,跳过)"
fi

# ---- 9. 形变压力(U1.28)-------------------------------------------------
# ★ 转屏本身**不会**销毁 SurfaceView —— Activity 声明了 configChanges。
#   所以两件事都做:转 100 次(验形变)+ 前后台 40 次(验真正的解绑重绑)。
#   只做前者的话「解绑必须同步阻塞」那条根本没被跑到,测出来是假绿。
step "形变压力 U1.28"
"$ADB" shell settings put system accelerometer_rotation 0 >/dev/null
"$ADB" shell am force-stop "$PKG" >/dev/null
"$ADB" logcat -c
"$ADB" shell "am start -n $ACT -e lp_page 'player:ep-1:stress'" >/dev/null
sleep 6
for _ in $(seq 1 50); do
  "$ADB" shell settings put system user_rotation 1 >/dev/null
  "$ADB" shell settings put system user_rotation 0 >/dev/null
done
for _ in $(seq 1 40); do
  "$ADB" shell input keyevent KEYCODE_HOME >/dev/null
  "$ADB" shell "am start -n $ACT" >/dev/null
done
sleep 3
if [ -n "$("$ADB" shell pidof "$PKG" | tr -d '[:space:]')" ]; then
  ok "转屏 100 次 + 前后台 40 次之后进程还活着"
else
  bad "压力测试后进程没了"
fi
C2="$("$ADB" logcat -d -b crash 2>/dev/null | grep -c "FATAL EXCEPTION")"
[ "$C2" = 0 ] && ok "压力测试期间没有 FATAL" || bad "压力测试期间 $C2 次 FATAL"

printf '\n'
[ "$fail" = 0 ] && { echo "全部通过。截图在 $OUT/"; exit 0; }
echo "$fail 项没过。截图在 $OUT/"
exit 1
