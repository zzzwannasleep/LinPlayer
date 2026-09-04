# 桌面便携包:干净、隔离、可覆盖更新

LinPlayer 的 Windows 压缩包是**便携包**(绿色包):所有应用数据都写在**程序目录**内,
不往系统目录乱丢文件。每份解压目录是一套独立环境 —— 互不影响,适合「同机并存多版本」
或「本地构建 vs. GitHub 构建对照测试」。

> 便携**不是可选项,是默认且唯一的正常路径**。落盘路径只有一个出口:
> 核心层的 `core/paths` 包。别在别处自己拼用户目录。

## 解压后的目录结构

```
LinPlayer/
├─ LinPlayer.exe            ← 程序本体(C# / Avalonia,self-contained,用户机器不装 .NET)
├─ lpcore.dll               ← Go 核心层(业务全在这)
├─ libmpv-2.dll             ← 完整版 libmpv(含 PGS/SUP 图形字幕解码器)
└─ userdata/                ← 你的全部身家 ★更新时保留★,删掉它=卸载干净
   ├─ config.json           ← 设置 / 服务器列表 / 凭据
   ├─ translation.json
   ├─ data/                 ← 用户数据:删了真会丢东西(观看记录、插件、whisper 模型)
   ├─ cache/                ← 纯缓存:随便删,能重建(封面、shader-cache、翻译)
   ├─ temp/                 ← 进程 TEMP/TMP 重定向到这里(连第三方库的临时文件也跑不掉)
   ├─ logs/
   └─ downloads/            ← 应用内下载
```

`cache/` 与 `data/` 分开不是洁癖 —— 它让「清理缓存」能是一句 `remove_dir_all(cache_root())`,
而不用逐个白名单挑文件(挑漏一个就是清不干净,挑错一个就是删用户数据)。

## 三条保证

1. **干净**:不写 `%APPDATA%` / `%LOCALAPPDATA%`(Windows)、不写 `~/.config` 与
   `~/.local/share`(Linux)、不进系统钥匙串。删掉解压文件夹 = 彻底清除。
   > ★ 旧的 Tauri 栈还得额外按住**浏览器内核自己**建的 profile(WebView2 不给
   > `data_directory` 就在 `%LOCALAPPDATA%` 建一个,实测 126MB)。
   > C# / Avalonia 栈没有内嵌浏览器,这条负担随 2026-09-04 删 Rust 栈一起消失了。
2. **隔离**:每份解压目录只读写**自己的 `userdata/`**。解压两份分别跑 GitHub 包和
   本地包,配置互不串改 —— 可以放心对照测试整个安装流程。
3. **可覆盖更新**:更新包(zip)只含程序文件,**不含 `userdata/`**。
   把新版解压**覆盖**到旧目录即可,配置不丢。应用内更新走的也是同一条路。

## 平台前提

### Windows
开箱即用,libmpv 已内置在包里。

### Linux(x86_64)

**暂无 Linux 版。** 2026-09-04 删除 Rust/Tauri 栈时,Linux 端的唯一实现一并删除,
而 Go 版的 Linux UI 还没写(进度见 `go-migration/TODO.md`)。

历史版本仍可在 Releases 里下载 —— 那是 Tauri 版,依赖 webkit2gtk 4.1 + GTK3 + libsoup3,
系统下限 Ubuntu ≥ 22.04 / Debian ≥ 12。具体依赖清单见 `git show rust-final:docs/PORTABLE.md`。

## 边界情况

- **装到只读位置**(如 `C:\Program Files\`、只读挂载点):程序目录不可写,启动探针
  (真建目录 + 真写一个探针文件再删)失败 → 自动回落系统目录
  (Windows `%LOCALAPPDATA%` / Linux `~/.local/share`)。功能不受影响,但**不再便携** ——
  设置页会如实标出当前数据根的类型(`RootKind::SystemFallback`),绝不悄悄换地方。
  > 探针必须真写文件:Windows 的 Program Files 有 UAC 虚拟化,建目录「成功」了,
  > 写进去的东西却被悄悄重定向到 VirtualStore,一点错都不报。
- **指定数据根**:设环境变量 `LP_DATA_DIR` 可强制数据根位置(`RootKind::Overridden`)。
- **从旧版升级**:迁移挂在 `paths::root()` 的**首次调用**上自动执行,不是某处的一句显式
  调用 —— 那样只要调用顺序排错(比如 `AppConfig::load()` 抢先在新根落下一个空
  `config.json`),迁移就会认为「目标已存在」而跳过,老用户升级后**服务器全没了且不报错**。
