#!/usr/bin/env bash
# 校验 .github/workflows/*.yml 里每个 `run:` 块的 **shell 语法**。
#
# 为什么单独要这个:`yaml.safe_load` 过不代表脚本是好的。
# 用脚本批量改 workflow 时切多了几行,结果是
#     run: |
#       if [ ! -d x ]; then          <-- then 之后全没了
# 这仍然是**完全合法的 YAML**,只有 runner 跑到那一步才报
#     syntax error: unexpected end of file
# 烧掉一整轮 CI 才发现。本项目已经这样栽过两次(一次回车符混进脚本,一次切多了行)。
#
# 只查 bash/sh 的块;pwsh 的块跳过(要 PowerShell 才能解析,本地不一定有)。
#
# 用法:bash scripts/check-workflows.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# ★ 临时目录用 mktemp,不写死 /tmp —— Windows 上的 python 会把 "/tmp" 解释成
#   盘符根下的 tmp 目录,而它通常不存在,直接 FileNotFoundError。
#   路径经环境变量传给 python,避免在 python 源码里出现 Windows 路径分隔符。
# ★ 不能只靠 `command -v` 挑解释器。Windows 上 `python3` 会命中微软商店的**空壳**
#   (WindowsApps 里那个),它什么都不干、直接退出 49 —— 而 command -v 认为它存在。
#   所以逐个**实跑一下**,谁真能执行用谁。CI(ubuntu)上是 python3,本地是 python。
# ★ 内联 python 打的是中文。Windows runner 上 Python 默认按 cp1252 输出,
#   遇到中文当场 UnicodeEncodeError,而本地(GBK/UTF-8)复现不出来 ——
#   2026-09-04 新 CI 第一次跑就栽在同一个坑上(那次是 check-ffi-contract.py)。
#   PYTHONIOENCODING 的优先级比 PYTHONUTF8 高,所以直接钉它。
export PYTHONIOENCODING=utf-8
PY_BIN=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import yaml" >/dev/null 2>&1; then
    PY_BIN="$c"; break
  fi
done
[ -n "$PY_BIN" ] || { echo "找不到带 PyYAML 的 python(pip install pyyaml)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export WORK

"$PY_BIN" - <<'PY'
import yaml, glob, json, os

out = []
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f, encoding='utf-8'))
    for jname, job in (d.get('jobs') or {}).items():
        job_shell = ((job.get('defaults') or {}).get('run') or {}).get('shell')
        for i, step in enumerate(job.get('steps') or []):
            run = step.get('run')
            if not run:
                continue
            shell = step.get('shell') or job_shell or 'bash'
            if 'pwsh' in shell or 'powershell' in shell:
                continue
            out.append({
                'label': '%s | %s | %s' % (f, jname, step.get('name') or ('#%d' % i)),
                'run': run,
            })

