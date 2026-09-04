#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 COMMANDS.md 生成各端绑定层(SPEC §5.6 / TODO B2.4)。

    python scripts/gen-bindings.py            # 写文件
    python scripts/gen-bindings.py --check    # 只校验:产物与当前 COMMANDS.md 是否一致

为什么要生成:266 条命令 × 3 端 = **798 次抄写机会**,写错的那几次全是运行时才发现的
——命令名是字符串,拼错了编译器不管,表现是「点了没反应」。

## 现在生成什么、不生成什么

**生成**:每条命令一个方法 + 一份命令名清单 + ABI 版本常量。
方法名由命令名机械推导(`emby.listItemsPage` → C# `EmbyListItemsPage` /
Kotlin `embyListItemsPage`),命令名字符串**只在生成的那一处出现**。

**不生成**:参数与返回的强类型。COMMANDS.md 的参数/返回列现在装的是**现有 Rust 签名**
(见该文档「规范」一节),那是移植时的对账基准,**不是**新契约的 JSON 形状。
拿它硬生成 record/data class 会造出一批和真实 JSON 对不上的类型 ——
比没有类型更糟:它看起来是类型安全的。

等各模块移植时把 JSON 形状回填进 COMMANDS.md,再让这个脚本生成强类型包装。
在那之前,参数是 `object?` / `Map<String, Any?>`,返回是 `JsonElement` / `JsonElement`。

## 一条硬规矩

`lp_next_event` **必须封成私有**(SPEC §5.6):有且仅有一个消费者线程能调它,
两个线程同时调不是崩溃,是事件被**随机分给两个线程** ——「有时候收得到有时候收不到」。
生成的绑定不暴露它,只暴露一个事件流。
"""

import argparse
import re
import sys
from pathlib import Path

# ★ Windows 的 CI runner 上 Python 默认按 cp1252 输出,打中文当场
#   UnicodeEncodeError —— 而本地开发机(GBK/UTF-8)复现不出来。
#   2026-09-04 新 CI 第一次跑就栽在这。不靠环境变量:PYTHONIOENCODING
#   优先级比 PYTHONUTF8 高,CI 上谁设了它就把 UTF-8 模式顶掉了。
import sys as _sys
for _s in (_sys.stdout, _sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


ROOT = Path(__file__).resolve().parent.parent
COMMANDS_MD = ROOT / "docs" / "go-migration" / "COMMANDS.md"
ABI_GO = ROOT / "core" / "ffi" / "abi.go"

OUT_CS = ROOT / "bindings" / "csharp" / "Commands.g.cs"
OUT_KT = ROOT / "bindings" / "kotlin" / "Commands.g.kt"

BANNER = "// 本文件由 scripts/gen-bindings.py 从 docs/go-migration/COMMANDS.md 生成。\n// 不要手改 —— 改了会在下一次生成时被覆盖,而且四方比对会红。\n"


def read_commands():
    """从 COMMANDS.md 的生成段里抽出 (域标题, [命令名...])。"""
    text = COMMANDS_MD.read_text(encoding="utf-8")
    body = text.split("<!-- BEGIN GENERATED -->", 1)
    if len(body) != 2:
        sys.exit("COMMANDS.md 里找不到 <!-- BEGIN GENERATED --> 标记")
    body = body[1]

    groups, current = [], None
    for line in body.splitlines():
        m = re.match(r"^###\s+(.+?)\s*·\s*`([a-z]+)\.\*`", line)
        if m:
            current = (m.group(1), m.group(2), [])
            groups.append(current)
            continue
        # | [ ] | `emby.views` | ... |
        m = re.match(r"^\|\s*\[[ x]\]\s*\|\s*`([a-zA-Z0-9_.]+)`", line)
        if m and current is not None:
            current[2].append(m.group(1))
    if not groups:
        sys.exit("COMMANDS.md 里一条命令都没解析出来 —— 表格格式变了?")

    names = [c for _, _, cs in groups for c in cs]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        sys.exit(f"COMMANDS.md 里有重复命令名: {sorted(dupes)}")
    return groups


def read_abi():
    """ABI 版本的真值只有 core/ffi/abi.go 一处(SPEC §5.0)。三端不许手抄。"""
    m = re.search(r"LP_ABI\s*=\s*(\d+)", ABI_GO.read_text(encoding="utf-8"))
    if not m:
        sys.exit(f"{ABI_GO} 里找不到 LP_ABI")
    return int(m.group(1))


def pascal(cmd):
    """emby.listItemsPage -> EmbyListItemsPage"""
    parts = cmd.replace(".", " ").split()
    return "".join(p[:1].upper() + p[1:] for p in parts)


def camel(cmd):
    """emby.listItemsPage -> embyListItemsPage"""
    p = pascal(cmd)
    return p[:1].lower() + p[1:]


def gen_csharp(groups, abi):
    out = [BANNER]
    # ★ 文件名以 .g.cs 结尾,编译器把它当「自动生成的代码」——
    #   那种文件里的可空注解**必须**有显式 #nullable 指令,否则 267 个 CS8669。
    #   (csproj 里的 <Nullable>enable</Nullable> 对生成文件不生效。)
    out.append("""#nullable enable

