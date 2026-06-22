# LinPlayer 备份文件格式

LinPlayer 的备份（本地导出 / WebDAV 备份）默认采用**免密码、跨客户端**的「通用配置」
格式（与 Richasy/Rodel `common-config` 对齐）。备份里含**服务器账号密码与访问 Token**，
导出时会加密成乱码，避免明文凭据被随手读到；导入端无需密码即可还原。

> ⚠️ **安全级别 = 混淆级**：解密密钥随文件分发（`_key`）或内置在客户端里，能挡住
> "文件意外泄露后被随手翻到明文密码"，但**不防被刻意提取密钥后解密**。这是离线
> 客户端 + 免密 + 任意客户端可解的固有取舍。

## 通用配置容器（默认格式）

```json
{
  "from": "LinPlayer",
  "version": "1.0",
  "export_time": 1750000000,
  "configs": ["<base64 AES-256-CBC 密文>", "..."],
  "additional_data": { "linplayer_settings": { ... }, "current_server_id": "..." },
  "_key": "<base64, 解密密钥;带上即任何客户端可免密解>"
}
```

- 每个服务器配置先序列化成 **snake_case JSON**（`type/id/name/url/username/user_id/`
  `password/access_token/icon/lines/options`），再用 **AES-256-CBC/PKCS7** 加密，
  **IV = 密钥前 16 字节**，base64 后放入 `configs[]`。
- 导入端优先读 `_key`，否则回退本客户端内置密钥；解不开的单条跳过。
- `additional_data` 为明文（无密内容），放 LinPlayer 偏好等，别的客户端可忽略。
- 实现：`lib/core/services/common_config.dart`（`CommonConfig.build/parse/isCommonConfig`）。

## 第三方对接

要让别的客户端与 LinPlayer 互导，实现上面的容器即可：用 `_key`（或同一把内置密钥）
做 AES-256-CBC/PKCS7（IV=密钥前16字节）解出每个 `configs[]`，按 snake_case 字段
映射到自己的服务器模型。带 `_key` 的导出任何客户端都能免密解。

## 向后兼容：旧版口令加密备份（仅导入）

旧版本（v1.0.0 安全加固版）导出的备份是**口令加密**的，导入时仍支持：检测到
`linplayer_encrypted_backup` 字段会提示输入当时的密码解密。当前版本**不再产出**
这种格式（默认导出已改为上面的免密通用配置）。

```json
{
  "linplayer_encrypted_backup": 1,
  "kdf": "pbkdf2-hmac-sha256",
  "cipher_alg": "aes-256-gcm",
  "iterations": 120000,
  "salt": "<base64>", "nonce": "<base64>",
  "cipher": "<base64>", "mac": "<base64, GCM 认证标签>"
}
```

- 密钥派生：`PBKDF2-HMAC-SHA256(password, salt, 120000) -> 256-bit`，再 `AES-256-GCM` 解密。
- 实现：`lib/core/services/backup_crypto.dart`（`BackupCrypto.decrypt/isEncrypted`，仅导入用）。

旧版**明文**备份也仍可直接导入（向后兼容）。

## 实现位置

- 默认免密格式：`lib/core/services/common_config.dart`。
- 旧口令格式（仅导入）：`lib/core/services/backup_crypto.dart`。
- 导出/导入 UI：`lib/ui/screens/settings/settings_backup_restore.dart`。
