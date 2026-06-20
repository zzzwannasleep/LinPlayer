# LinPlayer 备份文件格式

LinPlayer 的备份（本地导出 / WebDAV 备份）**自 v1.0.0 安全加固版起一律口令加密**，
因为备份里含**服务器账号密码与访问 Token**。明文导出已不再提供。

## 互相导入/导出须知（重要）

- 导出时你会被要求**设置一个备份密码**。这个密码**不保存在任何地方**。
- 把备份文件发给别人、或导入到另一台设备时，对方**必须输入同一个密码**才能解密导入。
- **忘记密码 = 无法恢复**（无后门、无法找回）。请妥善保管。
- 旧版本导出的**明文**备份仍可直接导入（向后兼容），但新导出一律加密。

## 加密备份文件结构

备份文件是一个 JSON 对象（加密包装）：

```json
{
  "linplayer_encrypted_backup": 1,
  "kdf": "pbkdf2-hmac-sha256",
  "cipher_alg": "aes-256-gcm",
  "iterations": 120000,
  "salt": "<base64, 16 字节随机盐>",
  "nonce": "<base64, AES-GCM nonce>",
  "cipher": "<base64, 密文>",
  "mac": "<base64, GCM 认证标签>"
}
```

- `linplayer_encrypted_backup` 存在即表示这是加密备份；导入端据此判断是否要求输入密码。
- 密钥派生：`PBKDF2-HMAC-SHA256(password, salt, iterations=120000) -> 256-bit key`。
- 加密：`AES-256-GCM(key, nonce)` 对**明文 payload 的 UTF-8 JSON**整体加密；`mac` 为
  GCM 认证标签，密码错误或文件被篡改时解密会失败（认证不通过）。

## 解密出的明文 payload

解密后是原始备份 payload（与旧明文备份同结构）：

```json
{
  "version": "1.0.0",
  "timestamp": "...",
  "currentServerId": "...",
  "servers": [ { "id": "...", "name": "...", "baseUrl": "...",
                 "authToken": "...", "password": "...", ... } ],
  "settings": { "...": "..." }
}
```

> 注意：明文 payload 里的 `servers[].password` / `authToken` 是真实凭据，这正是
> 备份必须整体加密的原因。App 运行时这些凭据存于 OS 安全存储（见 H11），
> 不在 SharedPreferences 明文落盘。

## 实现位置

- 加解密：`lib/core/services/backup_crypto.dart`（`BackupCrypto.encrypt/decrypt/isEncrypted`）。
- 导出/导入 UI：`lib/ui/screens/settings/settings_backup_restore.dart`。
