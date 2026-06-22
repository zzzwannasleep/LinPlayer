import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// 守护 docs/BACKUP_FORMAT.md 里发布的测试向量:确保第三方按文档实现时,
/// 文档给出的密文确实能解出文档给出的明文(算法/内置密钥若改动会在此报警)。
void main() {
  test('docs/BACKUP_FORMAT.md 测试向量解密结果与文档一致', () async {
    const keyB64 = 'TGluUGxheWVyLWNvbW1vbi1jb25maWcta2V5LXYxIQA=';
    const cfg0 =
        'RKTzQSr63I3NUMklxTXzIgSrZPxQHJB67Lt9i4DwXazbqSdysl8PuddwUirvl2hjXAhasTfVXsjMS/iT1kEF6ZDoeJ8UFwYzA97xKugHPNlucq2aSxzin2qq67Hr77B5JVdVL2s1wvrs7+oUyYEI1vUHFplaedtVY/ulcj3oRtj8RvEaWV/6oXq+iCiui9oiUktVTebE1UdctPrYreZyvpyRFEXun7iXIvXaDeQtKxK0aPd1a1TYMyKvDV+XseWqCFa6U8j4256KTbDsz7qs0N26o+8KamA2jfIwdqzbOr9VZUCCC641WO86bndEQHHI1P0HGXYBwhi4LOy41eakf4lshf8mc/COgqDQAPfCLKpQuoxgXyyRcRAx4mweLABInmyE0FacKsT4AWEAM2l68+OtbrTEmWuYuFaVFNw7dZc=';
    const expected =
        '{"type":"emby","id":"srv-1","name":"My Emby","url":"https://emby.example.com","username":"alice","user_id":"u123","password":"p@ss","access_token":"TOKEN-ABC","icon":null,"lines":[{"id":"l1","name":"LAN","url":"http://192.168.1.2:8096","remark":null}],"options":{"active_line_index":0,"allow_insecure_tls":false}}';

    final key = base64Decode(keyB64);
    final iv = key.sublist(0, 16);
    final aes = AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);
    final clear = await aes.decrypt(
      SecretBox(base64Decode(cfg0), nonce: iv, mac: Mac.empty),
      secretKey: SecretKey(key),
    );
    expect(utf8.decode(clear), expected);
  });
}
