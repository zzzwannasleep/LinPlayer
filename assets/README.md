把你要用作应用图标的图片保存为：`assets/app_icon.jpg`（建议至少 1024×1024）。
生成各平台图标：

```bash
flutter pub get
dart run flutter_launcher_icons
```

说明：
- 该命令会覆盖各平台工程内的图标文件（Android/iOS/macOS/Windows）。
- CI（GitHub Actions）构建时也会自动执行一次。
