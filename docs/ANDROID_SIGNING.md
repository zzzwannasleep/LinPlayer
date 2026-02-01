# Android 签名与 OTA 覆盖安装

Android 的“覆盖安装升级”（直接安装新版本 APK，不丢数据）依赖两个前提：
1. `applicationId` 不变（本项目目前为 `com.example.lin_player`）。
2. **签名证书不变**（同一个 keystore/alias）。

如果 nightly/CI 产物使用 **临时 debug keystore** 签名，那么每次构建出来的 APK 签名都可能不同，用户将无法覆盖安装，只能“卸载 → 重新安装”，并因此丢失应用数据。

仓库在 CI 中默认要求配置 release keystore；如确实需要强行允许 CI 用 debug 签名，可设置环境变量 `LINPLAYER_ALLOW_CI_DEBUG_SIGNING=true`，或在工作流输入里勾选 `allow_debug_signing`（不推荐，且不 OTA-safe）。

## 配置 GitHub Actions（推荐：保证 nightly 可覆盖安装）

在仓库 `Settings → Secrets and variables → Actions → Secrets` 中添加：

- `ANDROID_KEYSTORE_BASE64`：keystore 文件的 base64（建议单行；CI 会自动去除空白字符）
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

如果你安装了 GitHub CLI（`gh`），建议用文件直接写入 Secrets，避免粘贴引入不可见字符：

```bash
gh secret set ANDROID_KEYSTORE_BASE64 --body-file android/release.keystore.base64.txt
```

工作流会将 keystore 写入 `android/release.keystore`，并在 CI 里生成 `android/key.properties`（不入库）供 Gradle 读取。
> `key.properties` 里的 `storeFile` 路径是从 `android/app/`（Gradle 的 `:app` 模块目录）解析的，所以通常应填写 `../release.keystore`。

### 生成 keystore（示例：Windows / PowerShell）

需要已安装 JDK（确保 `keytool` 可用）：

```powershell
# 1) 生成 keystore（示例参数，可按需调整）
keytool -genkeypair -v `
  -keystore linplayer-release.keystore `
  -alias linplayer `
  -keyalg RSA -keysize 2048 -validity 36500

# 2) 生成 base64（单行，适合粘贴进 GitHub Secrets）
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("linplayer-release.keystore"))
$b64 | Set-Content -NoNewline linplayer-release.keystore.base64.txt
```

将 `linplayer-release.keystore.base64.txt` 的内容粘贴到 `ANDROID_KEYSTORE_BASE64` secret。

## 常见问题

- `base64: invalid input`：通常是 `ANDROID_KEYSTORE_BASE64` 中包含了 CRLF/空格等不可见字符；请用上面的命令重新生成 base64，或确保 Secrets 中是“纯 base64 字符串”。
