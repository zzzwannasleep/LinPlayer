import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lin_player_server_api/services/emby_api.dart';
import 'package:lin_player_prefs/preferences.dart';
import 'package:lin_player_state/app_state.dart';
import 'package:lin_player_state/server_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Backup import persists settings and servers', () async {
    SharedPreferences.setMockInitialValues({});

    final appState = AppState();
    await appState.importBackupMap(_sampleBackup());

    expect(appState.themeMode, ThemeMode.dark);
    expect(appState.uiScaleFactor, closeTo(1.25, 0.0001));
    expect(appState.useDynamicColor, isFalse);
    expect(appState.uiTemplate, UiTemplate.washiWatercolor);
    expect(appState.preferHardwareDecode, isFalse);
    expect(appState.playerCore, PlayerCore.exo);
    expect(appState.preferredAudioLang, 'jpn');
    expect(appState.preferredSubtitleLang, 'off');
    expect(appState.preferredVideoVersion, VideoVersionPreference.preferHevc);
    expect(appState.appIconId, 'pink');
    expect(appState.serverListLayout, ServerListLayout.list);
    expect(appState.mpvCacheSizeMb, 900);
    expect(appState.unlimitedStreamCache, isTrue);
    expect(appState.enableBlurEffects, isFalse);
    expect(appState.showHomeLibraryQuickAccess, isFalse);
    expect(appState.showHomeRandomRecommendations, isFalse);
    expect(appState.autoUpdateEnabled, isTrue);
    expect(appState.externalMpvPath, 'C:\\\\mpv\\\\mpv.exe');
    expect(appState.serverIconLibraryUrls, const [
      'https://example.com/icons.json',
      'http://foo.bar/iconlib.json?token=1',
    ]);

    expect(appState.danmakuEnabled, isTrue);
    expect(appState.danmakuApiUrls.first, 'https://api.dandanplay.net');
    expect(appState.danmakuOpacity, closeTo(0.8, 0.0001));
    expect(appState.danmakuMaxLines, 12);
    expect(appState.danmakuMergeRelated, isFalse);
    expect(appState.danmakuShowHeatmap, isFalse);

    expect(appState.servers.length, 2);
    expect(appState.activeServerId, 'srv_1');
    expect(appState.activeServer?.name, 'Home');
    expect(appState.activeServer?.hiddenLibraries, {'lib_a'});
    expect(
      appState.activeServer?.customDomains,
      contains(
        isA<CustomDomain>()
            .having((d) => d.name, 'name', '线路1')
            .having((d) => d.url, 'url', 'https://a.example.com'),
      ),
    );

    final reloaded = AppState();
    await reloaded.loadFromStorage();

    expect(reloaded.themeMode, ThemeMode.dark);
    expect(reloaded.uiScaleFactor, closeTo(1.25, 0.0001));
    expect(reloaded.uiTemplate, UiTemplate.washiWatercolor);
    expect(reloaded.showHomeLibraryQuickAccess, isFalse);
    expect(reloaded.showHomeRandomRecommendations, isFalse);
    expect(reloaded.autoUpdateEnabled, isTrue);
    expect(reloaded.danmakuMergeRelated, isFalse);
    expect(reloaded.danmakuShowHeatmap, isFalse);
    expect(reloaded.servers.length, 2);
    expect(reloaded.activeServerId, 'srv_1');
    expect(reloaded.activeServer?.name, 'Home');
    expect(reloaded.serverIconLibraryUrls, const [
      'https://example.com/icons.json',
      'http://foo.bar/iconlib.json?token=1',
    ]);
  });

  test('Encrypted backup (token mode) roundtrip', () async {
    SharedPreferences.setMockInitialValues({});

    final appState = AppState();
    await appState.importBackupMap(_sampleBackup());

    final exported = await appState.exportEncryptedBackupJson(
      passphrase: 'pw-123456',
      mode: BackupServerSecretMode.token,
      pretty: false,
    );

    final restored = AppState();
    await restored.importBackupJson(exported, passphrase: 'pw-123456');

    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.uiScaleFactor, closeTo(1.25, 0.0001));
    expect(restored.useDynamicColor, isFalse);
    expect(restored.uiTemplate, UiTemplate.washiWatercolor);
    expect(restored.autoUpdateEnabled, isTrue);
    expect(restored.showHomeLibraryQuickAccess, isFalse);
    expect(restored.showHomeRandomRecommendations, isFalse);
    expect(restored.playerCore, PlayerCore.exo);
    expect(restored.servers.length, 2);
    expect(restored.activeServerId, 'srv_1');
    expect(restored.serverIconLibraryUrls, const [
      'https://example.com/icons.json',
      'http://foo.bar/iconlib.json?token=1',
    ]);
  });

  test('Encrypted backup (password mode) imports via authenticator', () async {
    SharedPreferences.setMockInitialValues({});

    final appState = AppState();
    await appState.importBackupMap(_sampleBackup());

    final exported = await appState.exportEncryptedBackupJson(
      passphrase: 'pw-123456',
      mode: BackupServerSecretMode.password,
      serverLogins: const {
        'srv_1': BackupServerLogin(username: 'demo', password: 'p1'),
        'srv_2': BackupServerLogin(username: 'demo2', password: 'p2'),
      },
      pretty: false,
    );

    final restored = AppState();
    await restored.importBackupJson(
      exported,
      passphrase: 'pw-123456',
      authenticator: ({
        required String baseUrl,
        required String username,
        required String password,
        required String deviceId,
      }) async {
        return AuthResult(
          token: 'token_$username',
          baseUrlUsed: baseUrl,
          userId: 'user_$username',
        );
      },
    );

    expect(restored.servers.length, 2);
    expect(restored.activeServerId, 'srv_1');
    expect(restored.autoUpdateEnabled, isTrue);
    expect(restored.servers.firstWhere((s) => s.id == 'srv_1').token,
        'token_demo');
    expect(restored.servers.firstWhere((s) => s.id == 'srv_2').token,
        'token_demo2');
    expect(restored.serverIconLibraryUrls, const [
      'https://example.com/icons.json',
      'http://foo.bar/iconlib.json?token=1',
    ]);
  });
}

