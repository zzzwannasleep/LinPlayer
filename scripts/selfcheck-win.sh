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
#   LP_HOME=1 bash scripts/selfcheck-win.sh home                首页合集栏(有合集)
#   LP_HOME=1 LP_NOBOXSET=1 bash scripts/selfcheck-win.sh home-nobox
#                                                              没有合集 -> 整条不画
#   LP_WATCHED=60 LP_THUMB=1 bash scripts/selfcheck-win.sh w play:mv-1 <片子>
#                                                              看完阈值:续播 1200s/1800s=66.7%
#                                                              越线 -> 必须从头放
#   LP_TRANSCODE=1 LP_THUMB=1 bash scripts/selfcheck-win.sh tc play:mv-1 <片子>
#                                                              服务器只给转码地址 -> 我们照样直连
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

# ☠☠ 把 -clip 那个文件的**真实时长**告诉假服务器。
#   不告诉的话它报的是写死的假片长(电影 7200 秒),而真正放出来的是 1800 秒 ——
#   于是一切按百分比算的功能都在对着一个假数验:观看阈值、进度条、片头片尾跳过。
#   为此白跑过一轮:阈值设 60% 明明该越线,自检说没越。
# ☠☠ 环形缓存钉在**下限 64MB**,而自检片是 83MB —— 于是它**永远装不下整片**。
#   这不是抠内存,是为了让「已缓存 / 没缓存」这个对比组**一直存在**:
#   缓存装得下整片的话,跑够久就全都在本地了,缩略图那几条断言当场失去对照
#   (2026-09-03 实测:同一份代码等 12 秒绿、等 22 秒红,代码一行没改)。
#   真实比例也是这样的 —— 512MB 的环 vs 一部 4GB 的电影。LP_RING=字节 覆盖。
#
# ★ 顺带给视频流限速(默认 2MB/s)。环回是无限快的 ——
#   不限速的话预取代理几秒就把整片拉完,「已缓存 / 没缓存」这个对比组
#   根本造不出来,而缩略图那几条断言全靠它。LP_KBPS=0 关掉。
CLIPSECS=""
if [ -n "$CLIP" ] && command -v ffprobe >/dev/null 2>&1; then
  CLIPSECS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$CLIP" 2>/dev/null || true)"
fi

# ★ 默认开 gzip:**真 Emby 默认就是压的**。不压的假服务器曾让
#   「手动设 Accept-Encoding 导致 Go 不自动解压」这个洞本地全绿。
GZ="-gzip"; [ "${LP_NOGZIP:-}" = "1" ] && GZ=""

echo "== 1/5 编核心层 =="
bash "$ROOT/scripts/build-core.sh" "$BIN" >/dev/null
echo "   lpcore.dll $(stat -c%s "$BIN/lpcore.dll") 字节"

echo "== 2/5 编壳 =="
# ☠ **编不过就地停**。2026-09-03 栽过一次:壳编译失败但脚本继续往下跑,
#   于是起的是**上一次**编出来的 exe —— 自检全绿,而改的那行代码根本没进去。
#   `set -e` 管得住这一句,但报错被 >/dev/null 吞了,只剩一个没有上下文的退出。
if ! ( cd "$APP" && dotnet build -c "$CONF" -v q --nologo ); then
  echo "!! 壳编译失败 —— 停在这里。再往下跑的话起的是上一次那个 exe,自检结果不算数。" >&2
  exit 1
fi

echo "== 3/5 起假 Emby =="
# ★ 先杀干净。两个 LinPlayer 一起跑的时候截图会拍到上一个(旧界面),
#   看起来就像「改了没生效」—— 这个坑踩过。
powershell -NoProfile -Command "Get-Process LinPlayer,fakeemby -EA SilentlyContinue | Stop-Process -Force" || true
go build -o "$ROOT/build/fakeemby.exe" ./core/cmd/fakeemby 2>/dev/null || \
  ( cd "$ROOT/core" && go build -o "$ROOT/build/fakeemby.exe" ./cmd/fakeemby )
