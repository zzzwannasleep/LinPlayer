#!/usr/bin/env bash
# Windows 端真机自检:编核心 → 编壳 → 起假 Emby → 灌账号 → 起 exe → 截图。
#
# ★ 为什么每次都要走全套:「编译通过」不是交付。这个仓库栽过的三类 bug ——
#   透明窗口下渲染抛错=一片黑不报错 / 卡片没加 .ready 类=封面隐身 /
#   命令全绿但白名单空=一张封面都没有 —— **全都只有真渲染才现形**。
#
#   bash scripts/selfcheck-win.sh [截图名] [落到哪一页] [起播用的视频]
#
# 几个跑得最多的:
#   bash scripts/selfcheck-win.sh plugins       plugins        插件市场(市场 tab)
#   bash scripts/selfcheck-win.sh plugins-inst  plugins:1      已装 tab
#   bash scripts/selfcheck-win.sh plugin-dev    "plugindev:$PWD/scripts/fixtures/selfcheck-plugin"
#                                                              装一个真插件跑起来
#   LP_SHADER=ak_sharp LP_DRILL=1 bash scripts/selfcheck-win.sh quality player <片子>
#                                                              画质档位面板(真选下拉项)
#   LP_CATDETAIL=1 bash scripts/selfcheck-win.sh catalog #       "plugincatalog:$PWD/scripts/fixtures/selfcheck-plugin"
#                                                              影视目录 + 详情盖层
#     ↑ 这条走的是**最长的一条链**:JS 引擎 → 贡献点 → 源分派表 →
#       source.categories/catalog → 影视目录页渲染。只截市场页的话它一次都没被走过。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOT="${1:-selfcheck}"
# 第二个参数 = 落到哪一页(见 MainWindow.SelfCheckJump)。空 = 首页。
PAGE="${2:-}"
# 第三个参数 = 起播用的视频文件。给了才验播放链路。
CLIP="${3:-}"
APP="$ROOT/apps/windows/LinPlayer.Desktop"
# ★★ LP_CONF=Release 用发行配置跑。
#   平时跑 Debug 是对的(快),但**量性能必须用 Release**:
#   Debug 不做优化、方法不内联,同一段代码能慢好几倍 ——
#   拿 Debug 的数去优化,优化的是一个用户根本跑不到的程序。
CONF="${LP_CONF:-Debug}"
BIN="$APP/bin/$CONF/$(grep -oP "(?<=<TargetFramework>)[^<]+" "$APP/LinPlayer.Desktop.csproj")"
PORT=18096

source "$ROOT/scripts/env.sh"

# ★ 默认开 gzip:**真 Emby 默认就是压的**。不压的假服务器曾让
#   「手动设 Accept-Encoding 导致 Go 不自动解压」这个洞本地全绿。
GZ="-gzip"; [ "${LP_NOGZIP:-}" = "1" ] && GZ=""

echo "== 1/5 编核心层 =="
bash "$ROOT/scripts/build-core.sh" "$BIN" >/dev/null
echo "   lpcore.dll $(stat -c%s "$BIN/lpcore.dll") 字节"

echo "== 2/5 编壳 =="
( cd "$APP" && dotnet build -c "$CONF" -v q --nologo >/dev/null )

echo "== 3/5 起假 Emby =="
# ★ 先杀干净。两个 LinPlayer 一起跑的时候截图会拍到上一个(旧界面),
#   看起来就像「改了没生效」—— 这个坑踩过。
powershell -NoProfile -Command "Get-Process LinPlayer,fakeemby -EA SilentlyContinue | Stop-Process -Force" || true
go build -o "$ROOT/build/fakeemby.exe" ./core/cmd/fakeemby 2>/dev/null || \
  ( cd "$ROOT/core" && go build -o "$ROOT/build/fakeemby.exe" ./cmd/fakeemby )
"$ROOT/build/fakeemby.exe" -addr "127.0.0.1:$PORT" -clip "$CLIP" $GZ > "$ROOT/build/fakeemby.log" 2>&1 &
FAKE=$!
trap 'kill $FAKE 2>/dev/null || true' EXIT
# ★★ 等它起来。判据必须是 **curl 的退出码**,而且要能读懂 gzip:
#   原来写的是 `curl -s URL >/dev/null && break` —— 假服务器开着 -gzip 时
#   curl 不发 Accept-Encoding、拿到一坨 gzip 字节,**退出码 23**(写出错),
#   于是 break 从来没触发过:每一次自检都白等满 30 轮 ≈ 8 秒,
#   而且日志里只是多了 30 行 /System/Info/Public,谁也不会多看一眼。
#   我为此把这 30 行当成「应用在疯狂探活」查了半天。
for _ in $(seq 30); do curl -s --compressed -o /dev/null "http://127.0.0.1:$PORT/System/Info/Public" && break; sleep 0.2; done

