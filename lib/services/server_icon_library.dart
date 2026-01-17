import 'dart:convert';

import 'package:flutter/services.dart';

class ServerIconLibrary {
  const ServerIconLibrary({
    required this.name,
    required this.description,
    required this.icons,
  });

  final String name;
  final String description;
  final List<ServerIconEntry> icons;

  static const String defaultAssetPath = 'assets/server_icons.json';

  static Future<ServerIconLibrary>? _cachedDefault;

  static Future<ServerIconLibrary> loadDefault() {
    return _cachedDefault ??= _loadFromAsset(defaultAssetPath);
  }

  static Future<ServerIconLibrary> _loadFromAsset(String path) async {
    final raw = await rootBundle.loadString(path);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Invalid icon library json: not an object');
    }
    return ServerIconLibrary.fromJson(decoded.map(
      (k, v) => MapEntry(k.toString(), v),
    ));
  }

  factory ServerIconLibrary.fromJson(Map<String, dynamic> json) {
    final icons = (json['icons'] as List?)
            ?.whereType<Map>()
            .map((e) => ServerIconEntry.fromJson(
                  e.map((k, v) => MapEntry(k.toString(), v)),
                ))
            .where((e) => e.name.trim().isNotEmpty && e.url.trim().isNotEmpty)
            .toList() ??
        const <ServerIconEntry>[];

    return ServerIconLibrary(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      icons: icons,
    );
  }
}

class ServerIconEntry {
  const ServerIconEntry({required this.name, required this.url});

  final String name;
  final String url;

  factory ServerIconEntry.fromJson(Map<String, dynamic> json) =>
      ServerIconEntry(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
}