"$ROOT/build/fakeemby.exe" -addr "127.0.0.1:$PORT" -clip "$CLIP" $GZ ${LP_NOAVATAR:+-no-avatar} ${LP_EPS:+-eps $LP_EPS} ${LP_NOBOXSET:+-no-boxset} ${LP_TRANSCODE:+-transcode-only} ${CLIPSECS:+-clip-secs $CLIPSECS} -clip-kbps "${LP_KBPS:-2048}" > "$ROOT/build/fakeemby.log" 2>&1 &
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
# ★★ LP_SRV2=1 再灌**第二台**服务器。
#   「按服务器定制」这类开关,只有一台服的时候**验不出对错**:
#   一行的列表和「只管当前那台」长得一模一样。
#   第二台故意指一个打不通的地址 —— 设置页只列它,不需要它活着。
SRV2=""
# ★ LP_HIDEBOX=1 关掉当前这台;=2 关掉**第二台**(验「关的不是当前那台」也列得对)
HIDEBOX=""
case "${LP_HIDEBOX:-}" in
  1) HIDEBOX="\"http://127.0.0.1:$PORT\"" ;;
  2) HIDEBOX="\"http://127.0.0.1:1\"" ;;
esac
[ -n "${LP_SRV2:-}" ] && SRV2=',{ "server": "http://127.0.0.1:1", "token": "t2", "user_id": "u2",
    "user_name": "第二个用户", "name": "自检用第二台", "lines": [], "active_line": 0 }'
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
  }$SRV2],
  "active": 0,
  "theme": "dark",
  "companion_enabled": true,
  "plugin_official_enabled": true,
  "prefs": {
    "watched_threshold_percent": ${LP_WATCHED:-90},
    "prefetch_cache_bytes": ${LP_RING:-67108864},
    "hide_collection_servers": [$HIDEBOX]
  }
}
JSON
fi
fi

