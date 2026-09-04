#!/usr/bin/env bash
# 风格门禁 —— 查 CLAUDE.md §1.5 里能被机器查的那几条。
#
# 存在的理由:规范写在文档里不会有人去读,写在这里改坏了它会红。
# 用法:bash scripts/check-style.sh [--summary]
set -uo pipefail
cd "$(dirname "$0")/.."

D=apps/windows/LinPlayer.Desktop
SUM=${1:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
bad=0
sect() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cs()   { find "$D" -name '*.cs'    -not -path '*/obj/*' -not -path '*/bin/*'; }
xaml() { find "$D" -name '*.axaml' -not -path '*/obj/*' -not -path '*/bin/*'; }

fail() { bad=$((bad + 1)); echo "  ✗ $1"; }
pass() { echo "  ✓ $1"; }

# ---- 1. 注释块不超过 6 行 ----
# 只数**有正文**的行:`<summary>`、空 `///`、`<para>` 这些是语法不是水分。
sect "注释块 ≤ 6 行正文(超了说明代码该拆,不是该配更多解释)"
while read -r f; do
  awk -v F="$f" '
    function prose(l) {
      gsub(/^[ \t]*(\/\/\/|\/\/|\/\*|\*\/|\*)[ \t]*/, "", l)
      gsub(/<\/?(summary|para|list|item|remarks|returns|example)[^>]*>/, "", l)
      gsub(/[ \t]/, "", l)
      return length(l) > 0
    }
    # 一个 <summary> / 一个 <param> 各算一段:参数文档是接口契约,不是水分
    /^[ \t]*\/\/\/[ \t]*<(summary|param|returns|remarks|value|exception|typeparam)/ {
      if (p > 6) print p "\t" F ":" s
      s = NR; p = 0; c = 1; if (prose($0)) p++; next
    }
    /^[ \t]*(\/\/|\/\*|\*|\/\/\/)/ { if(!c) s=NR; c++; if(prose($0)) p++; next }
    { if(p>6) print p "\t" F ":" s; c=0; p=0 }
    END { if(p>6) print p "\t" F ":" s }
  ' "$f"
done < <(cs; xaml) | sort -rn > "$T/c"
if [ -s "$T/c" ]; then
  fail "$(wc -l < "$T/c") 处,最长 $(head -1 "$T/c" | cut -f1) 行"
  [ "$SUM" = --summary ] || head -10 "$T/c" | awk -F'\t' '{print "    " $1 " 行  " $2}'
else pass "没有"; fi

# ---- 2. 装饰符号每文件 ≤ 3 ----
sect "装饰符号(★ ☠ ⚠)每文件 ≤ 3(满屏星号 = 一个重点都没有)"
: > "$T/s"
while read -r f; do
  # 只数注释里的 —— 自检输出和 UI 文案里的 ⚠ / 评分的 ★ 是内容,不是装饰
  c=$(awk '
    /<!--/ { x=1 } /-->/ { print; x=0; next }
    x { print; next }
    /^[ \t]*(\/\/|\/\/\/|\*|\/\*)/ { print; next }
    /\/\// { sub(/^[^\/]*\/\//, ""); print }
  ' "$f" | grep -o '★\|☠\|⚠' | wc -l)
  [ "$c" -gt 3 ] && printf '%s\t%s\n' "$c" "$f" >> "$T/s"
done < <(cs; xaml)
if [ -s "$T/s" ]; then
  fail "$(wc -l < "$T/s") 个文件超标"
  [ "$SUM" = --summary ] || sort -rn "$T/s" | head -8 | awk -F'\t' '{print "    " $1 " 个  " $2}'
else pass "没有"; fi

# ---- 3. 圆角刻度 ----
sect "圆角刻度 0 / 6 / 10 / 999"
{ grep -rhoE 'CornerRadius\([0-9]+\)' $(cs) 2>/dev/null | grep -oE '[0-9]+'
  grep -rhoE 'CornerRadius="[0-9]+"|CornerRadius" Value="[0-9]+"' $(xaml) 2>/dev/null | grep -oE '[0-9]+'
} | grep -vx '0\|6\|10\|999' | sort -n | uniq -c > "$T/r"
if [ -s "$T/r" ]; then fail "刻度外的值:"; sed 's/^/    /' "$T/r"; else pass "没有"; fi

# ---- 4. 间距刻度:Spacing / Padding / Margin 同一把尺 ----
# Thickness 按**每个分量**判。>42 的数不是间距节奏而是「让开某个东西」的高度,
# 写成字面量对下一个读代码的人什么都不说 —— 必须是具名常量。
sect "间距刻度 0 / 2 / 6 / 10 / 14 / 18 / 26 / 34 / 42(Spacing + Padding + Margin)"
{ grep -rhoE '(Item|Line)?Spacing = [0-9]+' $(cs) 2>/dev/null | grep -oE '[0-9]+$'
  # 只认 Padding / Margin —— BorderThickness 也是 Thickness,但那是**边框宽度**不是间距,
  # 拿间距刻度去套它会把「极细发丝线」加粗一倍(2026-09-05 我就这么干过一次)
  grep -rhoE '(Padding|Margin) = new Thickness\([0-9.,[:space:]]+\)' $(cs) 2>/dev/null \
    | sed 's/.*new Thickness(//;s/)//' | tr ',' '\n'
  grep -rhoE 'Spacing="[0-9]+"' $(xaml) 2>/dev/null | grep -oE '[0-9]+'
  grep -rhoE '\b(Padding|Margin)="[0-9.,[:space:]]+"' $(xaml) 2>/dev/null | sed 's/.*="//;s/"//' | tr ',' '\n'
} | tr -d ' ' | grep -E '^[0-9]+$' > "$T/all"
grep -vx '0\|2\|6\|10\|14\|18\|26\|34\|42' "$T/all" | sort -n | uniq -c > "$T/p"
awk '$1 > 42' "$T/all" | sort -n | uniq -c > "$T/big"
if [ -s "$T/p" ]; then
  fail "刻度外的值:"; sed 's/^/    /' "$T/p"
  [ -s "$T/big" ] && echo "    ↑ 其中 >42 的不该写成字面数字,抽成具名常量"
else pass "没有"; fi

# ---- 5. 静默吞异常要说明理由(同行或上方 4 行内有注释即可) ----
sect "catch 吞掉异常必须说明「为什么可以静默」"
: > "$T/e"
while read -r f; do
  awk -v F="$f" '
    { L[NR]=$0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (L[i] !~ /catch *\{ *(return[^}]*)?\}/) continue
        if (L[i] ~ /\/\//) continue
        ok = 0
        for (j = i-4; j < i; j++) if (j > 0 && L[j] ~ /\/\/|\/\*|\*|\/\/\//) ok = 1
        if (!ok) print F ":" i "  " L[i]
      }
    }' "$f" >> "$T/e"
done < <(cs)
if [ -s "$T/e" ]; then
  fail "$(wc -l < "$T/e") 处没写理由"
  [ "$SUM" = --summary ] || sed 's/^/    /' "$T/e" | head -8
else pass "没有"; fi

# ---- 6. 颜色:不透明色号一律走 token ----
# 允许写死的只有**带 alpha 的叠加色**(#aarrggbb):那底下是画面不是背景色。
sect "颜色走 token(只有带 alpha 的叠加色允许写死)"
: > "$T/col"
grep -rnoE 'SolidColorBrush\(Color\.Parse\("#[0-9a-fA-F]+"\)' $(cs) 2>/dev/null \
  | grep -E '#[0-9a-fA-F]{6}"\)$' >> "$T/col"
# 属性形式(Background="#…")和 Setter 形式(<Setter … Value="#…"/>)都要查
grep -rnoE '(Background|Foreground|BorderBrush|Value)="#[0-9a-fA-F]+"' $(xaml) 2>/dev/null \
  | grep -E '#[0-9a-fA-F]{6}"$' >> "$T/col"
if [ -s "$T/col" ]; then
  fail "$(wc -l < "$T/col") 处不透明硬编码(换浅色主题就露馅)"
  [ "$SUM" = --summary ] || sed 's/^/    /' "$T/col" | head -10
else pass "没有"; fi

echo
if [ "$bad" -gt 0 ]; then echo "✗ $bad / 6 项不达标"; exit 1; fi
echo "✓ 6 项全过"
