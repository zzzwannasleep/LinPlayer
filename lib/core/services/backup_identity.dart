import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'secure_credential_store.dart';

/// 备份「设备身份」——非对称加密的密钥对（H13）。
///
/// 每台设备首次需要时生成一对长期密钥并存入 OS 安全存储：
///  - **X25519**：用于密钥协商（把备份「加密给某台设备」时用对方的 X25519 公钥）。
///  - **Ed25519**：用于签名（证明备份确实由本设备导出、未被篡改）。
///
/// 公钥可被分享（二维码 / 文本），私钥永不离开本机安全存储。配套封装/解封逻辑
/// 见 `BackupCrypto.sealTo` / `BackupCrypto.openSealed`，格式见 `docs/BACKUP_FORMAT.md`。
class BackupIdentity {
  BackupIdentity._();
  static final BackupIdentity instance = BackupIdentity._();

  /// OS 安全存储里的私钥种子键（各 32 字节，base64）。
  static const _encSeedKey = 'backup_id_x25519_seed_v1';
  static const _sigSeedKey = 'backup_id_ed25519_seed_v1';

  /// 可分享公钥字符串的前缀/版本标记。
  static const tokenPrefix = 'LPKEY1:';

  static final X25519 _x25519 = X25519();
  static final Ed25519 _ed25519 = Ed25519();

  SimpleKeyPair? _encKeyPair;
  SimpleKeyPair? _sigKeyPair;
  BackupPublicKey? _publicKey;

  /// 确保密钥对已就绪（首次调用会生成并持久化）。需在
  /// `SecureCredentialStore.initialize()` 之后调用。
  Future<void> _ensure() async {
    if (_encKeyPair != null && _sigKeyPair != null && _publicKey != null) {
      return;
    }
    final store = SecureCredentialStore.instance;

    var encSeedB64 = store.readKv(_encSeedKey);
    if (encSeedB64 == null || encSeedB64.isEmpty) {
      encSeedB64 = base64Encode(secureRandomBytes(32));
      await store.writeKv(_encSeedKey, encSeedB64);
    }
    var sigSeedB64 = store.readKv(_sigSeedKey);
    if (sigSeedB64 == null || sigSeedB64.isEmpty) {
      sigSeedB64 = base64Encode(secureRandomBytes(32));
      await store.writeKv(_sigSeedKey, sigSeedB64);
    }

    _encKeyPair = await _x25519.newKeyPairFromSeed(base64Decode(encSeedB64));
    _sigKeyPair = await _ed25519.newKeyPairFromSeed(base64Decode(sigSeedB64));
    final encPub = await _encKeyPair!.extractPublicKey();
    final sigPub = await _sigKeyPair!.extractPublicKey();
    _publicKey = BackupPublicKey(enc: encPub.bytes, sig: sigPub.bytes);
  }

  /// 本设备公钥（含 X25519 加密公钥 + Ed25519 签名公钥）。
  Future<BackupPublicKey> myPublicKey() async {
    await _ensure();
    return _publicKey!;
  }

  /// 本设备 X25519 密钥对（解封他人发来的备份时用）。
  Future<SimpleKeyPair> encryptionKeyPair() async {
    await _ensure();
    return _encKeyPair!;
  }

  /// 本设备 Ed25519 密钥对（导出时签名用）。
  Future<SimpleKeyPair> signingKeyPair() async {
    await _ensure();
    return _sigKeyPair!;
  }
}

/// 一台设备的可分享公钥：X25519 加密公钥（32B）+ Ed25519 签名公钥（32B）。
class BackupPublicKey {
  final List<int> enc;
  final List<int> sig;
  const BackupPublicKey({required this.enc, required this.sig});

  /// 编码为单行可分享字符串：`LPKEY1:<base64url(enc(32)||sig(32))>`。
  String encode() {
    final bytes = <int>[...enc, ...sig];
    return '${BackupIdentity.tokenPrefix}${base64Url.encode(bytes)}';
  }

  /// 解析 [encode] 产生的字符串。容忍前后空白；非法输入抛 [FormatException]。
  static BackupPublicKey decode(String token) {
    var t = token.trim();
    if (t.startsWith(BackupIdentity.tokenPrefix)) {
      t = t.substring(BackupIdentity.tokenPrefix.length);
    }
    final bytes = base64Url.decode(base64Url.normalize(t.trim()));
    if (bytes.length != 64) {
      throw const FormatException('公钥长度不正确（应为 64 字节）');
    }
    return BackupPublicKey(
      enc: bytes.sublist(0, 32),
      sig: bytes.sublist(32, 64),
    );
  }

  /// 人类可读的短指纹（SHA-256 前 5 字节，形如 `A1B2-C3D4-E5`），用于双方口头核对。
  String get fingerprint {
    final digest = crypto.sha256.convert(<int>[...enc, ...sig]).bytes;
    final hex = digest
        .take(5)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-${hex.substring(8, 10)}';
  }
}