Map<String, dynamic> _sampleBackup() {
  return {
    'type': 'lin_player_backup',
    'version': 1,
    'createdAt': '2026-01-17T00:00:00Z',
    'data': {
      'themeMode': 'dark',
      'uiScaleFactor': 1.25,
      'useDynamicColor': false,
      'themeTemplate': 'warm',
      'preferHardwareDecode': false,
      'playerCore': 'exo',
      'preferredAudioLang': 'jpn',
      'preferredSubtitleLang': 'off',
      'preferredVideoVersion': 'preferHevc',
      'appIconId': 'pink',
      'serverListLayout': 'list',
      'mpvCacheSizeMb': 900,
      'unlimitedCoverCache': true,
      'enableBlurEffects': false,
      'showHomeLibraryQuickAccess': false,
      'showHomeRandomRecommendations': false,
      'autoUpdateEnabled': true,
      'externalMpvPath': 'C:\\\\mpv\\\\mpv.exe',
      'serverIconLibraryUrls': const [
        'https://example.com/icons.json#v1',
        'example.com/icons.json',
        'http://foo.bar/iconlib.json?token=1#abc',
      ],
      'danmaku': {
        'enabled': true,
        'loadMode': 'online',
        'apiUrls': const ['https://api.dandanplay.net/'],
        'appId': 'app',
        'appSecret': 'secret',
        'opacity': 0.8,
        'scale': 1.1,
        'speed': 1.2,
        'bold': true,
        'maxLines': 12,
        'topMaxLines': 1,
        'bottomMaxLines': 2,
        'rememberSelectedSource': true,
        'lastSelectedSourceName': 'dandan',
        'mergeDuplicates': true,
        'mergeRelated': false,
        'showHeatmap': false,
        'preventOverlap': false,
        'blockWords': 'foo\\nbar',
        'matchMode': 'fileNameOnly',
        'chConvert': 'toSimplified',
      },
      'activeServerId': 'srv_1',
      'servers': [
        {
          'id': 'srv_1',
          'name': 'Home',
          'baseUrl': 'https://emby.example.com',
          'token': 'token_1',
          'userId': 'user_1',
          'hiddenLibraries': const ['lib_a'],
          'domainRemarks': const {'https://a.example.com': 'A'},
          'customDomains': const [
            {'name': '线路1', 'url': 'https://a.example.com'},
          ],
        },
        {
          'id': 'srv_2',
          'name': 'Office',
          'baseUrl': 'https://emby2.example.com',
          'token': 'token_2',
          'userId': 'user_2',
          'hiddenLibraries': const [],
          'domainRemarks': const {},
          'customDomains': const [],
        },
      ],
    },
  };
}
