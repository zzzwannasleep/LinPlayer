import 'package:flutter_test/flutter_test.dart';

import 'package:lin_player/services/emby_api.dart';
import 'package:lin_player/state/route_entries.dart';

void main() {
  test('includes current url when list is empty', () {
    final entries = buildRouteEntries(
      currentUrl: 'https://emby.example.com',
      customEntries: const [],
      pluginDomains: const [],
    );

    expect(entries, hasLength(1));
    expect(entries.single.domain.name, '登录线路');
    expect(entries.single.domain.url, 'https://emby.example.com');
    expect(entries.single.isCustom, isFalse);
  });

  test('does not duplicate when current url is in custom entries', () {
    final entries = buildRouteEntries(
      currentUrl: 'https://a.example.com',
      customEntries: [DomainInfo(name: 'A', url: 'https://a.example.com')],
      pluginDomains: const [],
    );

    expect(entries, hasLength(1));
    expect(entries.single.domain.name, 'A');
    expect(entries.single.domain.url, 'https://a.example.com');
    expect(entries.single.isCustom, isTrue);
  });

  test('does not duplicate when current url is in plugin domains', () {
    final entries = buildRouteEntries(
      currentUrl: 'https://p.example.com',
      customEntries: const [],
      pluginDomains: [DomainInfo(name: 'P', url: 'https://p.example.com')],
    );

    expect(entries, hasLength(1));
    expect(entries.single.domain.name, 'P');
    expect(entries.single.domain.url, 'https://p.example.com');
    expect(entries.single.isCustom, isFalse);
  });

  test('does not include current url when it is null', () {
    final entries = buildRouteEntries(
      currentUrl: null,
      customEntries: const [],
      pluginDomains: const [],
    );

    expect(entries, isEmpty);
  });
}
