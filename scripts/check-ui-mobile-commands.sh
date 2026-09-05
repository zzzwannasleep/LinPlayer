#!/usr/bin/env bash
# 门禁:UI_MOBILE.md 里提到的每个命令名都必须在 COMMANDS.md 里真的存在。
#
#   bash scripts/check-ui-mobile-commands.sh
#
# 存在的理由:命令名是**字符串**,拼错了编译器不管 —— 表现是「点了没反应」。
# 规格文档写错一个名字,后面十五页都会照着抄。
set -uo pipefail
cd "$(dirname "$0")/.."

DOC=docs/go-migration/UI_MOBILE.md
SRC=docs/go-migration/COMMANDS.md

# COMMANDS.md 里的真名:表格第二列那个反引号包着的 <域>.<动作>
grep -oE '\| `[a-z]+\.[a-zA-Z]+`' "$SRC" | tr -d '|` ' | sort -u > /tmp/lp-cmds-real.txt

# UI_MOBILE.md 里出现的所有 `<域>.<动作>` 形状的反引号片段。
# 只认已知的命令域前缀 —— 否则 `player.status`(事件名)和 `data.invalidate`
# 这类非命令也会被当成命令查。事件名在下面单列白名单。
grep -oE '`(emby|account|player|source|danmaku|plugin|download|sync|translate|prefs|system)\.[a-zA-Z]+`' "$DOC" \
  | tr -d '`' | sort -u > /tmp/lp-cmds-doc.txt

# 事件名不是命令(SPEC §5.5),它们从事件队列来,不进命令表
EVENTS='player.status|player.tracks|player.ended|download.progress|prefetch.stats|source.qr|plugin.ui|plugin.toast|config.changed|account.status|update.available'
# 同形不同物:Gradle 的插件 id 也长成 `<域>.<名字>` 的样子
NOT_COMMANDS='plugin.compose|plugin.serialization'

bad=0
while read -r c; do
  [ -z "$c" ] && continue
  echo "$c" | grep -qE "^($EVENTS)$" && continue
  echo "$c" | grep -qE "^($NOT_COMMANDS)$" && continue
  # 文档里明说「不存在」的那几条(SPEC 提到但命令表里没有的),放行 ——
  # 它们正是本门禁要暴露的事实,已经写在文档里了,不该再红一次。
  grep -n "\`$c\`" "$DOC" | grep -q "不存在" && continue
  grep -qx "$c" /tmp/lp-cmds-real.txt || { echo "  ✗ UI_MOBILE.md 提到 \`$c\`,但 COMMANDS.md 里没有"; bad=$((bad+1)); }
done < /tmp/lp-cmds-doc.txt

n=$(wc -l < /tmp/lp-cmds-doc.txt)
if [ "$bad" = 0 ]; then
  echo "✓ UI_MOBILE.md 引用的 $n 个命令名全部在 COMMANDS.md 里"
else
  echo "✗ $bad 个命令名对不上"
  exit 1
fi
