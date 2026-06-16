# Linux libmpv 说明

media_kit 在 Linux 使用**系统 libmpv**（`libmpv.so`，由发行版包提供）。发行版的
libmpv 通常是完整构建，自带全部 ffmpeg 解码器（含 PGS/`hdmv_pgs_subtitle`），
因此**一般无需替换**——运行时 PGS 检测对非 Windows 默认按「可用」处理。

## 安装/确保完整

```sh
# Debian/Ubuntu
sudo apt install libmpv2   # 或 libmpv1（旧版）
# Arch
sudo pacman -S mpv
# Fedora
sudo dnf install mpv-libs
```

确认含 PGS 解码器：

```sh
ffmpeg -decoders 2>/dev/null | grep pgssub   # libmpv 复用系统 ffmpeg 时
mpv --vd=help 2>/dev/null | grep -i pgs       # 或检查 mpv 自身
```

若某些精简发行版的 libmpv 缺解码器，安装完整版 `mpv`/`ffmpeg` 包即可；
LinPlayer 不在 Linux 端替换 libmpv（交由系统包管理器统一维护）。
