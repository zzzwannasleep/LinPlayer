#!/usr/bin/env bash
# 拿**真 Emby 服务器**跑一遍 Windows 端。
#
# ★★ 红线:这个脚本里**一个真实地址 / 账号 / 密码都没有**,全部从一个
#   不进版本控制的凭据文件读(仓库的 .gitignore 已经挡住 `*.env`)。
#   凭据文件格式 —— 每台三行,空行分隔,可以放多台:
#
#       https://你的服务器
#       用户名
#       密码
#
#       https://另一台
#       ...
#
# 为什么假 Emby 之外还要这个:假服务器只能造出**我想到的**形状。
# 真服务器上才有 fork 的缺胳膊少腿(实测服务器1 的 /Tags 和 /OfficialRatings
# 直接 404)、真实的库规模、真实的转码/直连决策、真实的证书。
#
#   bash scripts/selfcheck-real.sh <第几台> [页面] [凭据文件]
#
# 例:bash scripts/selfcheck-real.sh 1            # 第一台,登录后停在首页
#     bash scripts/selfcheck-real.sh 2 library    # 第二台,落到媒体库页
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDX="${1:-1}"
PAGE="${2:-}"
ENVF="${3:-$ROOT/2.env}"
APP="$ROOT/apps/windows/LinPlayer.Desktop"
BIN="$APP/bin/Debug/$(grep -oP "(?<=<TargetFramework>)[^<]+" "$APP/LinPlayer.Desktop.csproj")"

[ -f "$ENVF" ] || { echo "没有凭据文件:$ENVF"; exit 1; }

# 读第 IDX 台的三行。★ 只放进变量,**不回显** —— 别让密码进终端记录。
mapfile -t L < <(grep -vE '^\s*$' "$ENVF")
OFF=$(( (IDX - 1) * 3 ))
SRV="${L[$OFF]:-}"; USR="${L[$((OFF+1))]:-}"; PWD_="${L[$((OFF+2))]:-}"
[ -n "$SRV" ] || { echo "凭据文件里没有第 $IDX 台"; exit 1; }

source "$ROOT/scripts/env.sh"

echo "== 1/4 编核心层 =="
bash "$ROOT/scripts/build-core.sh" "$BIN" >/dev/null

echo "== 2/4 编壳 =="
( cd "$APP" && dotnet build -v q --nologo >/dev/null )

echo "== 3/4 清掉上一次的账号(要走真的登录那条路)=="
powershell -NoProfile -Command "Get-Process LinPlayer -EA SilentlyContinue | Stop-Process -Force" 2>/dev/null || true
rm -rf "$BIN/userdata"
mkdir -p "$BIN/userdata"

echo "== 4/4 起 exe,真登录第 $IDX 台 =="
WANT="login:$SRV|$USR|$PWD_"
[ -n "$PAGE" ] && AFTER="$PAGE" || AFTER=""
LP_SELFCHECK=1 LP_SELFCHECK_PAGE="$WANT" LP_SELFCHECK_AFTER="$AFTER" \
  "$BIN/LinPlayer.exe" > "$ROOT/build/real-app.log" 2>&1 &

# 真服务器比假的慢得多:库大、要走公网、可能还要转码探测
sleep "${LP_WAIT:-20}"
# ★ 页面名里可能有冒号(player:12345),**Windows 文件名不许有冒号** ——
#   直接拼进去的话 PowerShell 保存会失败,而脚本还照样打印「截图:...」。
SAFE="$(printf '%s' "${PAGE:-}" | tr -c 'a-zA-Z0-9_-' '_')"
OUT="$ROOT/build/real-$IDX${SAFE:+-$SAFE}.png"
powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/shot-window.ps1" \
  -ProcName LinPlayer -Out "$OUT"

powershell -NoProfile -Command "
  \$p = Get-Process LinPlayer -EA SilentlyContinue
  if (\$p) { \$null = \$p.CloseMainWindow(); if (-not \$p.WaitForExit(8000)) { \$p.Kill() } }" || true

echo "截图:$OUT"
[ -f "$OUT" ] || { echo "!! 截图没落盘"; exit 3; }
