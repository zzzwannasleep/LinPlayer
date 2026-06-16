# 内置 whisper.cpp 可执行文件（macOS）

把 whisper.cpp 的可执行文件放到本目录，构建时 Xcode 的「Bundle Whisper」脚本
阶段会自动把内容拷贝到 `LinPlayer.app/Contents/Resources/whisper/`，运行时由
`DesktopBinaryManager.resolveWhisper()` 定位，无需用户配置路径。

## 需要放入的文件

- `whisper-cli`（whisper.cpp 新版可执行名；旧版为 `main`，亦兼容）
- 其依赖的动态库（如 `libggml.dylib`、`libwhisper.dylib` 等，随构建附带）

## 获取方式

从 whisper.cpp 官方仓库自行编译（推荐开启 Metal 加速）：

```sh
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp && cmake -B build && cmake --build build -j --config Release
# 产物在 build/bin/ 下，拷贝 whisper-cli 及所需 .dylib 到本目录
```

> 模型权重（ggml-*.bin）不在此内置 —— 由用户在「设置 → 字幕翻译 → Whisper」
> 中按需下载。

## 注意（Gatekeeper）

未签名的可执行文件首次运行可能被 Gatekeeper 拦截。分发时应对其做 codesign，
或在打包流程里 `xattr -dr com.apple.quarantine` 处理。
