# LinPlayer 备份文件格式 / 兼容指南

> 本文档面向**想让自己的客户端与 LinPlayer 互相导入/导出服务器配置**的开发者。
> 照本文实现即可与 LinPlayer 双向互通(也与 Richasy/Rodel 的 `common-config` 同源)。

LinPlayer 备份默认采用**免密码、跨客户端**的「通用配置(common-config)」格式。备份里含
**服务器地址、账号、密码与访问 Token**;导出时把每条配置加密成乱码,导入端无需密码即可还原。

> ⚠️ **安全级别 = 混淆级。** 解密密钥随文件分发(`_key` 字段)或内置在客户端里,
> 目的是「文件意外泄露时不被随手读到明文密码」,**不防被刻意提取密钥后解密**。
> 这是「离线文件 + 免密 + 任意客户端可解」三者并存时的固有取舍,请勿当作强加密。

---

## 1. 容器结构

整个文件是一个 UTF-8 的 JSON 对象:

```json
{
  "from": "LinPlayer",
  "version": "1.0",
  "export_time": 1750000000,
  "configs": ["<base64( AES-256-CBC 密文 )>", "..."],
  "additional_data": { "linplayer_settings": { }, "current_server_id": "srv-1" },
  "_key": "<base64( 32 字节密钥 )>"
}
```

| 字段 | 类型 | 必需 | 说明 |
|---|---|:---:|---|
| `configs` | string[] | ✅ | 每个元素是**一条服务器配置**加密后的 base64 密文(见 §3) |
| `_key` | string | 否(强烈建议) | 解密密钥的 base64。带上它,**任何客户端都能免密解**;不带则需用内置密钥(见 §2) |
| `from` | string | 否 | 导出方标识,如 `"LinPlayer"` / `"RodelPlayer"`。仅信息性 |
| `version` | string | 否 | 格式版本,当前 `"1.0"` |
| `export_time` | number | 否 | 导出时间(Unix 秒) |
| `additional_data` | object | 否 | **明文**附加数据(无敏感内容)。LinPlayer 放偏好设置等;别的客户端可整体忽略 |

判定一个文件是否为本格式:**`configs` 是数组**即可。

`additional_data`(可选,LinPlayer 专用,他人忽略即可):

| 键 | 说明 |
|---|---|
| `linplayer_settings` | LinPlayer 的 App 偏好(主题/播放器等),明文对象 |
| `current_server_id` | 当前选中的服务器 `id` |

---

## 2. 密钥

- 密钥为 **32 字节(AES-256)**。
- 导出端**应**把密钥的 base64 写进 `_key`,这样任何实现本格式的客户端都能免密解密。
- 若某文件**没有** `_key`,LinPlayer 回退到内置默认密钥:

  - ASCII:`LinPlayer-common-config-key-v1!` 后跟 1 个 `0x00` 字节(共 31 + 1 = **32 字节**)
  - base64:`TGluUGxheWVyLWNvbW1vbi1jb25maWcta2V5LXYxIQA=`

  > 这把内置密钥**本就公开**(开源代码里可见),它只是「文件未带 `_key` 时」的兜底。
  > 你的客户端导出时只要带上自己的 `_key`,LinPlayer 就用你的 `_key` 解,无需这把内置密钥。

---

## 3. 单条配置的加密

`configs[]` 的每个元素 = 一条服务器配置,按如下方式加密:

1. 把该服务器序列化成 **snake_case 的 JSON 字符串**(字段见 §4),UTF-8 编码。
2. **AES-256-CBC** 加密,**PKCS#7 填充**。
3. **IV = 密钥的前 16 字节**(`iv = key[0:16]`)。注意:IV 不是随机的,直接取密钥前 16 字节。
4. 把密文做**标准 base64**(RFC 4648,带 `=` 填充)放进数组。

