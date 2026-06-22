import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// 教科书版 RFC 5869 HKDF-SHA256(salt 为空时按 HashLen 个 0 处理),
/// 用来验证 `cryptography` 包的 HKDF 与 libsodium/RFC 5869 互通。
List<int> rfc5869Hkdf({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  int length = 32,
}) {
  final effSalt = salt.isEmpty ? List<int>.filled(32, 0) : salt;
  final prk = c.Hmac(c.sha256, effSalt).convert(ikm).bytes; // Extract
  final out = <int>[];
  var t = <int>[];
  var counter = 1;
  while (out.length < length) {
    t = c.Hmac(c.sha256, prk).convert(<int>[...t, ...info, counter]).bytes;
    out.addAll(t);
    counter++;
  }
  return out.sublist(0, length);
}

void main() {
  test('cryptography 包 HKDF(空 salt) == RFC 5869 (libsodium 等价)', () async {
    final ikm = utf8.encode('shared-secret-32-bytes-xxxxxxxxx'); // 任意 IKM
    final info = <int>[...utf8.encode('lpseal1'), 1, 2, 3, 4, 5];

    final pkg = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(ikm),
      nonce: const [], // 包里的 nonce 即 HKDF salt
      info: info,
    );
    final pkgBytes = await pkg.extractBytes();

    final manual = rfc5869Hkdf(ikm: ikm, salt: const [], info: info);
    expect(pkgBytes, manual);
  });
}
