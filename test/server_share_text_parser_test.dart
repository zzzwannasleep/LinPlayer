import 'package:flutter_test/flutter_test.dart';

import 'package:lin_player/services/server_share_text_parser.dart';

void main() {
  test('parse share text with per-line ports', () {
    const raw = '''
▎↓目前线路 & 用户密码：26250163abc
主线路(推荐)
https://www.lilyemby.com 443
(全球可连)

CDN直连线路 (推荐)
https://cdn.lilyemby.com 443
(仅限中国大陆连接)

腾讯CDN线路
https://tx.lilyemby.com 443
(全球可连)

阿里CDN线路
https://aliyun.lilyemby.com 443
(全球可连)

客户端 https://t.me/lilyemby/58

公开探针 https://tz.lily.lat
''';

    final groups = ServerShareTextParser.parse(raw);
    expect(groups, hasLength(1));

    final g = groups.single;
    expect(g.password, '26250163abc');

    final urls = g.lines.map((l) => l.url).toSet();
    expect(
      urls,
      containsAll(<String>{
        'https://www.lilyemby.com',
        'https://cdn.lilyemby.com',
        'https://tx.lilyemby.com',
        'https://aliyun.lilyemby.com',
      }),
    );

    final main = g.lines.firstWhere((l) => l.url == 'https://www.lilyemby.com');
    expect(main.name, '主线路(推荐)');
    expect(main.selectedByDefault, isTrue);

    final telegram = g.lines.firstWhere((l) => l.url.startsWith('https://t.me/'));
    expect(telegram.selectedByDefault, isFalse);

    final probe = g.lines.firstWhere((l) => l.url == 'https://tz.lily.lat');
    expect(probe.selectedByDefault, isFalse);
  });

  test('parse share text with global port', () {
    const raw = '''
▎↓目前线路 & 用户密码：26250163abc

cf线路: https://mecf.mebimmer.de
原生线路: https://meenjoy.mebimmer.de
端口: 443
''';

    final groups = ServerShareTextParser.parse(raw);
    expect(groups, hasLength(1));

    final g = groups.single;
    expect(g.password, '26250163abc');

    expect(
      g.lines.map((l) => l.url).toList(),
      [
        'https://mecf.mebimmer.de',
        'https://meenjoy.mebimmer.de',
      ],
    );
    expect(g.lines.first.name, 'cf线路');
    expect(g.lines.first.selectedByDefault, isTrue);
  });
}

