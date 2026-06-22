import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linplayer_mobile/core/services/backup_crypto.dart';
import 'package:linplayer_mobile/core/services/backup_identity.dart';

void main() {
  final x25519 = X25519();
  final ed25519 = Ed25519();

  Future<BackupPublicKey> pubOf(
      SimpleKeyPair encKp, SimpleKeyPair sigKp) async {
    final enc = await encKp.extractPublicKey();
    final sig = await sigKp.extractPublicKey();
    return BackupPublicKey(enc: enc.bytes, sig: sig.bytes);
  }

  group('BackupPublicKey token', () {
    test('encode/decode round-trips and keeps fingerprint', () async {
      final enc = await x25519.newKeyPair();
      final sig = await ed25519.newKeyPair();
      final pub = await pubOf(enc, sig);
      final decoded = BackupPublicKey.decode(pub.encode());
      expect(decoded.enc, pub.enc);
      expect(decoded.sig, pub.sig);
      expect(decoded.fingerprint, pub.fingerprint);
      expect(pub.encode().startsWith(BackupIdentity.tokenPrefix), isTrue);
    });

    test('rejects malformed token', () {
      expect(() => BackupPublicKey.decode('not-a-key'), throwsFormatException);
    });
  });

  group('BackupCrypto seal/open', () {
    test('recipient can open and verify sender signature', () async {
      final recipientEnc = await x25519.newKeyPair();
      final recipientSig = await ed25519.newKeyPair();
      final recipientPub = await pubOf(recipientEnc, recipientSig);

      final senderEnc = await x25519.newKeyPair();
      final senderSig = await ed25519.newKeyPair();
      final senderPub = await pubOf(senderEnc, senderSig);

      const plain = '{"version":"1.0.0","servers":[{"name":"hi"}]}';
      final wrapper = await BackupCrypto.sealTo(
        plain,
        recipient: recipientPub,
        senderEd25519: senderSig,
        senderPublicKey: senderPub,
        exportTimeUnix: 1750000000,
      );
      expect(BackupCrypto.isSealed(wrapper), isTrue);

      final result = await BackupCrypto.openSealed(
        wrapper,
        recipientX25519: recipientEnc,
        recipientPublicKey: recipientPub,
      );
      expect(result.plaintext, plain);
      expect(result.signatureValid, isTrue);
      expect(result.senderPublicKey?.fingerprint, senderPub.fingerprint);
    });

    test('wrong recipient is rejected by fingerprint', () async {
      final recipientEnc = await x25519.newKeyPair();
      final recipientSig = await ed25519.newKeyPair();
      final recipientPub = await pubOf(recipientEnc, recipientSig);

      final senderSig = await ed25519.newKeyPair();
      final senderEnc = await x25519.newKeyPair();
      final senderPub = await pubOf(senderEnc, senderSig);

      final wrapper = await BackupCrypto.sealTo(
        'secret',
        recipient: recipientPub,
        senderEd25519: senderSig,
        senderPublicKey: senderPub,
      );

      final otherEnc = await x25519.newKeyPair();
      final otherSig = await ed25519.newKeyPair();
      final otherPub = await pubOf(otherEnc, otherSig);

      expect(
        () => BackupCrypto.openSealed(
          wrapper,
          recipientX25519: otherEnc,
          recipientPublicKey: otherPub,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('tampered ciphertext fails to decrypt', () async {
      final recipientEnc = await x25519.newKeyPair();
      final recipientSig = await ed25519.newKeyPair();
      final recipientPub = await pubOf(recipientEnc, recipientSig);
      final senderSig = await ed25519.newKeyPair();
      final senderEnc = await x25519.newKeyPair();
      final senderPub = await pubOf(senderEnc, senderSig);

      final wrapper = await BackupCrypto.sealTo(
        'payload',
        recipient: recipientPub,
        senderEd25519: senderSig,
        senderPublicKey: senderPub,
      );
      // 翻转密文一个字节。
      final cipher = base64Decode('${wrapper['cipher']}');
      cipher[0] ^= 0xFF;
      wrapper['cipher'] = base64Encode(cipher);

      expect(
        () => BackupCrypto.openSealed(
          wrapper,
          recipientX25519: recipientEnc,
          recipientPublicKey: recipientPub,
        ),
        throwsA(anything),
      );
    });
  });
}
