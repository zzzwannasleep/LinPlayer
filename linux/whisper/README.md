# 内置 whisper.cpp 可执行文件（Linux）

把 whisper.cpp 的可执行文件放到本目录，构建时会被打包到应用运行目录的
`whisper/` 子目录，运行时由 `DesktopBinaryManager.resolveWhisper()` 定位，
无需用户配置路径。

## 需要放入的文件

- `whisper-cli`（whisper.cpp 新版可执行名；旧版为 `main`，亦兼容）
- 其依赖的共享库（如 `libggml.so`、`libwhisper.so` 等）

## 获取方式

从 whisper.cpp 官方仓库自行编译：

```sh
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp && cmake -B build && cmake --build build -j --config Release
# 产物在 build/bin/ 下，拷贝 whisper-cli 及所需 .so 到本目录
```

> 模型权重（ggml-*.bin）不在此内置 —— 由用户在「设置 → 字幕翻译 → Whisper」
> 中按需下载。运行时若库找不到，可在打包脚本里设置 RPATH 或把 .so 一并放入。
