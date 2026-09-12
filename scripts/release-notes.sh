#!/usr/bin/env bash
#
# 从提交历史生成更新说明。输出到 $1(默认 /tmp/notes.md)。
#
# ☠ 为什么要有这个脚本:原来发布说明是 workflow 里写死的一段话(下载在哪、
#   数据目录在哪),**每次发布一字不变**,而应用内的「更新说明」正是读它。
#   用户 2026-09-12:「优化更新 md,现在一直是固定的,牛头不对马嘴」。
#   固定文案最坏的地方不是没用,是它**看起来像更新说明** —— 用户读完会以为
#   这次就改了这些。
#
# 本地跑一遍看效果:bash scripts/release-notes.sh /tmp/notes.md && cat /tmp/notes.md
set -euo pipefail

OUT="${1:-/tmp/notes.md}"

# 列的是**上一个版本到这一版**的提交(预发布、正式版都算上一个)。
# 原来只认上一个正式版,于是 731~742 每一版都从 730 列起,清单越攒越长(用户 2026-09-13)。
# 从 HEAD~1 往回找:重跑时这一版自己的 tag 可能已经打上了,它不算「上一个」。
PREV=$(git describe --tags --abbrev=0 --match 'v*' HEAD~1 2>/dev/null || true)
RANGE="${PREV:+$PREV..}HEAD"

# 一行一条。合并提交不要 —— 它的标题是「Merge branch …」,对用户零信息。
RAW=$(git log --no-merges --pretty=format:'%s' "$RANGE" 2>/dev/null || true)

# `类型(范围): 说明` → `【范围】说明`;`类型: 说明` → `说明`。
# 保留范围是因为它就是「改的是哪一块」(PC / 移动端 / 弹幕 / 更新),
# 而 feat/fix 这种类型词对用户没有意义。
LINES=$(printf '%s\n' "$RAW" \
  | sed -E 's/^[a-zA-Z]+\(([^)]+)\): */【\1】/; s/^[a-zA-Z]+: *//' \
  | grep -v '^[[:space:]]*$' \
  | awk '!seen[$0]++' \
  | head -40)

{
  echo "## 本次更新"
  echo
  if [ -z "$LINES" ]; then
    # 一条都没有时**说清楚**,别留一片空白让人以为界面坏了
    echo "- 这一版没有代码改动(只重新打了一次包)。"
  else
    printf '%s\n' "$LINES" | sed 's/^/- /'
  fi
} > "$OUT"

echo "写好了 $OUT:"
cat "$OUT"
