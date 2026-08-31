#!/usr/bin/env bash
# 核心层门禁。推之前跑这个。
#
#   bash scripts/check-core.sh
#
# 五关,任意一关红就退非零:
#   1. go vet + go test        —— 核心层单测
#   2. 出库                    —— c-shared 编得出来
#   3. FFI 契约                —— 生成的头文件与 SPEC §5.1 逐条一致
#   4. 契约测试(C# 宿主侧)   —— 35 条判据,覆盖 §5.0/§5.2/§5.3/§5.4/§5.7/§5.10/§5.11
#   5. 差分对账              —— Go 侧输出与黄金实现(Rust)逐字段一致
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/env.sh"

fail=0
step() { echo; echo "===== $* ====="; }

step "1. go vet + go test"
( cd "$ROOT/core" && go vet ./... && go test ./... ) || fail=$((fail + 1))

step "2. 出库"
bash "$ROOT/scripts/build-core.sh" >/dev/null || fail=$((fail + 1))

step "3. FFI 契约(头文件 vs SPEC §5.1)"
python "$ROOT/scripts/check-ffi-contract.py" || fail=$((fail + 1))

step "4. 契约测试(C# 宿主侧)"
CHECK="$ROOT/tools/corecheck/bin/Release/net10.0/corecheck.exe"
if [ ! -x "$CHECK" ]; then
  ( cd "$ROOT/tools/corecheck" && dotnet build -c Release --nologo >/dev/null )
fi
# LP_DEBUG_CMDS=1 才有 debug.* —— panic 边界那三条判据靠它们
LP_DEBUG_CMDS=1 "$CHECK" "$ROOT/build/core/lpcore.dll" | tail -20
rc=${PIPESTATUS[0]}
[ "$rc" = "0" ] || fail=$((fail + 1))

step "5. 差分对账(vs 黄金实现)"
( cd "$ROOT/core" && go run ./cmd/diffcheck ) || fail=$((fail + 1))

echo
if [ $fail -eq 0 ]; then echo "核心层门禁:全部通过。"; else echo "核心层门禁:$fail 关不通过。"; fi
exit $fail
