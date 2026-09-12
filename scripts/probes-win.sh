#!/usr/bin/env bash
#
# 把 PC 壳那几个探针一次跑完。
#
# 为什么要有这个:探针本来只写在 docs/lessons 里,谁都得先想起它叫什么名字才跑得动
# —— 三个月后没人记得。一条命令能跑完,它们才算门禁。
#
#   bash scripts/probes-win.sh          # 用已经编好的 Debug 产物
#   bash scripts/probes-win.sh --build  # 先编一次
#
# ⚠ 轨道探针会**开一个真窗口**(没有可视根时 ScrollViewer 的 Extent 恒为 0,
#   那样每一句断言都是假绿)。所以这套不进 CI,跟 selfcheck-win.sh 一样手跑。
set -uo pipefail
cd "$(dirname "$0")/.."

PROJ=apps/windows/LinPlayer.Desktop/LinPlayer.Desktop.csproj
EXE=apps/windows/LinPlayer.Desktop/bin/Debug/net10.0/LinPlayer.exe

if [ "${1:-}" = "--build" ]; then
  dotnet build "$PROJ" -c Debug -v q --nologo || exit 1
fi
[ -x "$EXE" ] || { echo "没有 $EXE —— 先跑一次 bash scripts/probes-win.sh --build"; exit 1; }

BAD=0
run() { # run <环境变量名> <人话名字>
  echo "── $2 ($1) ──"
  if env "$1=1" "$EXE"; then echo "   ✓ $2"; else echo "   ✗ $2"; BAD=$((BAD + 1)); fi
  echo
}

run LP_SCALEPROBE  "响应式缩放曲线"
run LP_SCROLLPROBE "滚动驱动器退不退得出死角"
run LP_NETPROBE    "顶栏网速读数"
run LP_KEYPROBE    "按键翻成 mpv 键名(input.conf 生效的入口)"
run LP_EPMETAPROBE "分集卡那行小字(分辨率/码率/大小)"
run LP_MEDIAPROBE  "媒体信息卡每条流写哪几行"
run LP_RAILPROBE   "选集轨道:翻页到头再回来 + 长按拖动"

if [ "$BAD" -eq 0 ]; then echo "探针全部通过。"; else echo "$BAD 组探针不过。"; fi
exit "$BAD"
