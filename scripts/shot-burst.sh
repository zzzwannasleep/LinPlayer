#!/usr/bin/env bash
# 连拍:同一个窗口连续截 N 张,报相邻两张差了多少像素。
#
# 存在的理由:「画面抽搐」是帧和帧之间的关系,一张截图量不出来。但**暂停的时候
# 画面本该一动不动** —— 这时候连拍如果每张都不一样,那就是抽搐本身,而且是客观的。
# 用法:bash scripts/shot-burst.sh <前缀> <张数> <间隔毫秒>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="${1:-burst}"; N="${2:-8}"; MS="${3:-120}"; ZONE="${4:-}"; WHAT="${5:-画面}"
for i in $(seq 1 "$N"); do
  powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/shot-window.ps1" \
    -ProcName LinPlayer -Out "$ROOT/build/$P-$i.png" >/dev/null 2>&1
  powershell -NoProfile -Command "Start-Sleep -Milliseconds $MS" >/dev/null 2>&1
done
PYTHONUTF8=1 python "$ROOT/scripts/burst-diff.py" "$ROOT/build" "$P" "$N" "$ZONE" "$WHAT"