解密就是逆过程:`base64 解码 → AES-256-CBC 解密(IV=key[0:16])→ 去 PKCS#7 填充 → UTF-8 → JSON 解析`。

> 兼容要点(常见坑):
> - **IV 取密钥前 16 字节**,不是随机 IV、也不在文件里。
> - **PKCS#7 填充**,不是零填充。
> - base64 是**标准变体**(`+`/`/`,带 `=`),不是 url-safe。
> - 没有单独的认证标签(CBC 无 MAC)。解错密钥通常表现为去填充失败,解不开的单条**跳过**即可。

---

## 4. 单条配置的字段(snake_case)

加密前/解密后的明文 JSON 结构:

```json
{
  "type": "emby",
  "id": "srv-1",
  "name": "My Emby",
  "url": "https://emby.example.com",
  "username": "alice",
  "user_id": "u123",
  "password": "p@ss",
  "access_token": "TOKEN-ABC",
  "icon": null,
  "lines": [
    { "id": "l1", "name": "LAN", "url": "http://192.168.1.2:8096", "remark": null }
  ],
  "options": { "active_line_index": 0, "allow_insecure_tls": false }
}
```

| 字段 | 类型 | 含义 | LinPlayer 映射 |
|---|---|---|---|
| `type` | string | 服务类型 | 固定 `"emby"`(导入时不强校验) |
| `id` | string | 配置唯一 ID | `id`(缺失则自动生成 UUID) |
| `name` | string | 显示名 | `name`(缺省「服务器」) |
| `url` | string | 服务器地址 | `baseUrl`(为空则该条丢弃) |
| `username` | string? | 账号 | `username` |
| `user_id` | string? | 用户 ID | `userId` |
| `password` | string? | 密码 | `password` |
| `access_token` | string? | 访问令牌 | `authToken` |
| `icon` | string? | 图标 URL | `iconUrl` |
| `lines` | array? | 备用线路 | 见下 |
| `options` | object? | 杂项 | 见下 |

`lines[i]`:

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 线路 ID(缺失自动生成) |
| `name` | string | 线路名(缺省「线路」) |
| `url` | string | 线路地址(为空则该线路丢弃) |
| `remark` | string? | 备注 |

`options`:

| 键 | 类型 | 说明 |
|---|---|---|
| `active_line_index` | int | 当前线路下标,默认 0 |
| `allow_insecure_tls` | bool | 是否信任自签名 TLS,默认 false |
| `remark` | string? | 服务器备注 |

> LinPlayer **忽略未知字段**。Richasy/Rodel 的额外字段(`sort_order`、`create`/`update`/
> `last_play`/`last_open` 等)可以保留,LinPlayer 不会用到,也不会因此报错。

---

## 5. 参考实现

### Python(`cryptography`)

```python
import base64, json
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

def decrypt_container(container: dict) -> list[dict]:
    key = base64.b64decode(container["_key"])      # 32 字节
    iv = key[:16]                                  # IV = 密钥前 16 字节
    servers = []
    for c in container["configs"]:
        dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        padded = dec.update(base64.b64decode(c)) + dec.finalize()
        unp = padding.PKCS7(128).unpadder()
        data = unp.update(padded) + unp.finalize()
        servers.append(json.loads(data.decode("utf-8")))
    return servers

def encrypt_container(servers: list[dict], key: bytes) -> dict:
    iv = key[:16]
    configs = []
    for s in servers:
        enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        p = padding.PKCS7(128).padder()
        data = p.update(json.dumps(s, ensure_ascii=False).encode("utf-8")) + p.finalize()
        configs.append(base64.b64encode(enc.update(data) + enc.finalize()).decode())
    return {"from": "MyClient", "version": "1.0", "configs": configs,
            "_key": base64.b64encode(key).decode()}
```

### Node.js(内置 `crypto`)

