# apps/ —— 各端宿主壳

壳只负责平台相关的事:窗口 / 生命周期、播放器(mpv)合成、把 `core`(Go 核心层)
的能力接到 UI 上。**业务逻辑不写在这里** —— 那些在 `core/`,各端共用同一份。

| 目录 | 状态 | 说明 |
|------|------|------|
| `windows/` | 在用 | C# + [Avalonia](https://avaloniaui.net) 11。经 P/Invoke 调 `lpcore.dll`,命令绑定是 `bindings/csharp/Commands.g.cs`(从 `docs/go-migration/COMMANDS.md` 生成) |

> ⚠️ **只有 Windows 一个端。** 2026-09-04 删除 Rust/Tauri 栈时,`desktop/`(Tauri 桌面壳)
> 与 `android/`(手机 + TV)一并删除,而 Go 版的 Linux / Android UI **还没开始写**
> (进度见 `docs/go-migration/TODO.md`)。
> 要看旧实现:`git show rust-final:apps/desktop/...`。

## windows 的几个约定

- **版本的唯一权威是仓库根的 `VERSION`**,见 [`docs/VERSIONING.md`](../docs/VERSIONING.md)。
  CI 用 `dotnet publish -p:Version=` 注入,`Program.cs` 回读程序集 ——
  **不许在代码里写死版本字面量**,那样发布出去老用户会静默收不到更新(踩过三次)。
- 图标正本在 `windows/LinPlayer.Desktop/Assets/`。以前它借的是 Tauri 端的
  `apps/desktop/icons/`,那边一删这边当场编不过(报在 Avalonia 的资源生成任务里,
  乍看不像图标的事)。**资源不跨栈借。**
- `lpcore.dll` 与 `libmpv-2.dll` 必须和 exe 同级。前者由 `scripts/build-core.sh` 出,
  后者是 112MB 的构建输入,不入库、CI 现拉,本地放 `third_party/libmpv/`。
- 数据全部落在 exe 同级的 `userdata/`(绿色包),唯一出口是核心层的 paths 模块。
