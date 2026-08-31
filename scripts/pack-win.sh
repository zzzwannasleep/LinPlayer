#!/usr/bin/env bash
# 出 Windows 绿色包。
#
# 「绿色」= 解压即用、**数据全在 exe 同级 userdata/**、卸载 = 删目录(SPEC §10.1)。
# 所以:
#   · self-contained 发布 —— 用户机器上不装 .NET
#   · 不写注册表、不写用户目录
#   · lpcore.dll / libmpv-2.dll 与 exe 同级
#
#   bash scripts/pack-win.sh [输出目录]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/pack}"
APP="$ROOT/apps/windows/LinPlayer.Desktop"
STAGE="$OUT/LinPlayer"

source "$ROOT/scripts/env.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "== 1/3 编核心层 =="
bash "$ROOT/scripts/build-core.sh" "$STAGE" >/dev/null
# ★ lpcore.h 是给宿主开发用的,不进发行包
rm -f "$STAGE/lpcore.h"

echo "== 2/3 发布外壳(self-contained)=="
dotnet publish "$APP" -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=false -p:DebugType=none \
  -o "$STAGE" --nologo -v q >/dev/null

echo "== 3/3 打包 =="
# ★ 发行包里**不许**有 userdata/:带上去等于把自检账号发给用户
rm -rf "$STAGE/userdata"
VER="$(grep -oP '(?<=<Version>)[^<]+' "$APP/LinPlayer.Desktop.csproj" 2>/dev/null || echo 0.1.0)"
ZIP="$OUT/LinPlayer-win-x64-$VER.zip"
rm -f "$ZIP"
powershell -NoProfile -Command \
  "Compress-Archive -Path '$(cygpath -w "$STAGE")' -DestinationPath '$(cygpath -w "$ZIP")' -CompressionLevel Optimal"

echo
echo "产物:$ZIP  ($(du -m "$ZIP" | cut -f1) MB)"
echo "目录:$STAGE"
ls "$STAGE" | grep -E '\.(exe|dll)$' | head
