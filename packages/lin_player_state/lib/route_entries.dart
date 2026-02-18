import 'package:lin_player_server_api/services/emby_api.dart';

typedef RouteEntry = ({DomainInfo domain, bool isCustom});

List<RouteEntry> buildRouteEntries({
  required String? currentUrl,
  required List<DomainInfo> customEntries,
  required List<DomainInfo> pluginDomains,
}) {
  final current = (currentUrl ?? '').trim();
  final hasCurrentInList = current.isNotEmpty &&
      (customEntries.any((d) => d.url == current) ||
          pluginDomains.any((d) => d.url == current));

  final seen = <String>{};
  final entries = <RouteEntry>[];

  void add(DomainInfo domain, {required bool isCustom}) {
    final url = domain.url.trim();
    if (url.isEmpty || seen.contains(url)) return;
    seen.add(url);
    entries.add((domain: domain, isCustom: isCustom));
  }

  if (current.isNotEmpty && !hasCurrentInList) {
    add(
      DomainInfo(name: '登录线路', url: current),
      isCustom: false,
    );
  }
  for (final d in customEntries) {
    add(d, isCustom: true);
  }
  for (final d in pluginDomains) {
    add(d, isCustom: false);
  }

  return entries;
}
