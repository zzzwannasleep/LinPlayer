#!/usr/bin/env bash
# Windows 端真机自检:编核心 → 编壳 → 起假 Emby → 灌账号 → 起 exe → 截图。
#
# ★ 为什么每次都要走全套:「编译通过」不是交付。这个仓库栽过的三类 bug ——
#   透明窗口下渲染抛错=一片黑不报错 / 卡片没加 .ready 类=封面隐身 /
#   命令全绿但白名单空=一张封面都没有 —— **全都只有真渲染才现形**。
#
#   bash scripts/selfcheck-win.sh [截图名]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOT="${1:-selfcheck}"
# 第二个参数 = 落到哪一页(见 MainWindow.SelfCheckJump)。空 = 首页。
PAGE="${2:-}"
# 第三个参数 = 起播用的视频文件。给了才验播放链路。
CLIP="${3:-}"
APP="$ROOT/apps/windows/LinPlayer.Desktop"
BIN="$APP/bin/Debug/$(grep -oP "(?<=<TargetFramework>)[^<]+" "$APP/LinPlayer.Desktop.csproj")"
PORT=18096

source "$ROOT/scripts/env.sh"

echo "== 1/5 编核心层 =="
bash "$ROOT/scripts/build-core.sh" "$BIN" >/dev/null
echo "   lpcore.dll $(stat -c%s "$BIN/lpcore.dll") 字节"

echo "== 2/5 编壳 =="
( cd "$APP" && dotnet build -v q --nologo >/dev/null )

echo "== 3/5 起假 Emby =="
# ★ 先杀干净。两个 LinPlayer 一起跑的时候截图会拍到上一个(旧界面),
#   看起来就像「改了没生效」—— 这个坑踩过。
powershell -NoProfile -Command "Get-Process LinPlayer,fakeemby -EA SilentlyContinue | Stop-Process -Force" || true
go build -o "$ROOT/build/fakeemby.exe" ./core/cmd/fakeemby 2>/dev/null || \
  ( cd "$ROOT/core" && go build -o "$ROOT/build/fakeemby.exe" ./cmd/fakeemby )
"$ROOT/build/fakeemby.exe" -addr "127.0.0.1:$PORT" -clip "$CLIP" > "$ROOT/build/fakeemby.log" 2>&1 &
FAKE=$!
trap 'kill $FAKE 2>/dev/null || true' EXIT
for _ in $(seq 30); do curl -s "http://127.0.0.1:$PORT/System/Info/Public" >/dev/null && break; sleep 0.2; done

echo "== 4/5 灌一个账号(冷启动形态:配置里就有,本次会话没登录过)=="
mkdir -p "$BIN/userdata"
cat > "$BIN/userdata/config.json" <<JSON
{
  "device_id": "linplayer-selfcheck",
  "accounts": [{
    "server": "http://127.0.0.1:$PORT",
    "token": "fake-token",
    "user_id": "u1",
    "user_name": "自检用户",
    "name": "自检用假服务器",
    "lines": [],
    "active_line": 0
  }],
  "active": 0,
  "theme": "dark",
  "companion_enabled": true,
  "plugin_official_enabled": true
}
JSON

echo "== 5/5 起 exe 截图 =="
LP_SELFCHECK_PAGE="$PAGE" LP_SELFCHECK_MAXIMIZE="${LP_MAX:-}" "$BIN/LinPlayer.exe" > "$ROOT/build/app.log" 2>&1 &
# 播放页要等起播 + 解码,别的页 6 秒够
sleep $([ -n "$CLIP" ] && echo 12 || echo 6)
powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/shot-window.ps1" \
  -ProcName LinPlayer -Out "$ROOT/build/$SHOT.png"
# ★ **优雅关闭**,不是 Stop-Process。
#   Kill 掉的话退出路径(lp_shutdown:停 mpv + 上报进度 + 写历史)根本不会跑,
#   而「看一半退出续播不落地」正是这条路断掉的唯一表现。
powershell -NoProfile -Command "
  \$p = Get-Process LinPlayer -EA SilentlyContinue
  if (\$p) { \$null = \$p.CloseMainWindow(); if (-not \$p.WaitForExit(8000)) { \$p.Kill(); Write-Output '!! 8 秒没退干净,只能 kill' } }
" || true

echo
echo "假 Emby 收到的请求:"
grep '  <-' "$ROOT/build/fakeemby.log" | sort | uniq -c | sort -rn
echo
echo "截图:build/$SHOT.png"
