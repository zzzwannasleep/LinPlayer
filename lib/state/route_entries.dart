import '../services/emby_api.dart';

typedef RouteEntry = ({DomainInfo domain, bool isCustom});

List<RouteEntry> buildRouteEntries({
  required String? currentUrl,
  required List<DomainInfo> customEntries,
  required List<DomainInfo> pluginDomains,
}) {
  final hasCurrentInList = currentUrl != null &&
      (customEntries.any((d) => d.url == currentUrl) ||
          pluginDomains.any((d) => d.url == currentUrl));

  return <RouteEntry>[
    if (currentUrl != null && !hasCurrentInList)
      (domain: DomainInfo(name: '登录线路', url: currentUrl), isCustom: false),
    for (final d in customEntries) (domain: d, isCustom: true),
    for (final d in pluginDomains) (domain: d, isCustom: false),
  ];
}

