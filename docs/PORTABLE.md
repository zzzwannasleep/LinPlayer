# 桌面便携包:干净、隔离、可覆盖更新

LinPlayer 的 Windows/Linux 压缩包是**便携包**:所有应用数据都写在**程序目录**内,
不往系统目录乱丢文件。每份解压目录是一套独立环境 —— 互不影响,适合「同机并存多版本」
或「本地构建 vs. GitHub 构建对照测试」。

## 解压后的目录结构

```
LinPlayer/
├─ linplayer.exe          ← 程序本体
├─ *.dll                  ← 运行库(libmpv-2.dll、flutter_windows.dll …)
├─ data/                  ← Flutter 自带资源(flutter_assets、icudtl.dat)※更新时被替换
├─ plugins/               ← QuickJS 插件
├─ downloads/             ← 应用内下载
├─ temp/                  ← 图片/视频缓存(可随时删)
└─ userdata/              ← 你的全部配置与数据 ★更新时保留★
   ├─ app_support/        ← 设置、服务器列表、密码/Token(Windows 上 DPAPI 加密)、
   │                         观看记录、字体、mpv.conf、whisper 模型
   ├─ documents/          ← 日志导出
   ├─ cache/              ← 杂项缓存
   └─ temp/               ← 运行日志、临时文件
```

> 实现见 `lib/core/services/portable_paths.dart`:启动最早期把
> `PathProviderPlatform.instance` 重定向到 `程序目录/userdata`。

## 三条保证

1. **干净**:不写 `%APPDATA%`、不写「文档」目录、不进系统钥匙串(Windows)。
   删掉解压文件夹 = 彻底清除,系统里不留残渣。
2. **隔离**:每份解压目录只读写**自己的 `userdata/`**。解压两份分别跑 GitHub 包和
   本地包,配置互不串改 —— 可以放心对照测试整个安装流程。
3. **可覆盖更新**:更新包(zip)只含程序文件与 `data/`,**不含 `userdata/`**。
   把新版解压**覆盖**到旧目录即可:程序文件被替换,`userdata/`(及 `plugins/`、
   `downloads/`)原样保留,配置不丢。

## 边界情况

- **装到只读位置**(如 `C:\Program Files\`):程序目录不可写,启动探针失败 →
  自动回退到系统默认目录(`%APPDATA%` 等),功能不受影响,只是不再便携。
- **从旧版升级**:首次以便携方式启动时,若 `userdata/` 是全新创建,会把旧的系统
  应用支持目录(`%APPDATA%\…`)里的配置**一次性迁移**进 `userdata/app_support`,
  老用户升级后设置不丢。
- **Linux 密码存储**:`flutter_secure_storage_linux` 走系统 libsecret 钥匙串
  (不经 path_provider),故 Linux 上密码/Token 仍在系统钥匙串里;其余数据照样便携。
  Windows 不受此限(DPAPI 密文文件落在 `userdata/app_support/`)。