# ★★ LP_FRESH=1:**不灌账号,走真的登录那条路**。
#
#   一直灌 config.json 起的代价:11 个页面全验过了,唯独「登录成功之后要把账号
#   写进配置」这一环从来没被走过 —— 而它漏了的表现是「登录进去了,
#   但整个应用当作你没登录」。2026-08-31 用户实测撞上,原话
#   「进去了但是还是不行,提示缺少 server-id」。
#
#   预置状态跑得快,但**跑不到状态是怎么来的那条路**。两条都要有。
if [ "${LP_FRESH:-}" = "1" ] || [ "${LP_FRESH:-}" = "2" ]; then
  echo "== 4/5 不灌账号 —— 走真的登录(LP_FRESH=1)=="
  rm -rf "$BIN/userdata"
  mkdir -p "$BIN/userdata"
  # ★ LP_FRESH=2:清干净但**不自动登录** —— 用来看首登闸口自己长什么样。
  #   只有 =1 才走那条自动填表点登录的路。
  if [ "${LP_FRESH:-}" != "2" ]; then
    PAGE="login:http://127.0.0.1:$PORT|u1|p"
  else
    PAGE=""
  fi
else

if [ "${LP_SOURCE:-}" = "1" ]; then
  # 文件浏览型源(本地源)。造一棵真的目录树 —— 假的目录树列不出真的排序 / 大小 / 视频判定。
  echo "== 4/5 灌一个**本地源**账号 + 造目录树(LP_SOURCE=1)=="
  TREE="$BIN/userdata/_selfcheck_tree"
  rm -rf "$TREE"; mkdir -p "$TREE/剧集/S01" "$TREE/空文件夹"
  printf 'x%.0s' $(seq 1 1234) > "$TREE/某部电影.mkv"
  printf 'x%.0s' $(seq 1 999)  > "$TREE/封面.jpg"
  printf 'x%.0s' $(seq 1 5678) > "$TREE/剧集/S01/第01集.mp4"
  # ★ 路径要进 JSON,反斜杠必须转义。Windows 上 $TREE 是 /d/... 形式,
  #   但 exe 拿到的是 D:\... —— 统一用正斜杠,Go 的 filepath 两种都吃。
  TREE_JSON="$(cd "$TREE" && pwd -W 2>/dev/null || printf '%s' "$TREE")"
  mkdir -p "$BIN/userdata"
  cat > "$BIN/userdata/config.json" <<JSON
{
  "device_id": "linplayer-selfcheck",
  "accounts": [{
    "server": "$TREE_JSON",
    "user_name": "本地文件夹",
    "name": "自检本地源",
    "lines": [],
    "active_line": 0,
    "source_kind": "local",
    "source": { "id": "$TREE_JSON", "base_url": "$TREE_JSON", "extra": {} }
  }],
  "active": 0,
  "theme": "dark"
}
JSON
else

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
fi
fi

echo "== 5/5 起 exe 截图 =="
# ★ 排行榜的两个上游也指到假服务器上(它顺带假扮弹弹Play / TMDB)。
#   没有这一步的话,排行榜只验得到「没凭据」那一半 —— 而**有数据时长什么样**
#   才是会出 bug 的那一半(图床白名单、id 数字/字符串两种、名次角标)。
export LP_RANKING_BASE_DANDAN="http://127.0.0.1:$PORT"
export LP_RANKING_BASE_TMDB="http://127.0.0.1:$PORT"
export LP_RANKING_BASE_TMDBIMG="http://127.0.0.1:$PORT"
# 追剧日历的上游同理(假服务器兼职 Bangumi)
export LP_BANGUMI_API="http://127.0.0.1:$PORT"
# 图标库的聚合源(假服务器兼职图床)。
# ★ 真实构建里这个是 -ldflags 注入的,源码里没有 —— 自检走环境变量那条覆盖。
export LP_ICON_LIBRARY_SOURCES="http://127.0.0.1:$PORT/icons.json"
# 插件市场的官方源(假服务器兼职插件仓库)。同上:真实构建里是硬编的公开地址。
# ★ 不指过去的话,市场页在没网的机器上只验得到「拉取失败」那一半 ——
#   而**有插件时长什么样**(第三方徽章、跳过数提示、版本取最大)才是会出 bug 的那半。
export LP_PLUGIN_OFFICIAL_REGISTRY="http://127.0.0.1:$PORT/plugins/registry.json"
LP_SELFCHECK=1 LP_SELFCHECK_MENU="${LP_MENU:-}" LP_SELFCHECK_COUNT="${LP_COUNT:-}" LP_SELFCHECK_PAGE="$PAGE" LP_SELFCHECK_MAXIMIZE="${LP_MAX:-}" LP_SELFCHECK_PLAYER_DRILL="${LP_DRILL:-}" LP_SELFCHECK_SCROLL="${LP_SCROLL:-}" LP_SELFCHECK_SOURCE="${LP_SRCKIND:-}" LP_SELFCHECK_CATALOG_DETAIL="${LP_CATDETAIL:-}" LP_SELFCHECK_SHADER="${LP_SHADER:-}" "$BIN/LinPlayer.exe" > "$ROOT/build/app.log" 2>&1 &
# 播放页要等起播 + 解码,别的页 6 秒够
# LP_SHADER=all 要把 28 档挨个挂一遍(每档要等真渲染一帧才编译),得多给点时间
# LP_WAIT=秒 覆盖等待时长(滚动扫描这类要跑几秒的自检用)
sleep "${LP_WAIT:-$([ "${LP_SHADER:-}" = "all" ] && echo 45 || { [ -n "$CLIP" ] && echo 12 || echo 6; })}"
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
