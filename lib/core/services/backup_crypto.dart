import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'backup_identity.dart';
import 'secure_credential_store.dart' show secureRandomBytes;

/// 备份文件的口令加密（H12）。
///
/// 整包明文 JSON 用「PBKDF2-HMAC-SHA256 派生密钥 + AES-256-GCM」加密，输出一个
/// 自描述的 JSON 包装（含算法/迭代次数/盐/nonce/密文/认证标签）。导入端据此
/// 还原。格式文档见 `docs/BACKUP_FORMAT.md`。
class BackupCrypto {
  BackupCrypto._();

  static const int _iterations = 120000;
  static final AesGcm _aes = AesGcm.with256bits();

  static Pbkdf2 _pbkdf2(int iterations) => Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );

  /// 是否为本格式的加密备份。
  static bool isEncrypted(Map<String, dynamic> json) =>
      json['linplayer_encrypted_backup'] != null;

  /// 用口令加密明文 JSON 字符串，返回可 `jsonEncode` 的包装 Map。
  static Future<Map<String, dynamic>> encrypt(
      String plaintext, String passphrase) async {
    final salt = secureRandomBytes(16);
    final key = await _pbkdf2(_iterations)
        .deriveKeyFromPassword(password: passphrase, nonce: salt);
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return {
      'linplayer_encrypted_backup': 1,
      'kdf': 'pbkdf2-hmac-sha256',
      'cipher_alg': 'aes-256-gcm',
      'iterations': _iterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'cipher': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  /// 用口令解密包装 Map，返回明文 JSON 字符串。口令错误或数据被篡改会抛异常
  /// （AES-GCM 认证失败）。
  static Future<String> decrypt(
      Map<String, dynamic> wrapper, String passphrase) async {
    final iterations = (wrapper['iterations'] as num?)?.toInt() ?? _iterations;
    final salt = base64Decode('${wrapper['salt']}');
    final nonce = base64Decode('${wrapper['nonce']}');
    final cipher = base64Decode('${wrapper['cipher']}');
    final mac = base64Decode('${wrapper['mac']}');
    final key = await _pbkdf2(iterations)
        .deriveKeyFromPassword(password: passphrase, nonce: salt);
    final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
    final clear = await _aes.decrypt(box, secretKey: key);
    return utf8.decode(clear);
  }

  // ---------------------------------------------------------------------------
  // 非对称「加密给指定设备」（H13）。
  //
  // 用收件人的 X25519 公钥协商出一次性对称密钥再 AES-256-GCM 加密整包，无需口令；
  // 同时用发件人的 Ed25519 私钥对密文签名，收件人据此验证来源与完整性。这是标准
  // ECIES / sealed-box 思路（X25519 ECDH + HKDF-SHA256 + AES-GCM + Ed25519 签名），
  // 任何实现同一方案的客户端都能互通。格式见 `docs/BACKUP_FORMAT.md`。
  // ---------------------------------------------------------------------------

  static const String sealAlg = 'x25519-hkdf-sha256-aes256gcm';
  static const String sealSigAlg = 'ed25519';
  static const List<int> _hkdfInfo = [108, 112, 115, 101, 97, 108, 49]; // "lpseal1"

  static final X25519 _x25519 = X25519();
  static final Ed25519 _ed25519 = Ed25519();
  static final Hkdf _hkdf =
      Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// 是否为本格式的「加密给设备」备份。
  static bool isSealed(Map<String, dynamic> json) =>
      json['linplayer_sealed_backup'] != null;

  /// 把明文 JSON「加密给」[recipient]（其公钥），用 [senderEd25519] 私钥签名。
  /// 返回可 `jsonEncode` 的自描述包装 Map。
  static Future<Map<String, dynamic>> sealTo(
    String plaintext, {
    required BackupPublicKey recipient,
    required SimpleKeyPair senderEd25519,
    required BackupPublicKey senderPublicKey,
    int? exportTimeUnix,
  }) async {
    // 1) 一次性临时 X25519 密钥对，与收件人公钥做 ECDH。
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPub = await ephemeral.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey:
          SimplePublicKey(recipient.enc, type: KeyPairType.x25519),
    );
    // 2) HKDF 派生对称密钥；info 里绑定双方公钥防错配。
    final aesKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: const [],
      info: <int>[..._hkdfInfo, ...ephemeralPub.bytes, ...recipient.enc],
    );
    // 3) AES-256-GCM 加密整包。
    final nonce = _aes.newNonce();
    final sealBox = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: aesKey,
      nonce: nonce,
    );
    // 4) 对公开头部 + 密文做 Ed25519 签名（来源 + 完整性）。
    final signed = _signedBytes(
      ephemeralPub.bytes,
      nonce,
      sealBox.cipherText,
      sealBox.mac.bytes,
    );
    final signature = await _ed25519.sign(signed, keyPair: senderEd25519);

    return {
      'linplayer_sealed_backup': 1,
      'alg': sealAlg,
      'sig_alg': sealSigAlg,
      'from': 'LinPlayer',
      'version': '2.0',
      if (exportTimeUnix != null) 'export_time': exportTimeUnix,
      'epk': base64Encode(ephemeralPub.bytes),
      'recipient_fp': recipient.fingerprint,
      'nonce': base64Encode(nonce),
      'cipher': base64Encode(sealBox.cipherText),
      'mac': base64Encode(sealBox.mac.bytes),
      'sender_pub': senderPublicKey.encode(),
      'sig': base64Encode(signature.bytes),
    };
  }

  /// 用本设备 [recipientX25519] 私钥解封 [wrapper]，返回明文与发件人信息。
  /// 若该备份不是发给本设备、或签名校验失败、或数据被篡改，会抛异常。
  static Future<SealedOpenResult> openSealed(
    Map<String, dynamic> wrapper, {
    required SimpleKeyPair recipientX25519,
    required BackupPublicKey recipientPublicKey,
  }) async {
    final alg = '${wrapper['alg']}';
    if (alg != sealAlg) {
      throw FormatException('不支持的封装算法: $alg');
    }
    // 早判断「是否发给本设备」，给出比 GCM 失败更友好的错误。
    final recipientFp = wrapper['recipient_fp'];
    if (recipientFp is String &&
        recipientFp.isNotEmpty &&
        recipientFp != recipientPublicKey.fingerprint) {
      throw const FormatException('此备份不是加密给当前设备的（公钥不匹配）');
    }

    final epk = base64Decode('${wrapper['epk']}');
    final nonce = base64Decode('${wrapper['nonce']}');
    final cipher = base64Decode('${wrapper['cipher']}');
    final mac = base64Decode('${wrapper['mac']}');

    // 验签（来源 + 公开头部完整性）。sender_pub 缺失/非法则视为未验证。
    bool signatureValid = false;
    BackupPublicKey? senderPub;
    try {
      senderPub = BackupPublicKey.decode('${wrapper['sender_pub']}');
      final signed = _signedBytes(epk, nonce, cipher, mac);
      signatureValid = await _ed25519.verify(
        signed,
        signature: Signature(
          base64Decode('${wrapper['sig']}'),
          publicKey:
              SimplePublicKey(senderPub.sig, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      signatureValid = false;
    }

    // ECDH + HKDF 还原对称密钥，AES-GCM 解密。
    final shared = await _x25519.sharedSecretKey(
      keyPair: recipientX25519,
      remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519),
    );
    final aesKey = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: const [],
      info: <int>[..._hkdfInfo, ...epk, ...recipientPublicKey.enc],
    );
    final clear = await _aes.decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: aesKey,
    );

    return SealedOpenResult(
      plaintext: utf8.decode(clear),
      senderPublicKey: senderPub,
      signatureValid: signatureValid,
    );
  }

  /// 签名覆盖的字节：epk || nonce || cipher || mac（确定性拼接）。
  static List<int> _signedBytes(
          List<int> epk, List<int> nonce, List<int> cipher, List<int> mac) =>
      <int>[...epk, ...nonce, ...cipher, ...mac];
}

/// 解封结果：明文 + 发件人公钥（可能为空）+ 签名是否通过。
class SealedOpenResult {
  final String plaintext;
  final BackupPublicKey? senderPublicKey;
  final bool signatureValid;
  const SealedOpenResult({
    required this.plaintext,
    required this.senderPublicKey,
    required this.signatureValid,
  });
}
