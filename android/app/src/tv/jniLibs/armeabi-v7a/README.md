# TV 专属 mihomo 内核目录

此目录仅在构建 **tv** flavor 时被打包（见 `android/app/build.gradle.kts` 的 `sourceSets`）。

放置文件：`libmihomo.so`（mihomo 的 arm32/armv7 二进制，重命名为 `lib*.so`）。

为什么命名为 `lib*.so`：Android 安装时会把 jniLibs 中的 `.so` 解压到应用的
`nativeLibraryDir` 并赋予可执行权限。Android 10+ 出于安全限制，**只能从
`nativeLibraryDir` 执行二进制**，因此把内核伪装成 `.so` 是通行做法（Clash/SagerNet 同理）。

获取方式（不入库，按需拉取）：

```powershell
pwsh ./scripts/fetch_mihomo_tv.ps1 -MihomoVersion v1.18.10
```

mobile / iOS / 桌面 / Apple TV 均不包含此内核。
