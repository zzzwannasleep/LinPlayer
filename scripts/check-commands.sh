#!/usr/bin/env bash
# 门禁一:每个 #[tauri::command] 都必须注册进 generate_handler![]。
# 门禁二:安卓那份**独立拷贝**不能悄悄少掉桌面已有的 source_* / plugin_* 命令。
#
# 为什么要有门禁一:写了命令忘了注册,cargo 照样编过、零警告,但前端 invoke 直接报
# "command not found" —— 是个只有跑起来点到那个按钮才会发现的静默失败。
# 已经真实漏过一次(plugin_ui_respond:插件 ctx.ui 的唯一回填口,注册漏了,整条链是断的)。
#
# 为什么要有门禁二:apps/android/src/lib.rs 是 apps/desktop/src/lib.rs 的手工拷贝
# (源后端工厂表、source_* 命令都各有一份)。桌面加一条、安卓忘了加,**桌面 CI 全绿**,
# 而手机端点到那个功能才报 command not found。Stremio 源当年就是这么漏的
# (source_login 安卓侧压根没注册)。本机编不了安卓(要 NDK),所以只能静态比。
#
# 用法:bash scripts/check-commands.sh   (在仓库根下跑)
set -euo pipefail

SRC="apps/desktop/src/lib.rs"
[ -f "$SRC" ] || { echo "找不到 $SRC —— 请在仓库根目录下运行"; exit 2; }

# 定义:紧跟在 #[tauri::command] 后面的 fn 名。
# ★ 必须扫**整个 apps/<端>/src**,不能只扫 lib.rs:命令也定义在 pluginmarket.rs /
#   updater.rs 等同级模块里。只扫 lib.rs 的话那些命令会被判成「注册了但没定义」——
#   于是脚本长期红着,而**长期红的门禁等于没有门禁**:真漏注册的那条会淹没在噪音里。
#
# ★ 用 awk 状态机而不是 grep -B1:`#[tauri::command]` 和 `fn` 之间**允许夹别的行**
#   (行注释、#[allow(...)] 等),-B1 只看一行就会漏掉它们(icon_library 就是这么漏的)。
#
# (2026-07-26 修:此前 7 个假阳性 + 漏检 1 个。)
scan_defined() {
  awk '
    /#\[tauri::command\]/ { armed = 1; next }
    armed && /^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+[A-Za-z_]/ {
      match($0, /fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)
      name = substr($0, RSTART, RLENGTH); sub(/^fn[[:space:]]+/, "", name)
      print name; armed = 0; next
    }
    # 夹在中间的注释/属性行不打断配对;真遇到别的代码行才放弃
    armed && /^[[:space:]]*($|\/\/|#\[|\/\*|\*)/ { next }
    armed { armed = 0 }
  ' "$@" | sort -u
}

# 注册:generate_handler![ ... ] 之间的裸标识符。
# 逗号是**可选**的:列表最后一项通常没有尾逗号(plugin_market_install 就因此被漏读,
# 反过来被报成「定义了但没注册」——一个纯属解析造成的假警报)。
scan_registered() {
  local f="$1"
  local start end
  start=$(grep -n "generate_handler!\[" "$f" | head -1 | cut -d: -f1)
  end=$(awk -v s="$start" 'NR>s && /^[[:space:]]*\]\)/ {print NR; exit}' "$f")
  [ -n "${end:-}" ] || { echo "解析不出 $f 的 generate_handler 结束行 —— 本脚本的假设失效了,别信它的结论" >&2; exit 2; }
  sed -n "$((start+1)),$((end-1))p" "$f" | grep -oP '^\s+\K\w+(?=,?\s*$)' | sort -u
}

defined=$(scan_defined apps/desktop/src/*.rs)
registered=$(scan_registered "$SRC")

echo "桌面: defined=$(echo "$defined" | wc -l)  registered=$(echo "$registered" | wc -l)"

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

# ── 门禁二:安卓拷贝不能落下桌面已有的源 / 插件命令 ──────────────────────
# 只盯 source_* 和 plugin_* 这两族:它们是**明确要求三端一致**的(同一套前端页面在
# 手机端也要能用)。其余命令有真实的端差异(窗口 chrome、文件选择器、mpv 子窗口…),
# 全量比会长期红 —— 长期红的门禁等于没有门禁。
ANDROID="apps/android/src/lib.rs"
if [ -f "$ANDROID" ]; then
  a_defined=$(scan_defined apps/android/src/*.rs)
  a_registered=$(scan_registered "$ANDROID")
  echo "安卓: defined=$(echo "$a_defined" | wc -l)  registered=$(echo "$a_registered" | wc -l)"

  a_orphan=$(comm -23 <(echo "$a_defined") <(echo "$a_registered"))
  if [ -n "$a_orphan" ]; then
    echo "❌ 安卓侧定义了但没注册:"
    echo "$a_orphan" | sed 's/^/   /'
    rc=1
  fi

  # 白名单:确属只做 PC 的能力。加一条就要在这里写清楚为什么。
  ANDROID_EXEMPT=$(printf '%s\n' \
    plugin_pick_install \
    plugin_pick_dev_dir \
    | sort -u)
  # ↑ 两条都是**系统文件选择器**。安卓上装插件走市场(plugin_market_install),
  #   没有「挑一个本地 .ipk / 开发目录」这回事。

  shared=$(echo "$registered" | grep -E '^(source|plugin)_' | comm -23 - <(echo "$ANDROID_EXEMPT") || true)
  a_shared=$(echo "$a_registered" | grep -E '^(source|plugin)_' || true)
  missing=$(comm -23 <(echo "$shared") <(echo "$a_shared"))
  if [ -n "$missing" ]; then
    echo "❌ 桌面有、安卓没有的 source_/plugin_ 命令(手机端点到就报 command not found):"
    echo "$missing" | sed 's/^/   /'
    echo "   —— 若确属只做 PC 的能力,把它加进本脚本的 ANDROID_EXEMPT 白名单并写明原因。"
    rc=1
  fi
fi

[ $rc -eq 0 ] && echo "✅ 命令注册与三端一致性均通过"
exit $rc