using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace LinPlayer.Core;

/// <summary>
/// 核心层命令的类型化包装。**生成的,不要手写。**
/// </summary>
/// <remarks>
/// 参数与返回暂时是弱类型(<c>object?</c> / <see cref="JsonElement"/>):
/// COMMANDS.md 的参数列现在装的是现有 Rust 签名,不是新契约的 JSON 形状。
/// 形状回填之后这里会换成 record。
///
/// <para>
/// ⚠️ <c>lp_next_event</c> 不在这里暴露:有且仅有一个消费者线程能调它。
/// 两个线程同时调不会崩,而是事件被<b>随机分给两个线程</b> ——
/// 表现为「有时候收得到有时候收不到」。事件请走 <c>CoreClient</c> 的事件流。
/// </para>
/// </remarks>
public partial interface ILinPlayerCommands
{
    /// <summary>发一条命令,等它的 result 事件。</summary>
    Task<JsonElement> CallAsync(string command, object? args, CancellationToken ct = default);
}

public static class LinPlayerAbi
{
    /// <summary>ABI 版本。真值在 core/ffi/abi.go,这里是生成出来的副本。</summary>
    public const int Version = %d;
}

/// <summary>全部命令名。四方比对(COMMANDS.md ↔ Go 注册表 ↔ 三端绑定)用这份。</summary>
public static class LinPlayerCommandNames
{
    public static readonly string[] All =
    [
%s
    ];
}

public static class LinPlayerCommandsExtensions
{""" % (abi, "\n".join(
        f'        "{c}",' for _, _, cs in groups for c in cs)))

    for title, prefix, cmds in groups:
        out.append(f"\n    // ---- {title} · {prefix}.* ({len(cmds)} 条) ----\n")
        for c in cmds:
            out.append(
                f"    public static Task<JsonElement> {pascal(c)}(this ILinPlayerCommands c, "
                f"object? args = null, CancellationToken ct = default)\n"
                f'        => c.CallAsync("{c}", args, ct);\n'
            )
    out.append("}\n")
    return "".join(out)


def gen_kotlin(groups, abi):
    out = [BANNER]
    out.append("""
package xyz.linplayer.core

import kotlinx.serialization.json.JsonElement

/**
 * 核心层命令的类型化包装。**生成的,不要手写。**
 *
 * 参数与返回暂时是弱类型:COMMANDS.md 的参数列现在装的是现有 Rust 签名,
 * 不是新契约的 JSON 形状。形状回填之后这里会换成 data class。
 *
 * ⚠️ `lp_next_event` 不在这里暴露:有且仅有一个消费者线程能调它。
 * 两个线程同时调不会崩,而是事件被**随机分给两个线程** ——
 * 表现为「有时候收得到有时候收不到」。事件请走 `CoreClient` 的 Flow。
 */
interface LinPlayerCommands {
    /** 发一条命令,挂起到它的 result 事件回来。 */
    suspend fun call(command: String, args: Map<String, Any?>? = null): JsonElement
}

object LinPlayerAbi {
    /** ABI 版本。真值在 core/ffi/abi.go,这里是生成出来的副本。 */
    const val VERSION = %d
}

/** 全部命令名。四方比对(COMMANDS.md ↔ Go 注册表 ↔ 三端绑定)用这份。 */
object LinPlayerCommandNames {
    @JvmField
    val ALL: List<String> = listOf(
%s
    )
}
""" % (abi, "\n".join(f'        "{c}",' for _, _, cs in groups for c in cs)))

    for title, prefix, cmds in groups:
        out.append(f"\n// ---- {title} · {prefix}.* ({len(cmds)} 条) ----\n")
        for c in cmds:
            out.append(
                f"suspend fun LinPlayerCommands.{camel(c)}(args: Map<String, Any?>? = null): JsonElement =\n"
                f'    call("{c}", args)\n'
            )
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验产物是否最新,不写文件")
    args = ap.parse_args()

    groups = read_commands()
    abi = read_abi()
    total = sum(len(cs) for _, _, cs in groups)

    targets = [(OUT_CS, gen_csharp(groups, abi)), (OUT_KT, gen_kotlin(groups, abi))]

    stale = []
    for path, content in targets:
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(path)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            # 强制 LF:产物必须可复现,CRLF 会让 --check 在不同机器上结论不同
            path.write_text(content, encoding="utf-8", newline="\n")

    if args.check:
        if stale:
            print("绑定层产物过期,跑一次 python scripts/gen-bindings.py:")
            for p in stale:
                print("  -", p.relative_to(ROOT))
            return 1
        print(f"绑定层产物是最新的({total} 条命令,ABI={abi})。")
        return 0

    print(f"已生成 {len(targets)} 份绑定,共 {total} 条命令(ABI={abi}):")
    for p, c in targets:
        print(f"  {p.relative_to(ROOT)}  {len(c.splitlines())} 行")
    return 0


if __name__ == "__main__":
    sys.exit(main())
