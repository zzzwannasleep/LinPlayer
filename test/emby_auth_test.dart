import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:lin_player/services/emby_api.dart';

void main() {
  test('authenticate prefers root base when user input ends with /emby', () async {
    final requested = <String>[];
    final client = MockClient((req) async {
      requested.add(req.url.toString());
      if (req.url.toString() ==
          'https://example.com/emby/Users/AuthenticateByName') {
        return http.Response(
          jsonEncode({
            'AccessToken': 't1',
            'User': {'Id': 'u1'},
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('no', 405);
    });

    final api = EmbyApi(
      hostOrUrl: 'https://example.com/emby',
      preferredScheme: 'https',
      client: client,
    );

    final auth = await api.authenticate(
      username: 'demo',
      password: 'pw',
      deviceId: 'device-1',
    );

    expect(auth.baseUrlUsed, 'https://example.com');
    expect(auth.token, 't1');
    expect(auth.userId, 'u1');
    expect(requested, ['https://example.com/emby/Users/AuthenticateByName']);
  });

  test('authenticate falls back to base with /emby when server requires double prefix',
      () async {
    final requested = <String>[];
    final client = MockClient((req) async {
      requested.add(req.url.toString());
      if (req.url.toString() ==
          'https://example.com/emby/emby/Users/AuthenticateByName') {
        return http.Response(
          jsonEncode({
            'AccessToken': 't2',
            'User': {'Id': 'u2'},
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('method not allowed', 405);
    });

    final api = EmbyApi(
      hostOrUrl: 'https://example.com',
      preferredScheme: 'https',
      client: client,
    );

    final auth = await api.authenticate(
      username: 'demo',
      password: 'pw',
      deviceId: 'device-1',
    );

    expect(auth.baseUrlUsed, 'https://example.com/emby');
    expect(auth.token, 't2');
    expect(auth.userId, 'u2');
    expect(
      requested.take(2).toList(),
      [
        'https://example.com/emby/Users/AuthenticateByName',
        'https://example.com/emby/emby/Users/AuthenticateByName',
      ],
    );
  });

  test('authenticate strips /web/index.html from pasted url', () async {
    final requested = <String>[];
    final client = MockClient((req) async {
      requested.add(req.url.toString());
      if (req.url.toString() ==
          'https://example.com/emby/Users/AuthenticateByName') {
        return http.Response(
          jsonEncode({
            'AccessToken': 't3',
            'User': {'Id': 'u3'},
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('no', 404);
    });

    final api = EmbyApi(
      hostOrUrl: 'https://example.com/web/index.html',
      preferredScheme: 'https',
      client: client,
    );

    final auth = await api.authenticate(
      username: 'demo',
      password: 'pw',
      deviceId: 'device-1',
    );

    expect(auth.baseUrlUsed, 'https://example.com');
    expect(requested, ['https://example.com/emby/Users/AuthenticateByName']);
  });
}

