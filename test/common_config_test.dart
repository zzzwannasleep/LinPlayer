import 'package:flutter_test/flutter_test.dart';
import 'package:linplayer_mobile/core/providers/server_providers.dart';
import 'package:linplayer_mobile/core/services/common_config.dart';

void main() {
  ServerConfig sample() => ServerConfig(
        id: 'srv-1',
        name: '我的Emby',
        baseUrl: 'https://emby.example.com',
        iconUrl: 'https://emby.example.com/icon.png',
        remark: '家里',
        lines: [
          ServerLine(id: 'l1', name: '内网', url: 'http://192.168.1.2:8096'),
          ServerLine(id: 'l2', name: '公网', url: 'https://emby.example.com'),
        ],
        activeLineIndex: 1,
        username: 'alice',
        authToken: 'TOKEN-ABC',
        userId: 'u123',
        password: 'p@ss',
        allowInsecureTls: true,
      );

  test('isCommonConfig 识别容器', () async {
    final c = await CommonConfig.build([sample()]);
    expect(CommonConfig.isCommonConfig(c), isTrue);
    expect(CommonConfig.isCommonConfig({'servers': []}), isFalse);
  });

  test('容器携带 _key 与元数据', () async {
    final c = await CommonConfig.build([sample()],
        exportTimeUnix: 1750000000, extra: {'k': 'v'});
    expect(c['from'], 'LinPlayer');
    expect(c['version'], '1.0');
    expect(c['export_time'], 1750000000);
    expect((c['configs'] as List).length, 1);
    expect(c['_key'], isA<String>());
    expect((c['additional_data'] as Map)['k'], 'v');
    // configs 元素是 base64 密文,不含明文凭据。
    expect((c['configs'] as List).first.toString().contains('TOKEN-ABC'), isFalse);
  });

  test('往返: build -> parse 保留服务器字段(用文件内 _key)', () async {
    final original = sample();
    final container = await CommonConfig.build([original]);
    final parsed = await CommonConfig.parse(container);
    expect(parsed.length, 1);
    final s = parsed.first;
    expect(s.id, original.id);
    expect(s.name, original.name);
    expect(s.baseUrl, original.baseUrl);
    expect(s.iconUrl, original.iconUrl);
    expect(s.remark, original.remark);
    expect(s.username, original.username);
    expect(s.userId, original.userId);
    expect(s.password, original.password);
    expect(s.authToken, original.authToken);
    expect(s.allowInsecureTls, original.allowInsecureTls);
    expect(s.activeLineIndex, original.activeLineIndex);
    expect(s.lines.length, 2);
    expect(s.lines[0].url, original.lines[0].url);
    expect(s.lines[1].name, original.lines[1].name);
  });

  test('无 _key 时回退内置密钥仍可解', () async {
    final container = await CommonConfig.build([sample()], includeKey: false);
    expect(container.containsKey('_key'), isFalse);
    final parsed = await CommonConfig.parse(container);
    expect(parsed.single.authToken, 'TOKEN-ABC');
  });
}
