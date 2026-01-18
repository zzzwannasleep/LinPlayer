## 应用图标（flutter_launcher_icons）

本项目使用 `flutter_launcher_icons` 从 `assets/app_icon.jpg` 一键生成各平台应用图标资源（Android/iOS/macOS/Windows）。

### 什么时候需要运行？
- 替换了 `assets/app_icon.jpg`
- 调整了 `pubspec.yaml` 中的 `flutter_launcher_icons:` 配置
- 新增/启用了某个平台（例如首次启用 Windows/macOS）

### 1) 准备图标源文件
- 将你要用作应用图标的图片保存为：`assets/app_icon.jpg`
- 建议尺寸：至少 1024×1024（尽量使用正方形、边缘留出安全内边距）
- 建议避免纯透明边缘（尤其是 iOS，会移除 alpha，见下文说明）

### 2) 生成各平台图标

在项目根目录执行：

```bash
flutter pub get
dart run flutter_launcher_icons
```

说明：
- 该命令会覆盖各平台工程内的图标文件（Android/iOS/macOS/Windows）。
- iOS 端默认会移除透明通道（见 `pubspec.yaml` 的 `remove_alpha_ios: true`）。
- CI（GitHub Actions）构建时也会自动执行一次；如果你在本地替换了图标，建议本地也执行一次并提交生成结果，避免各平台图标不同步。

### 3) 生成结果（常见位置）
- Android：`android/app/src/main/res/mipmap-*/`（`ic_launcher*`）
- iOS：`ios/Runner/Assets.xcassets/AppIcon.appiconset/`
- macOS：`macos/Runner/Assets.xcassets/AppIcon.appiconset/`
- Windows：`windows/runner/resources/app_icon.ico`

### 4) 配置位置
- 图标生成配置在 `pubspec.yaml` 的 `flutter_launcher_icons:` 段落。
