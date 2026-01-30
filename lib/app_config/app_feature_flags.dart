import 'package:flutter/foundation.dart';

import '../state/media_server_type.dart';
import 'app_product.dart';

@immutable
class AppFeatureFlags {
  const AppFeatureFlags({
    required this.allowedServerTypes,
  });

  final Set<MediaServerType> allowedServerTypes;

  bool isServerTypeAllowed(MediaServerType type) =>
      allowedServerTypes.contains(type);

  @override
  bool operator ==(Object other) {
    return other is AppFeatureFlags &&
        setEquals(other.allowedServerTypes, allowedServerTypes);
  }

  @override
  int get hashCode {
    final sorted = allowedServerTypes.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return Object.hashAll(sorted);
  }

  static AppFeatureFlags forProduct(AppProduct product) {
    switch (product) {
      case AppProduct.lin:
      case AppProduct.emos:
      case AppProduct.uhd:
        return const AppFeatureFlags(
          allowedServerTypes: {
            MediaServerType.emby,
            MediaServerType.jellyfin,
            MediaServerType.plex,
            MediaServerType.webdav,
          },
        );
    }
  }
}
