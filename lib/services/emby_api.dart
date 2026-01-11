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

class EmbyApi {
  EmbyApi(String baseUrl) : _baseUrl = _normalizeBaseUrl(baseUrl);

  final String _baseUrl;

  static String _normalizeBaseUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url'; // 默认加 https
    }
    // 去掉末尾斜杠
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    return url;
  }

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

  Future<String> authenticate({
    required String username,
    required String password,
  }) async {
    final url = Uri.parse('$_baseUrl/emby/Users/AuthenticateByName');
    final body = jsonEncode({
      'Username': username,
      // Emby 允许明文密码字段 "Pw"；兼容某些服务端同时接受 "Password"
      'Pw': password,
      'Password': password,
    });

    final resp = await http.post(url, headers: _authHeader(), body: body);
    if (resp.statusCode != 200) {
      throw Exception('登录失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = map['AccessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw Exception('未返回 token');
    }
    return token;
  }

  Future<List<DomainInfo>> fetchDomains(String token) async {
    final url = Uri.parse('$_baseUrl/emby/System/Ext/ServerDomains');
    final resp = await http.get(url, headers: {
      'X-Emby-Token': token,
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      throw Exception('拉取线路失败（${resp.statusCode}）');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (map['data'] as List<dynamic>? ?? [])
        .map((e) => DomainInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    return list;
  }
}