```js
const crypto = require('crypto');

function decryptContainer(container) {
  const key = Buffer.from(container._key, 'base64');   // 32 字节
  const iv = key.subarray(0, 16);                      // IV = 密钥前 16 字节
  return container.configs.map(c => {
    const d = crypto.createDecipheriv('aes-256-cbc', key, iv); // 默认 PKCS#7
    const buf = Buffer.concat([d.update(Buffer.from(c, 'base64')), d.final()]);
    return JSON.parse(buf.toString('utf8'));
  });
}
```

### C#(`System.Security.Cryptography`)

```csharp
using var aes = Aes.Create();
aes.Mode = CipherMode.CBC;
aes.Padding = PaddingMode.PKCS7;
aes.Key = key;                 // 32 字节
aes.IV = key[..16];            // IV = 密钥前 16 字节
var plain = aes.CreateDecryptor().TransformFinalBlock(cipher, 0, cipher.Length);
```

---

## 6. 测试向量(可用于自检)

下面是用**内置默认密钥**、`export_time=1750000000` 生成的真实文件。把它喂给你的解密实现,
应当还原出后面的明文配置(完全确定性:IV 由密钥派生,无随机量,结果可复现)。

```json
{
  "from": "LinPlayer",
  "version": "1.0",
  "export_time": 1750000000,
  "configs": [
    "RKTzQSr63I3NUMklxTXzIgSrZPxQHJB67Lt9i4DwXazbqSdysl8PuddwUirvl2hjXAhasTfVXsjMS/iT1kEF6ZDoeJ8UFwYzA97xKugHPNlucq2aSxzin2qq67Hr77B5JVdVL2s1wvrs7+oUyYEI1vUHFplaedtVY/ulcj3oRtj8RvEaWV/6oXq+iCiui9oiUktVTebE1UdctPrYreZyvpyRFEXun7iXIvXaDeQtKxK0aPd1a1TYMyKvDV+XseWqCFa6U8j4256KTbDsz7qs0N26o+8KamA2jfIwdqzbOr9VZUCCC641WO86bndEQHHI1P0HGXYBwhi4LOy41eakf4lshf8mc/COgqDQAPfCLKpQuoxgXyyRcRAx4mweLABInmyE0FacKsT4AWEAM2l68+OtbrTEmWuYuFaVFNw7dZc="
  ],
  "additional_data": {
    "linplayer_settings": { "themeMode": "dark" },
    "current_server_id": "srv-1"
  },
  "_key": "TGluUGxheWVyLWNvbW1vbi1jb25maWcta2V5LXYxIQA="
}
```

`configs[0]` 解密后(去 PKCS#7、UTF-8)应当等于:

```json
{"type":"emby","id":"srv-1","name":"My Emby","url":"https://emby.example.com","username":"alice","user_id":"u123","password":"p@ss","access_token":"TOKEN-ABC","icon":null,"lines":[{"id":"l1","name":"LAN","url":"http://192.168.1.2:8096","remark":null}],"options":{"active_line_index":0,"allow_insecure_tls":false}}
```

---

## 7. 向后兼容(仅导入)

LinPlayer 还能导入两种旧格式(当前**不再产出**它们):

1. **旧版口令加密备份**:含 `linplayer_encrypted_backup` 字段,`PBKDF2-HMAC-SHA256(pwd, salt, 120000)`
   → `AES-256-GCM` 解密,导入时提示输入密码。
2. **旧版明文备份**:直接是 payload JSON(`{version, servers:[...], settings:{}}`)。

新客户端做兼容**只需实现 §1–§4 的通用配置**即可,旧格式可不管。

---

## 8. 实现位置

- 默认免密格式:`lib/core/services/common_config.dart`(`CommonConfig.build/parse/isCommonConfig`)。
- 旧口令格式(仅导入):`lib/core/services/backup_crypto.dart`。
- 导出/导入 UI:`lib/ui/screens/settings/settings_backup_restore.dart`。
- 回归测试:`test/common_config_test.dart`。
