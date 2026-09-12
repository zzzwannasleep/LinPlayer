#!/usr/bin/env bash
#
# 从提交历史生成更新说明。
#
#   bash scripts/release-notes.sh <输出文件> [pre|stable]     (模式默认 pre)
#
# ☠ 为什么要有这个脚本:原来发布说明是 workflow 里写死的一段话(下载在哪、
#   数据目录在哪),**每次发布一字不变**,而应用内的「更新说明」正是读它。
#   用户 2026-09-12:「优化更新 md,现在一直是固定的,牛头不对马嘴」。
#   固定文案最坏的地方不是没用,是它**看起来像更新说明** —— 用户读完会以为
#   这次就改了这些。
#
# 本地跑一遍看效果:bash scripts/release-notes.sh /tmp/notes.md pre && cat /tmp/notes.md
set -euo pipefail

OUT="${1:-/tmp/notes.md}"
MODE="${2:-pre}"

# 对比的是**这个渠道的用户上一个装到的版本**,两个渠道不是同一个:
#   pre    —— 从上一个发布升上来(预发布、正式版都算)。原来一律对比上一个正式版,
#             于是 731~742 每一版都写「对比 build730」,清单一版比一版长(用户 2026-09-13)。
#   stable —— 从上一个正式版升上来。中间的预发布他没装过,只对比上一个预发布会漏掉整段。
# 从 HEAD~1 往回找:这一版自己的 tag(重跑时可能已经打上了)不能算「上一个」。
case "$MODE" in
  pre)    PREV=$(git describe --tags --abbrev=0 --match 'v*' HEAD~1 2>/dev/null || true) ;;
  stable) PREV=$(git describe --tags --abbrev=0 --match 'v*' --exclude '*-pre' HEAD~1 2>/dev/null || true) ;;
  *)      echo "未知模式:$MODE(只认 pre / stable)" >&2; exit 2 ;;
esac

if [ -n "$PREV" ]; then
  RANGE="$PREV..HEAD"
else
  RANGE="HEAD"
fi

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

N=$(printf '%s\n' "$RAW" | grep -c '' || true)

{
  echo "## 本次更新"
  echo
  if [ -z "$LINES" ]; then
    # 一条都没有时**说清楚**,别留一片空白让人以为界面坏了
    echo "- 这一版没有代码改动(只重新打了一次包)。"
  else
    printf '%s\n' "$LINES" | sed 's/^/- /'
  fi
  echo
  if [ -n "$PREV" ]; then
    echo "共 $N 次提交,对比 $PREV。"
  fi
} > "$OUT"

echo "写好了 $OUT:"
cat "$OUT"