w = os.environ['WORK']
for i, b in enumerate(out):
    # newline='\n':GitHub runner 上是 LF。带回车符的脚本 bash 会报怪错,
    # 那正是本项目栽过的第一次(回车符被当成命令的一部分)。
    with open('%s/%d.sh' % (w, i), 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(b['run'])
with open(w + '/labels.txt', 'w', encoding='utf-8', newline='\n') as fh:
    # ★ 每行都要带结尾换行。用 '\n'.join 的话最后一行没有换行符,下面的
    #   `while read` 会**静默丢掉最后一块** —— 实测 35 块只查了 34 块,
    #   而"最后一个步骤坏掉"恰恰是脚本批量改文件时最容易造出来的情况。
    for b in out:
        fh.write(b['label'] + '\n')
print(len(out))
PY

n=$("$PY_BIN" -c "import os;print(sum(1 for _ in open(os.environ['WORK']+'/labels.txt',encoding='utf-8')))")
echo "待查 shell 块: $n"

fail=0
i=0
while IFS= read -r label; do
  if ! err=$(bash -n "$WORK/$i.sh" 2>&1); then
    echo "  FAIL  $label"
    echo "        $err"
    fail=1
  fi
  i=$((i + 1))
done < "$WORK/labels.txt"

if [ "$fail" -ne 0 ]; then
  echo "workflow 里有 shell 语法错误"
  exit 1
fi
echo "全部通过($i 块)"

# ★★ 编译期凭据闸门。2026-07-21 事故:安卓 job 从建起来就没传 DANDANPLAY_*/TMDB_API_KEY,
#   于是 TV 端排行榜整页空白 —— 而 CI 全绿、APK 正常出包、装得上跑得起来。
#   这类漏配**没有任何运行时信号**:sealsecrets 读不到就静默不注入,
#   前端只好诚实显示「这个构建没配」,看着像功能没做。
#
# ★ 2026-09-04:识别的构建步骤从 `tauri build` 改成 `pack-win.sh` / `build-core.sh`;
#   2026-09-06 再加 `build-core-android.sh`
#   (Rust 栈已删)。**这一改不能忘** —— 闸门认不出任何构建步骤时会走下面的
#   `checked == 0` 分支判失败,那是故意的:一个谁都拦不住的闸门比没有闸门更坏。
# ★ 变量从 3 个扩到 9 个,与 core/cmd/sealsecrets/main.go 读的那批一致。
#   全表与「漏配之后用户看到什么」见 docs/go-migration/BUILD-SECRETS.md。
"$PY_BIN" - <<'PY'
import yaml, glob, sys

NEED = ['DANDANPLAY_APP_ID', 'DANDANPLAY_APP_SECRET', 'TMDB_API_KEY',
        'LP_SYNC_PROXY_BASE', 'LP_SYNC_PROXY_KEY', 'LP_BANGUMI_REDIRECT_URI',
        'LP_AFDIAN_SPONSOR_URL', 'LP_ICON_LIBRARY_SOURCES', 'LP_CF_TEST_URL']
# ★ 2026-09-06:加上安卓那条。build-core-android.sh 也读同一批编译期凭据,
#   漏配的表现一模一样(弹幕搜不到 / 排行榜空白),而 CI 全绿。
BUILD_STEPS = ('pack-win.sh', 'build-core.sh', 'build-core-android.sh')
bad = []
checked = 0
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f, encoding='utf-8'))
    for jname, job in (d.get('jobs') or {}).items():
        for i, step in enumerate(job.get('steps') or []):
            run = step.get('run') or ''
            if not any(m in run for m in BUILD_STEPS):
                continue
            checked += 1
            label = '%s | %s | %s' % (f, jname, step.get('name') or ('#%d' % i))
            # 变量可以挂在 step 或 job 上,两处都算。
            env = dict((job.get('env') or {}), **(step.get('env') or {}))
            miss = [k for k in NEED if not str(env.get(k, '')).strip()]
            if miss:
                bad.append('%s  缺少: %s' % (label, ', '.join(miss)))

if checked == 0:
    print('凭据闸门:没找到任何构建步骤(%s) —— 闸门本身失效了,当作失败'
          % ' / '.join(BUILD_STEPS))
    sys.exit(1)
for b in bad:
    print('  FAIL  ' + b)
if bad:
    print('构建步骤漏了编译期凭据 —— 出来的包功能会静默残废(排行榜空白)')
    sys.exit(1)
print('凭据闸门通过(%d 个构建步骤)' % checked)
PY

# ---------------------------------------------------------------------------
# 上下文闸门:`secrets` 不许出现在任何 `if:` 里。
#
# ☠ 2026-09-06 烧了一整轮:`if: ${{ secrets.X != '' }}` 写在 step 上,
#   GitHub 在**校验阶段**就判整个 workflow 非法
#   ("Unrecognized named-value: 'secrets'"),于是**一个 job 都不生成** ——
#   Actions 页面上只有一句「This run likely failed because of a workflow file issue」,
#   没有任何编译错误可看,`gh run view` 也列不出 job。
#   `yaml.safe_load` 过、`run:` 块语法也过,这个闸门之前的两关全绿。
#
#   官方的可用上下文表里,`steps.if` / `jobs.if` 都**没有** secrets。
#   要按密钥有没有配来分支,把它先落到 **job 级 env**(那里允许),再判 env。
"$PY_BIN" - <<'PY'
import yaml, glob, sys

bad = []

def walk_if(where, val):
    if isinstance(val, str) and 'secrets.' in val:
        bad.append(where)

for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f, encoding='utf-8'))
    for jname, job in (d.get('jobs') or {}).items():
        walk_if('%s | job %s | if' % (f, jname), job.get('if'))
        for i, step in enumerate(job.get('steps') or []):
            label = '%s | %s | %s | if' % (f, jname, step.get('name') or ('#%d' % i))
            walk_if(label, step.get('if'))

for b in bad:
    print('  FAIL  ' + b + '  用了 secrets 上下文')
if bad:
    print("`if:` 里不许用 secrets —— GitHub 校验阶段就判 workflow 非法,一个 job 都不会生成。")
    print("改法:把密钥落到 job 级 `env:`(那里允许),`if:` 判 `env.X`。")
    sys.exit(1)
print('上下文闸门通过(if 里没有 secrets)')
PY
