import 'package:flutter/foundation.dart';

import '../state/app_state.dart';
import '../state/emos_session.dart';
import '../state/media_server_type.dart';
import 'emby_api.dart';
import 'emos_api.dart';
import 'emos_auth_flow.dart';

class EmosSignInService {
  static Future<void> signInAndBootstrap({
    required AppState appState,
    required String baseUrl,
    required String appName,
  }) async {
    final fixedBaseUrl = baseUrl.trim();
    if (fixedBaseUrl.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Base URL is empty');
    }

    if (kIsWeb) {
      throw UnsupportedError('Emos sign-in is not supported on web');
    }

    final auth = await EmosAuthFlow.signIn(
      baseUrl: fixedBaseUrl,
      appName: appName,
    );

    await appState.setEmosSession(
      EmosSession(
        token: auth.token,
        userId: auth.userId,
        username: auth.username,
        avatarUrl: auth.avatar,
      ),
    );

    final api = EmosApi(baseUrl: fixedBaseUrl, token: auth.token);
    final user = await api.fetchUser();

    final emyaUrl = user.emyaUrl.trim();
    if (emyaUrl.isEmpty) throw StateError('Missing emya_url');

    var emyaPassword = user.emyaPassword.trim();
    if (emyaPassword.isEmpty) {
      final oneTime = await api.fetchEmyaLoginPassword();
      emyaPassword = oneTime.password.trim();
    }
    if (emyaPassword.isEmpty) throw StateError('Missing emya password');

    final emyaScheme =
        Uri.tryParse(emyaUrl)?.scheme.trim().toLowerCase() ?? 'https';
    final usernameCandidates = <String>{user.username.trim(), user.userId.trim()}
      ..removeWhere((e) => e.isEmpty);

    String chosenUsername = usernameCandidates.isNotEmpty
        ? usernameCandidates.first
        : user.username.trim();
    for (final candidate in usernameCandidates) {
      try {
        final probe = EmbyApi(
          hostOrUrl: emyaUrl,
          preferredScheme: emyaScheme,
          serverType: MediaServerType.emby,
          deviceId: appState.deviceId,
        );
        await probe.authenticate(
          username: candidate,
          password: emyaPassword,
          deviceId: appState.deviceId,
          serverType: MediaServerType.emby,
        );
        chosenUsername = candidate;
        break;
      } catch (_) {
        // try next
      }
    }

    await appState.addServer(
      hostOrUrl: emyaUrl,
      scheme: emyaScheme == 'http' ? 'http' : 'https',
      serverType: MediaServerType.emby,
      username: chosenUsername,
      password: emyaPassword,
      displayName: 'Emos Emya',
      activate: true,
    );
  }
}