# ★★ **每次都清掉图片缓存**。
#   核心层的 /img 通道把上游字节落盘缓存(userdata/cache/img),按 src 做键 ——
#   而自检里 src 是固定的 http://127.0.0.1:18096/Items/xxx/Images/...。
#   于是**改了假服务器画的图,界面上还是上一版那张**,而且一切正常:
#   命令绿、日志绿、诊断打出来的位图尺寸也对(旧图被放大到目标高度而已)。
#   2026-09-02 为此把「剧照没画出来」查了十几轮 —— 其实一直画着,只是画的是旧图。
#   缓存本身是对的(它省的就是回源),但**自检要的是这一版的字节**。
# LP_KEEPIMG=1:**不清**。量「第二次进首页有多快」时用 —— 清着量的永远是冷缓存。
# ★ 服务器图标缓存同理:它按 server_id 做键,而自检里 server_id 恒定 ——
#   改了假服务器给的图标(或者想验「头像 404 要退回官方图标」),
#   缓存不清的话一次 HTTP 都不会发,自检看到的永远是上一版那张。
# ★★ **元数据缓存(cache/meta)也要清** —— 2026-09-03 当场又栽了一次:
#   给假服务器补了「分集详情」的形状,界面上照样画的是电影版式,
#   因为 emby.itemDetail 的上一次结果还躺在盘上,而键里只有 server + item_id。
#   一般规律:**凡是改了夹具产出的内容而不是它的地址,
#   就得把中间所有按地址做键的缓存都清一遍**。现在是三层。
[ "${LP_KEEPIMG:-}" = "1" ] || rm -rf "$BIN/userdata/cache/img" "$BIN/userdata/cache/icons" "$BIN/userdata/cache/meta"
# ☠☠ 观看历史也要清。上一轮把自检片放到了片尾,history.json 就记着那个位置;
#   下一轮从详情页起播时它被当成续播位置传给 mpv —— `loadfile ... start=<片长>` ——
#   于是**起播即 EOF**:播放页当场判「播完」退出去,而这一切一条错都不报。
#   排查这个花了六轮自检:表面症状是「缩略图取不到本地缓存」,
#   真因是播放页退出时把本地代理一起收了。
rm -f "$BIN/userdata/history.json"

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
LP_CORELOG="${LP_CORELOG:-}" LP_SELFCHECK=1 LP_SELFCHECK_MENU="${LP_MENU:-}" LP_SELFCHECK_COUNT="${LP_COUNT:-}" LP_SELFCHECK_BOOM="${LP_BOOM:-}" LP_SELFCHECK_VERSION="${LP_VER:-}" LP_SELFCHECK_HERO="${LP_HERO:-}" LP_SELFCHECK_NAVHOVER="${LP_NAVHOVER:-}" LP_SELFCHECK_GLYPH="${LP_GLYPH:-}" LP_SELFCHECK_EPISODE="${LP_EP:-}" LP_SELFCHECK_COLLAPSE="${LP_COLLAPSE:-}" LP_SELFCHECK_FILL="${LP_FILL:-}" LP_SELFCHECK_SIDEBAR="${LP_SIDEBAR:-}" LP_SELFCHECK_SRVMENU="${LP_SRVMENU:-}" LP_SELFCHECK_RAIL="${LP_RAIL:-}" LP_SELFCHECK_CHROME="${LP_CHROME:-}" LP_SELFCHECK_OSDFADE="${LP_OSDFADE:-}" LP_SELFCHECK_RESUME="${LP_RESUME:-}" LP_SELFCHECK_RECLICK="${LP_RECLICK:-}" LP_SELFCHECK_SRVICON="${LP_SRVICON:-}" LP_SELFCHECK_THUMB="${LP_THUMB:-}" LP_SELFCHECK_HOME="${LP_HOME:-}" LP_SELFCHECK_HOMESET="${LP_HOMESET:-}" LP_SELFCHECK_WATCHED="${LP_WATCHED:-}" LP_SELFCHECK_PAGE="$PAGE" LP_SELFCHECK_MAXIMIZE="${LP_MAX:-}" LP_SELFCHECK_PLAYER_DRILL="${LP_DRILL:-}" LP_SELFCHECK_SCROLL="${LP_SCROLL:-}" LP_SELFCHECK_SOURCE="${LP_SRCKIND:-}" LP_SELFCHECK_CATALOG_DETAIL="${LP_CATDETAIL:-}" LP_SELFCHECK_SHADER="${LP_SHADER:-}" "$BIN/LinPlayer.exe" > "$ROOT/build/app.log" 2>&1 &
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

# ☠☠ **播放上报三件套**只在服务器那边看得见。
#   缺哪一件都是「看一半退出续播不落地」,而客户端一切正常:
#   Playing(起播) / Progress(播放中,原来**一次都没发过**) / Stopped(停播)。
if [ -n "$CLIP" ]; then
  for ep in Playing Playing/Progress Playing/Stopped; do
    n="$(grep -c "POST /Sessions/$ep " "$ROOT/build/fakeemby.log" || true)"
    if [ "${n:-0}" -gt 0 ]; then echo "[播放上报] ✓ $ep × $n"
    else echo "[播放上报] ✗ $ep 一次都没收到 —— 这一件缺了就是「看一半退出续播不落地」"; fi
  done
fi

# ★ 「标记已观看」这一半只在服务器那边看得见 —— 客户端日志里没有它。
if [ -n "${LP_WATCHED:-}" ]; then
  if grep -q "PlayedItems" "$ROOT/build/fakeemby.log"; then
    echo "[观看阈值] ✓ 服务器收到了标记已观看(PlayedItems)"
  else
    echo "[观看阈值] ✗ 服务器一次 PlayedItems 都没收到 —— 阈值只管了续播,没管标记"
  fi
fi

echo
echo "假 Emby 收到的请求:"
grep '  <-' "$ROOT/build/fakeemby.log" | sort | uniq -c | sort -rn
echo
echo "截图:build/$SHOT.png"
