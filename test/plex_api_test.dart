import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:lin_player/services/plex_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PlexApi.buildAuthUrl includes expected parameters', () {
    final api = PlexApi(
      clientIdentifier: 'cid-123',
      product: 'LinPlayer',
      device: 'Flutter',
      platform: 'Flutter',
      version: '1.0.0',
      client: MockClient((_) async => http.Response('', 200)),
    );

    final url = api.buildAuthUrl(code: 'pin-code');
    final uri = Uri.parse(url);

    expect(uri.scheme, 'https');
    expect(uri.host, 'app.plex.tv');
    expect(uri.path, '/auth');
    expect(uri.fragment.startsWith('?'), isTrue);

    final params = Uri.splitQueryString(uri.fragment.substring(1));
    expect(params['clientID'], 'cid-123');
    expect(params['code'], 'pin-code');
    expect(params['context[device][product]'], 'LinPlayer');
    expect(params['context[device][device]'], 'Flutter');
    expect(params['context[device][platform]'], 'Flutter');
    expect(params['context[device][version]'], '1.0.0');
  });

  test('PlexApi.createPin posts strong=true and parses response', () async {
    final mock = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://plex.tv/api/v2/pins');
      expect(request.headers['Accept'], 'application/json');
      expect(request.headers['X-Plex-Client-Identifier'], 'cid-123');
      expect(
          request.headers['Content-Type'], 'application/x-www-form-urlencoded');
      expect(request.body, 'strong=true');

      return http.Response(
        jsonEncode({
          'id': 42,
          'code': 'ABCD',
          'authToken': null,
          'qr': null,
          'expiresAt': '2026-01-01T00:00:00Z',
        }),
        201,
      );
    });

    final api = PlexApi(clientIdentifier: 'cid-123', client: mock);
    final pin = await api.createPin();

    expect(pin.id, 42);
    expect(pin.code, 'ABCD');
    expect(pin.authToken, isNull);
    expect(pin.expiresAt, isNotNull);
  });

  test('PlexApi.fetchPin gets status and parses authToken', () async {
    final mock = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://plex.tv/api/v2/pins/42');
      expect(request.headers['Accept'], 'application/json');
      expect(request.headers['X-Plex-Client-Identifier'], 'cid-123');

      return http.Response(
        jsonEncode({
          'id': 42,
          'code': 'ABCD',
          'authToken': 'token-xyz',
          'qr': null,
          'expiresAt': '2026-01-01T00:00:00Z',
        }),
        200,
      );
    });

    final api = PlexApi(clientIdentifier: 'cid-123', client: mock);
    final pin = await api.fetchPin(42);

    expect(pin.authToken, 'token-xyz');
  });

  test('PlexApi.fetchResources includes token and returns servers', () async {
    final mock = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'plex.tv');
      expect(request.url.path, '/api/v2/resources');
      expect(request.url.queryParameters['includeHttps'], '1');
      expect(request.url.queryParameters['includeRelay'], '1');
      expect(request.headers['X-Plex-Token'], 'token-xyz');

      return http.Response(
        jsonEncode([
          {
            'name': 'Plex Server',
            'clientIdentifier': 'machine-id',
            'provides': 'server',
            'owned': true,
            'accessToken': 'server-token',
            'connections': [
              {'uri': 'http://10.0.0.2:32400', 'local': true, 'relay': false},
              {
                'uri': 'https://example.plex.direct:32400',
                'local': false,
                'relay': false
              },
              {
                'uri': 'https://10-0-0-2.plex.direct:32400',
                'local': true,
                'relay': false
              },
            ],
          },
        ]),
        200,
      );
    });

    final api = PlexApi(clientIdentifier: 'cid-123', client: mock);
    final resources = await api.fetchResources(authToken: 'token-xyz');

    expect(resources, hasLength(1));
    expect(resources.first.isServer, isTrue);
    expect(
      resources.first.pickBestConnectionUri(),
      'https://10-0-0-2.plex.direct:32400',
    );
  });
}
