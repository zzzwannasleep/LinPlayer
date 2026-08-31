#!/usr/bin/env bash
# 绑定层门禁(TODO B2.4)。
#
#   bash scripts/check-bindings.sh
#
# 四关:
#   1. 产物是最新的        —— 改了 COMMANDS.md 忘了重跑生成器 = 绑定里少一条命令
#   2. C# 编得过
#   3. Kotlin 编得过
#   4. 四方比对            —— COMMANDS.md ↔ Go 注册表 ↔ C# ↔ Kotlin
#
# 第 4 关是这套东西存在的理由:命令名是**字符串**,拼错了编译器不管,
# 表现是「点了没反应」。266 × 3 = 798 次抄写机会,靠人眼是守不住的。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/env.sh"

fail=0
step() { echo; echo "===== $* ====="; }

step "1. 产物是否最新"
python "$ROOT/scripts/gen-bindings.py" --check || fail=$((fail + 1))

step "2. C# 编译"
( cd "$ROOT/bindings/csharp" && dotnet build -c Release --nologo 2>&1 | tail -4 ) || fail=$((fail + 1))

step "3. Kotlin 编译"
# 借安卓工程的 gradle wrapper —— 单独再装一份 Kotlin 工具链不值当。
GRADLEW="$ROOT/apps/android/gen/android/gradlew"
if [ -x "$GRADLEW" ]; then
  if "$GRADLEW" -p "$ROOT/bindings/kotlin" compileKotlin -q; then
    echo "Kotlin 编译通过。"
  else
    echo "Kotlin 编译失败。"
    fail=$((fail + 1))
  fi
else
  # ★ 不静默跳过。「环境里没有就当过了」正是假绿的一类(夹具不真实)。
  echo "!! 找不到 $GRADLEW —— Kotlin 这一关**没验**,不要当它过了。"
  fail=$((fail + 1))
fi

step "4. 四方比对(COMMANDS.md ↔ Go 注册表 ↔ C# ↔ Kotlin)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python "$ROOT/scripts/dump-command-names.py" "$ROOT" "$TMP" || fail=$((fail + 1))

# Go 注册表:cgo 出来的可执行文件要找得到 libmpv,否则起不来(0xc0000135)。
#
# ★ LC_ALL=C 不能省:导出脚本按码点排,系统 sort 默认按语言环境排
#   (会忽略标点、还可能不分大小写)。两种顺序混用时 comm 会把**每一条**
#   都报成差异,看起来像「Go 里全是野命令」—— 第一版就是这么红的。
( cd "$ROOT/core" && PATH="$ROOT/crates/mpv/libmpv:$PATH" go run ./cmd/listcommands ) \
  | LC_ALL=C sort > "$TMP/go.txt"

cmp_sets() { # $1=名字 $2=实际 $3=期望
  if diff -u "$3" "$2" > "$TMP/d" 2>&1; then
    echo "  $1:与 COMMANDS.md 完全一致($(grep -c . "$2") 条)"
  else
    echo "  $1:与 COMMANDS.md 对不上 ——"
    sed -n '4,24p' "$TMP/d" | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}
cmp_sets "C#    " "$TMP/cs.txt" "$TMP/md.txt"
cmp_sets "Kotlin" "$TMP/kt.txt" "$TMP/md.txt"

# ★ Go 侧现在只移植了一部分,所以要求的是**子集**不是相等:
#   Go 里有而 COMMANDS.md 里没有的 = 野命令(三端绑定里根本调不到它),必须红。
#   反过来(还没移植的)不算错 —— 迁移完成时改成相等,那条写在 B3 出口判据里。
# ★ debug.* 不进契约,是**设计如此**:那是探针 / 自检用的命令(SPEC §5 的 debug 组),
#   由 LP_DEBUG_CMDS 门控,三端绑定里不该出现它们。所以比对前先摘掉。
#   反过来说:凡是产品要用的命令,名字里就不许带 debug —— 一旦带了,
#   它会**静默地**从三端绑定里消失,而这个门禁还是绿的。
ORPHAN="$(LC_ALL=C comm -23 "$TMP/go.txt" "$TMP/md.txt" | grep -v "^debug\.")"
if [ -n "$ORPHAN" ]; then
  echo "  Go 注册表里有 COMMANDS.md 没有的命令(三端绑定调不到它):"
  echo "$ORPHAN" | sed 's/^/    /'
  fail=$((fail + 1))
else
  echo "  Go    :$(grep -c . "$TMP/go.txt") / $(grep -c . "$TMP/md.txt") 条已注册,无野命令"
fi

echo
if [ $fail -eq 0 ]; then echo "绑定层门禁:全部通过。"; else echo "绑定层门禁:$fail 关不通过。"; fi
exit $fail
