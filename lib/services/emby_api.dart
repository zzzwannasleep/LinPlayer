import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

class DomainInfo {
  final String name;
  final String url;

  DomainInfo({required this.name, required this.url});

  factory DomainInfo.fromJson(Map<String, dynamic> json) {
    return DomainInfo(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }
}

class LibraryInfo {
  final String id;
  final String name;
  LibraryInfo({required this.id, required this.name});

  factory LibraryInfo.fromJson(Map<String, dynamic> json) =>
      LibraryInfo(id: json['Id'] as String? ?? '', name: json['Name'] as String? ?? '');
}

class AuthResult {
  final String token;
  final String baseUrlUsed;
  final String userId;
  AuthResult({required this.token, required this.baseUrlUsed, required this.userId});
}

class MediaItem {
  final String id;
  final String name;
  final String type;
  MediaItem({required this.id, required this.name, required this.type});

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        id: json['Id'] as String? ?? '',
        name: json['Name'] as String? ?? '',
        type: json['Type'] as String? ?? '',
      );
}

class EmbyApi {
  EmbyApi({
    required String hostOrUrl,
    required String preferredScheme,
    String? port,
  })  : _hostOrUrl = hostOrUrl.trim(),
        _preferredScheme = preferredScheme,
        _port = port?.trim();

  final String _hostOrUrl;
  final String _preferredScheme;
  final String? _port;

  // Simple device id generator to satisfy Emby header requirements
  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  Map<String, String> _authHeader() {
    final deviceId = _randomId();
    return {
      'Content-Type': 'application/json',
      'X-Emby-Authorization':
          'MediaBrowser Client="LinPlayer", Device="Flutter", DeviceId="$deviceId", Version="1.0.0"'
    };
  }

  List<String> _candidates() {
    // If user pasted full URL with scheme, just try it.
    final parsed = Uri.tryParse(_hostOrUrl);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      final port = parsed.hasPort ? ':${parsed.port}' : '';
      return ['${parsed.scheme}://${parsed.host}$port'];
    }

    String port = _port ?? '';
    if (port.isEmpty) {
      port = _preferredScheme == 'http' ? '80' : '443';
    }
    final preferred = '$_preferredScheme://$_hostOrUrl:$port';

    final fallbackScheme = _preferredScheme == 'http' ? 'https' : 'http';
    final fallbackPort = _port?.isNotEmpty == true
        ? _port!
        : (fallbackScheme == 'http' ? '80' : '443');
    final fallback = '$fallbackScheme://$_hostOrUrl:$fallbackPort';

    if (preferred == fallback) {
      return [preferred];
    }
    return [preferred, fallback];
  }

  Future<AuthResult> authenticate({
    required String username,
    required String password,
  }) async {
    final errors = <String>[];
    for (final base in _candidates()) {
      final url = Uri.parse('$base/emby/Users/AuthenticateByName');
      final body = jsonEncode({
        'Username': username,
        'Pw': password,
        'Password': password,
      });

      try {
        final resp = await http.post(url, headers: _authHeader(), body: body);
        if (resp.statusCode != 200) {
          errors.add('${url.origin}: HTTP ${resp.statusCode}');
          continue;
        }
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = map['AccessToken'] as String?;
        final userId = (map['User'] as Map<String, dynamic>?)?['Id'] as String? ?? '';
        if (token == null || token.isEmpty) {
          errors.add('${url.origin}: 未返回 token');
          continue;
        }
        return AuthResult(token: token, baseUrlUsed: base, userId: userId);
      } catch (e) {
        errors.add('${url.origin}: $e');
      }
    }
    throw Exception('登录失败：${errors.join(" | ")}');
  }

  Future<List<DomainInfo>> fetchDomains(
    String token,
    String baseUrl, {
    bool allowFailure = true,
  }) async {
    final url = Uri.parse('$baseUrl/emby/System/Ext/ServerDomains');
    try {
      final resp = await http.get(url, headers: {
        'X-Emby-Token': token,
        'Accept': 'application/json',
      });
      if (resp.statusCode != 200) {
        if (allowFailure) return [];
        throw Exception('拉取线路失败（${resp.statusCode}）');
      }
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (map['data'] as List<dynamic>? ?? [])
          .map((e) => DomainInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      return list;
    } catch (e) {
      if (allowFailure) return [];
      rethrow;
    }
  }

  Future<List<LibraryInfo>> fetchLibraries({
    required String token,
    required String baseUrl,
    required String userId,
  }) async {
    // Emby 官方推荐获取视图的接口：/Users/{userId}/Views
    final url = Uri.parse('$baseUrl/emby/Users/$userId/Views');
    final resp = await http.get(url, headers: {
      'X-Emby-Token': token,
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      throw Exception('拉取媒体库失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => LibraryInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    return items;
  }

  Future<List<MediaItem>> fetchItems({
    required String token,
    required String baseUrl,
    required String userId,
    required String parentId,
  }) async {
    final url = Uri.parse(
        '$baseUrl/emby/Users/$userId/Items?ParentId=$parentId&Recursive=true&Fields=Path');
    final resp = await http.get(url, headers: {
      'X-Emby-Token': token,
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      throw Exception('拉取媒体列表失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (map['Items'] as List<dynamic>? ?? [])
        .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return items;
  }
}
