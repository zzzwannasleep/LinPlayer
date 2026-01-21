import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class PlexPin {
  final int id;
  final String code;
  final String? authToken;
  final String? qr;
  final DateTime? expiresAt;

  PlexPin({
    required this.id,
    required this.code,
    required this.authToken,
    required this.qr,
    required this.expiresAt,
  });

  factory PlexPin.fromJson(Map<String, dynamic> json) {
    final expiresRaw = (json['expiresAt'] ?? '').toString().trim();
    DateTime? expiresAt;
    if (expiresRaw.isNotEmpty) {
      expiresAt = DateTime.tryParse(expiresRaw);
    }
    return PlexPin(
      id: (json['id'] as num?)?.toInt() ?? 0,
      code: (json['code'] ?? '').toString(),
      authToken: (json['authToken'] as String?)?.trim(),
      qr: (json['qr'] as String?)?.trim(),
      expiresAt: expiresAt,
    );
  }
}

class PlexConnection {
  final String uri;
  final bool local;
  final bool relay;

  PlexConnection({
    required this.uri,
    required this.local,
    required this.relay,
  });

  factory PlexConnection.fromJson(Map<String, dynamic> json) {
    final uri = (json['uri'] ?? '').toString().trim();
    return PlexConnection(
      uri: uri,
      local: json['local'] == true,
      relay: json['relay'] == true,
    );
  }

  bool get isHttps => uri.toLowerCase().startsWith('https://');
}

class PlexResource {
  final String name;
  final String clientIdentifier;
  final String provides;
  final bool owned;
  final String? accessToken;
  final List<PlexConnection> connections;

  PlexResource({
    required this.name,
    required this.clientIdentifier,
    required this.provides,
    required this.owned,
    required this.accessToken,
    required this.connections,
  });

  factory PlexResource.fromJson(Map<String, dynamic> json) {
    final connections = (json['connections'] as List?)
            ?.whereType<Map>()
            .map((e) =>
                PlexConnection.fromJson(e.map((k, v) => MapEntry('$k', v))))
            .where((e) => e.uri.isNotEmpty)
            .toList() ??
        const <PlexConnection>[];
    return PlexResource(
      name: (json['name'] ?? json['product'] ?? '').toString().trim(),
      clientIdentifier: (json['clientIdentifier'] ?? '').toString().trim(),
      provides: (json['provides'] ?? '').toString().trim(),
      owned: json['owned'] == true,
      accessToken: (json['accessToken'] as String?)?.trim(),
      connections: connections,
    );
  }

  bool get isServer => provides.split(',').map((e) => e.trim()).contains('server');

  String? pickBestConnectionUri() {
    if (connections.isEmpty) return null;
    final ordered = [...connections];
    ordered.sort((a, b) {
      int score(PlexConnection c) {
        var s = 0;
        if (c.isHttps) s += 10;
        if (c.local) s += 5;
        if (!c.relay) s += 1;
        return -s;
      }

      return score(a).compareTo(score(b));
    });
    return ordered.first.uri;
  }
}

class PlexApi {
  PlexApi({
    required this.clientIdentifier,
    this.product = 'LinPlayer',
    this.device = 'Flutter',
    this.platform = 'Flutter',
    this.version = '1.0.0',
    http.Client? client,
  }) : _client = client ??
            IOClient(
              HttpClient()..badCertificateCallback = (_, __, ___) => true,
            );

  final String clientIdentifier;
  final String product;
  final String device;
  final String platform;
  final String version;
  final http.Client _client;

  Map<String, String> _headers({String? token}) => <String, String>{
        'Accept': 'application/json',
        'X-Plex-Client-Identifier': clientIdentifier,
        'X-Plex-Product': product,
        'X-Plex-Version': version,
        'X-Plex-Device': device,
        'X-Plex-Platform': platform,
        if (token != null && token.trim().isNotEmpty) 'X-Plex-Token': token.trim(),
      };

  Future<PlexPin> createPin({bool strong = true}) async {
    final resp = await _client.post(
      Uri.parse('https://plex.tv/api/v2/pins'),
      headers: <String, String>{
        ..._headers(),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: strong ? 'strong=true' : '',
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw Exception('Plex create pin failed (${resp.statusCode})');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PlexPin.fromJson(map);
  }

  Future<PlexPin> fetchPin(int id) async {
    final resp = await _client.get(
      Uri.parse('https://plex.tv/api/v2/pins/$id'),
      headers: _headers(),
    );
    if (resp.statusCode != 200) {
      throw Exception('Plex pin status failed (${resp.statusCode})');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PlexPin.fromJson(map);
  }

  String buildAuthUrl({required String code}) {
    final qs = Uri(
      queryParameters: <String, String>{
        'clientID': clientIdentifier,
        'code': code,
        'context[device][product]': product,
        'context[device][device]': device,
        'context[device][platform]': platform,
        'context[device][version]': version,
      },
    ).query;
    return 'https://app.plex.tv/auth#?$qs';
  }

  Future<List<PlexResource>> fetchResources({
    required String authToken,
    bool includeHttps = true,
    bool includeRelay = true,
  }) async {
    final uri = Uri.parse(
      'https://plex.tv/api/v2/resources'
      '?includeHttps=${includeHttps ? '1' : '0'}'
      '&includeRelay=${includeRelay ? '1' : '0'}',
    );
    final resp = await _client.get(
      uri,
      headers: _headers(token: authToken),
    );
    if (resp.statusCode != 200) {
      throw Exception('Plex resources failed (${resp.statusCode})');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => PlexResource.fromJson(e.map((k, v) => MapEntry('$k', v))))
        .toList(growable: false);
  }
}

