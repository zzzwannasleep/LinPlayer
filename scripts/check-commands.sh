#!/usr/bin/env bash
# 门禁:每个 #[tauri::command] 都必须注册进 generate_handler![]。
#
# 为什么要有这个:写了命令忘了注册,cargo 照样编过、零警告,但前端 invoke 直接报
# "command not found" —— 是个只有跑起来点到那个按钮才会发现的静默失败。
# 已经真实漏过一次(plugin_ui_respond:插件 ctx.ui 的唯一回填口,注册漏了,整条链是断的)。
#
# 用法:bash scripts/check-commands.sh   (在仓库根下跑)
set -euo pipefail

SRC="apps/desktop/src/lib.rs"
[ -f "$SRC" ] || { echo "找不到 $SRC —— 请在仓库根目录下运行"; exit 2; }

# 定义:紧跟在 #[tauri::command] 后面的 fn 名。
# ★ 必须扫**整个 apps/desktop/src**,不能只扫 lib.rs:命令也定义在 pluginmarket.rs /
#   updater.rs 等同级模块里。只扫 lib.rs 的话那些命令会被判成「注册了但没定义」——
#   于是脚本长期红着,而**长期红的门禁等于没有门禁**:真漏注册的那条会淹没在噪音里。
#
# ★ 用 awk 状态机而不是 grep -B1:`#[tauri::command]` 和 `fn` 之间**允许夹别的行**
#   (行注释、#[allow(...)] 等),-B1 只看一行就会漏掉它们(icon_library 就是这么漏的)。
#
# (2026-07-26 修:此前 7 个假阳性 + 漏检 1 个。)
defined=$(awk '
  /#\[tauri::command\]/ { armed = 1; next }
  armed && /^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+[A-Za-z_]/ {
    match($0, /fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)
    name = substr($0, RSTART, RLENGTH); sub(/^fn[[:space:]]+/, "", name)
    print name; armed = 0; next
  }
  # 夹在中间的注释/属性行不打断配对;真遇到别的代码行才放弃
  armed && /^[[:space:]]*($|\/\/|#\[|\/\*|\*)/ { next }
  armed { armed = 0 }
' apps/desktop/src/*.rs | sort -u)

# 注册:generate_handler![ ... ] 之间的裸标识符。
start=$(grep -n "generate_handler!\[" "$SRC" | head -1 | cut -d: -f1)
end=$(awk -v s="$start" 'NR>s && /^        \]\)/ {print NR; exit}' "$SRC")
[ -n "${end:-}" ] || { echo "解析不出 generate_handler 的结束行 —— 本脚本的假设失效了,别信它的结论"; exit 2; }
# 逗号是**可选**的:列表最后一项通常没有尾逗号(plugin_market_install 就因此被漏读,
# 反过来被报成「定义了但没注册」——一个纯属解析造成的假警报)。
registered=$(sed -n "$((start+1)),$((end-1))p" "$SRC" | grep -oP '^\s+\K\w+(?=,?\s*$)' | sort -u)

echo "defined=$(echo "$defined" | wc -l)  registered=$(echo "$registered" | wc -l)"

orphan=$(comm -23 <(echo "$defined") <(echo "$registered"))
ghost=$(comm -13 <(echo "$defined") <(echo "$registered"))

rc=0
if [ -n "$orphan" ]; then
  echo "❌ 定义了但没注册(前端 invoke 会报 command not found):"
  echo "$orphan" | sed 's/^/   /'
  rc=1
fi
if [ -n "$ghost" ]; then
  echo "❌ 注册了但没定义(应该编译期就炸,炸不了说明本脚本解析错了):"
  echo "$ghost" | sed 's/^/   /'
  rc=1
fi
[ $rc -eq 0 ] && echo "✅ 全部命令均已注册"
exit $rc
