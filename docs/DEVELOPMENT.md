# 开发与技术

> 2026-09-04 重写。此前这份文档写的是 Rust + React/Tauri 那一套 —— 那个栈已从仓库删除,
> 整篇都作废了。要看旧内容:`git show rust-final:docs/DEVELOPMENT.md`。

## 技术栈

| 层 | 用什么 | 说明 |
|---|---|---|
| 核心层 | [Go](https://go.dev) | 业务全在这:Emby 协议 / 播放控制 / 网络 / 插件 / 弹幕 / 同步 / 下载。编成 `lpcore` 动态库(`c-shared`),经 C ABI 供各端调用 |
| 播放内核 | [libmpv](https://mpv.io) | 核心层 cgo 直接调。不是子进程,是进程内库 |
| Windows 外壳 | C# / .NET 10 + [Avalonia 11](https://avaloniaui.net) | 窗口、UI、把核心层的命令接到界面上 |
| 命令绑定 | 生成的 `Commands.g.cs` / `Commands.g.kt` | 从 `docs/go-migration/COMMANDS.md` 生成,见下文「命令契约」 |

**只有 Windows 一个端能出包。** Linux 与 Android/TV 的 UI 还没写。

## 仓库结构

```
core/              Go 核心层。出库为 lpcore.dll
  ffi/             C ABI 边界(SPEC §5.1)
  cmd/             listcommands / diffcheck / sealsecrets 等工具
apps/windows/      C# + Avalonia 外壳
bindings/          从 COMMANDS.md 生成的命令绑定(csharp / kotlin)
third_party/
  libmpv/          libmpv 的头文件与导入库(cgo 链接用)。dll 不入库
scripts/           构建与门禁脚本
docs/go-migration/ 架构 SPEC / 迁移方案 / 任务清单 / 命令契约 / 领域知识
docs/lessons/      踩坑经验正本
VERSION            版本号唯一权威(见 VERSIONING.md)
```

## 环境要求

- **不需要在系统里装 Go**。工具链(Go + zig)由脚本拉到 `.toolchain/`,版本与 sha256 钉在
  `scripts/fetch-toolchain.sh` 里 —— 本地和 CI 用的是同一份,免得「我这儿能编、CI 编不过」。
  > 为什么带一个 C 编译器:Go 编 `c-shared` **必须走 cgo**,cgo 要 gcc/clang 口径的编译器,
  > MSVC 不行。选 zig 是因为一个包同时能当 Windows 和 Linux 的 cc。
- **.NET SDK 10**(编 Avalonia 外壳)
- **libmpv**:`third_party/libmpv/` 里已有链接期需要的 `client.h` / `mpv.lib`;
  运行还需要 `libmpv-2.dll`(112MB,**不入库**)。CI 每次从 shinchiro 现拉,本地自备。
  > 必须是**完整版**:精简版 libmpv 能编译、能播放,但蓝光 PGS 图形字幕一片空白。

## 本地开发

```bash
bash scripts/fetch-toolchain.sh     # 新机器第一步
source scripts/env.sh               # 激活(PowerShell: . .\scripts\env.ps1)
bash scripts/check-toolchain.sh     # 自检,含反向注入

bash scripts/build-core.sh          # 出 build/core/lpcore.dll
dotnet run --project apps/windows/LinPlayer.Desktop
```

跑 Go 测试时 **`PATH` 里要有 `third_party/libmpv`**,否则 cgo 出来的测试二进制
起不来,报 `exit status 0xc0000135`(STATUS_DLL_NOT_FOUND)——
这个错看着像代码坏了,其实只是找不到 DLL:

```bash
cd core && PATH="$PWD/../third_party/libmpv:$PATH" go test ./...
```

## 门禁(推之前跑)

| 命令 | 管什么 |
|---|---|
| `bash scripts/check-core.sh` | go vet / go test / 出库 / FFI 契约 / C# 契约测试 / **18 条差分对账** |
| `bash scripts/check-bindings.sh` | 绑定产物最新 / C# 编译 / Kotlin 编译 / **四方比对** |
| `bash scripts/check-workflows.sh` | workflow 的 shell 语法 + **编译期凭据闸门** |
| `bash scripts/pack-win.sh` | 出绿色包。**「编译通过」不是交付** |
| `bash scripts/selfcheck-win.sh` | 真机自检:起假 Emby → 灌账号 → 起 exe → 截图 |

### 差分对账是什么

`core/cmd/diffcheck/corpus/` 里有 18 份语料,录的是**旧 Rust 实现(黄金实现)的输出**。
Go 版必须逐字对得上 —— 验收标准不是「跑起来了」,是「和黄金实现一致」。
Rust 代码已经删了,但语料还在、照样有效。

## 命令契约

命令名是**字符串**,拼错了编译器不管,表现是「点了没反应」。所以有一条生成链:

```
docs/go-migration/COMMANDS.md  ──gen-bindings.py──>  bindings/csharp/Commands.g.cs
        (手维护真源)                                  bindings/kotlin/Commands.g.kt
```

`COMMANDS.md` 是**手维护**的(2026-09-04 起)。以前它从 Tauri 注册表自动生成,
Rust 栈删除后数据源没了 —— Go 的 handler 是 `map[string]any -> any`,抽不出静态签名。

那「表和事实分家」谁来守?`check-bindings.sh` 第 4 关:它拿 `COMMANDS.md` 和
**Go 注册表**做双向比对 —— 表里有而 Go 没注册、Go 注册了而表里没有,两个方向都红。
**加命令必须同时改 `COMMANDS.md`。**

## 编译期凭据

弹幕、排行榜、OAuth 代理等 9 个变量在构建时注入(`core/cmd/sealsecrets`),
明文不进二进制、不进构建日志。全表与「漏配之后用户看到什么」见
[`go-migration/BUILD-SECRETS.md`](go-migration/BUILD-SECRETS.md)。

一个都不配也编得出来 —— 对应功能会**明说「这个构建没配」**,不会崩、也不会假装成功。
但发行版九个全都要配:漏了用户看到的是「弹幕搜不到 / 排行榜空白 / Trakt 登不上」,
而 CI 全绿。`check-workflows.sh` 的凭据闸门盯着这件事。

## 版本号

**唯一权威是仓库根的 `VERSION`**,见 [`VERSIONING.md`](VERSIONING.md)。
代码里**不许写死版本字面量** —— 版本一退,更新检查判「已是最新」并静默卡死所有老用户。
这个坑本仓踩过三次。
