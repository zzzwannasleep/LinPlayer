# macOS 完整版 libmpv（可选替换）

media_kit 在 macOS 通过 `media_kit_libs_macos_video` 随包提供 `Mpv.framework`。
若其缺少你需要的解码器（如 PGS/`hdmv_pgs_subtitle`），把**完整版 libmpv 二进制**
放到本目录并命名为 `Mpv`，构建末尾的「Upgrade libmpv」脚本会自动覆盖
`.app/Contents/Frameworks/Mpv.framework/Mpv` 并重新签名。不放则跳过、用自带版本。

## 如何获取完整版 libmpv（macOS, dylib/framework 二进制）

- Homebrew：`brew install mpv`，其依赖 `libmpv`（`/opt/homebrew/lib/libmpv.dylib`，
  通常含完整 ffmpeg/解码器）。把该 dylib 重命名为 `Mpv` 放入本目录即可。
- 或自行用完整 ffmpeg 编译 libmpv。

> 注意 ABI：所放 libmpv 的主版本需与 media_kit 期望的一致（libmpv-2 / client API v2），
> 否则加载失败。建议与 media_kit 当前版本对齐后再替换。

## 跳过

设环境变量 `LINPLAYER_SKIP_LIBMPV_UPGRADE=1` 可显式跳过替换。
