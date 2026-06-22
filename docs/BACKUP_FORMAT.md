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

## 加密给指定设备（非对称 / 无需口令，H13）

除口令加密外，还支持把备份**加密给某台设备的公钥**——对方无需和你约定密码，
导出的文件**只有持有对应私钥的那台设备能解开**；同时用导出方的私钥签名，导入方
可验证来源与完整性。这是标准 ECIES / sealed-box 方案，任何实现同一方案的客户端
都可互通。

### 设备身份（密钥对）

每台设备首次需要时生成一对长期密钥，私钥存入 OS 安全存储，永不离开本机：

- **X25519**：密钥协商（把备份加密给本设备时用本设备的 X25519 公钥）。
- **Ed25519**：签名（证明备份由本设备导出且未被篡改）。

可分享的公钥串（二维码 / 文本）格式：

```
LPKEY1:<base64url( x25519_pub(32) || ed25519_pub(32) )>
```

指纹（供双方口头核对）= `SHA-256(x25519_pub || ed25519_pub)` 前 5 字节的十六进制，
形如 `A1B2-C3D4-E5`。实现见 `lib/core/services/backup_identity.dart`。

### 封装文件结构

```json
{
  "linplayer_sealed_backup": 1,
  "alg": "x25519-hkdf-sha256-aes256gcm",
  "sig_alg": "ed25519",
  "from": "LinPlayer",
  "version": "2.0",
  "export_time": 1750000000,
  "epk": "<base64, 一次性 X25519 临时公钥(32B)>",
  "recipient_fp": "<收件人公钥指纹，用于早判断是否发给本设备>",
  "nonce": "<base64, AES-GCM nonce(12B)>",
  "cipher": "<base64, 密文>",
  "mac": "<base64, GCM 认证标签>",
  "sender_pub": "LPKEY1:<导出方公钥串>",
  "sig": "<base64, Ed25519 签名>"
}
```

### 算法流程

1. 导出方生成一次性 X25519 临时密钥对 `epk/esk`。
2. 共享密钥 `ss = X25519(esk, recipient_x25519_pub)`。
3. 对称密钥 `k = HKDF-SHA256(ss, salt=空, info="lpseal1" || epk || recipient_x25519_pub, len=32)`。
4. `cipher,mac = AES-256-GCM(k, nonce).encrypt(明文 payload 的 UTF-8 JSON)`。
5. `sig = Ed25519.sign(sender_sk, epk || nonce || cipher || mac)`。

导入方用本设备 X25519 私钥重算 `ss → k` 解密；用 `sender_pub` 里的 Ed25519 公钥验签。
`recipient_fp` 与本设备指纹不一致会直接报「不是发给本设备」，比 GCM 失败更友好。

> 解密出的明文 payload 与上文口令备份完全一致（同一 `_buildBackupPayload`）。

## 实现位置

- 口令加解密：`lib/core/services/backup_crypto.dart`（`BackupCrypto.encrypt/decrypt/isEncrypted`）。
- 非对称封装：`lib/core/services/backup_crypto.dart`（`BackupCrypto.sealTo/openSealed/isSealed`）。
- 设备密钥对：`lib/core/services/backup_identity.dart`（`BackupIdentity` / `BackupPublicKey`）。
- 导出/导入 UI：`lib/ui/screens/settings/settings_backup_restore.dart`。

## 第三方对接

要让别的客户端与 LinPlayer 互导，**只需对齐上面的明文 payload + 任一种信封**：

- 想最省事：实现「密码模式」(`linplayer_encrypted_backup`)，无需密钥交换，双方约定一个密码即可。
- 想免密互传：实现「加密给设备」(`linplayer_sealed_backup`)，双方各自生成密钥对并交换 `LPKEY1` 公钥串。

可编译的 C 语言参考实现（libsodium + cJSON，含密钥生成/封装/解封/验签的完整往返）见
`docs/interop/lp_backup_interop.c`。HKDF 互通性（空 salt 等价 RFC 5869）有回归测试
`test/backup_hkdf_interop_test.dart` 守护。
