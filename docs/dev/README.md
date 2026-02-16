# 开发者文档（Developer Docs）

本目录包含 **二次开发 / 构建发布 / 维护** 相关内容；用户使用说明请看仓库根目录的 `README.md` 与 `docs/` 下的用户文档。

## 快速开始

建议使用 Flutter stable 3.x，并先运行 `flutter doctor -v` 确认环境正常。

```bash
flutter pub get
flutter run
```

## 常用命令

```bash
flutter analyze
flutter test

# Android（含 split-per-abi）
flutter build apk --split-per-abi

# Windows
flutter build windows --release

# macOS
flutter build macos --release

# iOS（无签名）
flutter build ios --release --no-codesign

# Linux
flutter build linux --release
```

> Windows 如提示 “Building with plugins requires symlink support”，请在系统设置中开启“开发者模式”。

## Android 签名（OTA 覆盖安装）

见：`docs/dev/ANDROID_SIGNING.md`

## Android TV：内置代理资源

Android TV 的内置代理使用 `mihomo + metacubexd`。CI 会自动拉取/打包相关资源；本地从源码构建如需更新可运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/fetch_tv_proxy_assets.ps1
```

> 如遇 GitHub API 限流，可设置环境变量 `GITHUB_TOKEN` 或 `GH_TOKEN`。

路线图与实现说明：`docs/dev/TV_PROXY_ROADMAP.md`

## 源码导览

项目结构与各模块职责：`docs/dev/ARCHITECTURE.md`
桌面端 UI 专项重构说明：`docs/dev/DESKTOP_UI_ARCHITECTURE.md`

## CI / 发布

- Nightly 构建：`.github/workflows/build-all.yml`
- Stable 发布：`.github/workflows/release-latest.yml`
