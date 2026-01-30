import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

class EmosAuthResult {
  const EmosAuthResult({
    required this.token,
    required this.userId,
    required this.username,
    required this.avatar,
  });

  final String token;
  final String userId;
  final String username;
  final String? avatar;
}

class EmosAuthFlow {
  static Future<EmosAuthResult> signIn({
    required String baseUrl,
    required String appName,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Emos sign-in is not supported on Web yet.');
    }

    final base = Uri.parse(baseUrl.trim().replaceAll(RegExp(r'/+$'), ''));
    if (base.scheme != 'http' && base.scheme != 'https') {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Invalid http/https url');
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final callbackUri = Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      path: '/emos_callback',
    );

    final uuid = _randomUuidV4();
    final loginUri = base.resolve('link').replace(
      queryParameters: {
        'uuid': uuid,
        'name': appName,
        'url': callbackUri.toString(),
      },
    );

    final completer = Completer<EmosAuthResult>();
    StreamSubscription<HttpRequest>? sub;
    sub = server.listen((req) async {
      try {
        final params = req.uri.queryParameters;
        final token = (params['token'] ?? '').trim();
        final userId = (params['user_id'] ?? '').trim();
        final username = (params['username'] ?? '').trim();
        final avatar = (params['avatar'] ?? '').trim();

        if (token.isEmpty || userId.isEmpty) {
          req.response
            ..statusCode = 400
            ..headers.contentType = ContentType.html
            ..write(_html('Missing token/user_id, please retry.'));
          await req.response.close();
          return;
        }

        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(_html('Login success. You can return to the app.'));
        await req.response.close();

        if (!completer.isCompleted) {
          completer.complete(
            EmosAuthResult(
              token: token,
              userId: userId,
              username: username,
              avatar: avatar.isEmpty ? null : avatar,
            ),
          );
        }
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      } finally {
        await sub?.cancel();
        await server.close(force: true);
      }
    });

    final ok = await launchUrl(
      loginUri,
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      await sub.cancel();
      await server.close(force: true);
      throw StateError('Failed to open login url.');
    }

    return completer.future.timeout(timeout, onTimeout: () async {
      await sub?.cancel();
      await server.close(force: true);
      throw TimeoutException('Login timed out.');
    });
  }

  static String _html(String message) {
    final safe = message
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    return '<!doctype html><html><head><meta charset="utf-8"></head>'
        '<body style="font-family:system-ui;padding:20px;">'
        '<h3>$safe</h3>'
        '<p>You may close this page now.</p>'
        '</body></html>';
  }

  static String _randomUuidV4() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant
    String hex(int v) => v.toRadixString(16).padLeft(2, '0');
    final b = bytes.map(hex).join();
    return '${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-'
        '${b.substring(16, 20)}-${b.substring(20)}';
  }
}

