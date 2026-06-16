# 内置 whisper.cpp 可执行文件（Windows）

把 whisper.cpp 的预编译可执行文件放到本目录，构建时会被自动打包到应用运行
目录的 `whisper/` 子目录，运行时由 `DesktopBinaryManager.resolveWhisper()` 定位，
无需用户手动配置路径。

## 需要放入的文件

- `whisper-cli.exe`（whisper.cpp 新版可执行名；旧版为 `main.exe`，亦兼容）
- 其依赖的运行库 DLL（如 `ggml.dll`、`ggml-base.dll`、`whisper.dll`、`SDL2.dll` 等，
  随 whisper.cpp release 附带）

## 获取方式

从 whisper.cpp 官方 Release 下载 Windows 预编译包（`whisper-bin-x64.zip`）：
https://github.com/ggerganov/whisper.cpp/releases

解压后将 `whisper-cli.exe` 与同目录的 DLL 一并拷入本目录即可。

> 注意：模型权重（ggml-*.bin）不在此处内置 —— 由用户在「设置 → 字幕翻译 →
> Whisper」中按需下载。

## 其他平台的内置位置

- macOS：放入 `.app` 的 `Contents/Resources/whisper/`（或可执行文件同级 `whisper/`）。
- Linux：放入可执行文件同级的 `whisper/` 或 `bin/` 目录。

运行时解析顺序：用户指定路径 → 已下载缓存 → 可执行文件同级 `whisper/`·`bin/` →
系统 PATH。
