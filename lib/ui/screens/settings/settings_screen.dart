import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/services/sync/sync_models.dart';
import '../../../core/services/sync/trakt_sync_service.dart';
import '../../../core/services/webdav_service.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/cache_service.dart';
import '../../../core/utils/danmaku_filter.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/api/danmaku/danmaku_source.dart';
import '../../../core/api/danmaku/danmaku_service.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/translation/subtitle_document.dart';
import '../../../core/services/translation/whisper/desktop_binary_manager.dart';
import '../../../core/services/translation/whisper/whisper_model.dart';
import '../../../core/services/translation/whisper/whisper_model_manager.dart';
import '../../../core/providers/update_providers.dart';
import '../../../core/services/update/app_update_service.dart';
import '../../widgets/common/app_update_gate.dart';
import '../../../plugins/ui/plugin_management_screen.dart';

part 'settings_backup_restore.dart';
part 'settings_danmaku.dart';
part 'settings_general.dart';
part 'settings_home.dart';
part 'settings_player.dart';
part 'settings_sync.dart';
part 'settings_translation.dart';

Map<String, dynamic> _buildBackupPayload(WidgetRef ref) {
  return {
    'version': '1.0.0',
    'timestamp': DateTime.now().toIso8601String(),
    'currentServerId': ref.read(currentServerProvider)?.id,
    'servers': ref.read(serverListProvider).map(serverConfigToJson).toList(),
    'settings': {
      'themeMode': ref.read(themeModeProvider).name,
      'locale': localeToPreferenceTag(ref.read(localeProvider)),
      'startupPage': ref.read(startupPageProvider).name,
      'playerCore': ref.read(playerCoreProvider),
      'playbackSpeed': ref.read(defaultPlaybackSpeedProvider),
      'skipForwardStep': ref.read(skipForwardStepProvider),
      'longPressSpeed': ref.read(longPressSpeedProvider),
      'hardwareDecoding': ref.read(hardwareDecodingProvider),
      'backgroundPlayback': ref.read(backgroundPlaybackProvider),
      'autoPlayNext': ref.read(autoPlayNextProvider),
      'watchedThreshold': ref.read(watchedThresholdProvider),
      'danmakuEnabled': ref.read(danmakuEnabledProvider),
      'danmakuOpacity': ref.read(danmakuOpacityProvider),
      'danmakuFontSize': ref.read(danmakuFontSizeProvider),
      'danmakuSpeed': ref.read(danmakuSpeedProvider),
      'danmakuDensity': ref.read(danmakuDensityProvider),
      'preferredSubtitleLanguage': ref.read(preferredSubtitleLanguageProvider),
      'preferredAudioLanguage': ref.read(preferredAudioLanguageProvider),
      'preferredVersion': ref.read(preferredVersionProvider),
      'rememberBrightness': ref.read(rememberBrightnessProvider),
      'subtitleFont': ref.read(subtitleFontProvider),
      'mpvDolbyVisionFix': ref.read(mpvDolbyVisionFixProvider),
      'externalMpvPath': ref.read(externalMpvPathProvider),
      'impellerEnabled': ref.read(impellerEnabledProvider),
      'exoLibass': ref.read(exoLibassProvider),
      'subtitleBackground': ref.read(subtitleBackgroundProvider),
      'hideDailyRecommendations': ref.read(hideDailyRecommendationsProvider),
      'useVideoBackground': ref.read(useVideoBackgroundProvider),
    },
  };
}

Future<void> _restoreBackupPayload(
    WidgetRef ref, Map<String, dynamic> payload) async {
  final preferredServerId = payload['currentServerId'] as String?;
  final serversJson = (payload['servers'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(serverConfigFromJson)
      .toList();
  final settings = (payload['settings'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};

  ref.read(serverListProvider.notifier).replaceServers(serversJson);
  if (serversJson.isNotEmpty) {
    await ref.read(currentServerProvider.notifier).loadFromSaved(
          serversJson,
          preferredServerId: preferredServerId,
        );
    ref.read(authStateProvider.notifier).state =
        serverHasUsableAuth(ref.read(currentServerProvider))
            ? AuthState.authenticated
            : AuthState.unauthenticated;
  } else {
    ref.read(currentServerProvider.notifier).clear();
    ref.read(authStateProvider.notifier).state = AuthState.unauthenticated;
  }

  ref.read(themeModeProvider.notifier).state =
      parseThemeMode(settings['themeMode'] as String?);
  ref.read(localeProvider.notifier).state =
      parseLocaleTag(settings['locale'] as String?);
  ref.read(startupPageProvider.notifier).state =
      parseStartupPage(settings['startupPage'] as String?);

  if (settings['playerCore'] is String) {
    ref.read(playerCoreProvider.notifier).state =
        normalizePlayerCore(settings['playerCore'] as String);
  }
  if (settings['playbackSpeed'] is num) {
    ref.read(defaultPlaybackSpeedProvider.notifier).state =
        (settings['playbackSpeed'] as num).toDouble();
  }
  if (settings['skipForwardStep'] is num) {
    ref.read(skipForwardStepProvider.notifier).state =
        (settings['skipForwardStep'] as num).toInt();
  }
  if (settings['longPressSpeed'] is num) {
    ref.read(longPressSpeedProvider.notifier).state =
        (settings['longPressSpeed'] as num).toDouble();
  }
  if (settings['hardwareDecoding'] is bool) {
    ref.read(hardwareDecodingProvider.notifier).state =
        settings['hardwareDecoding'] as bool;
  }
  if (settings['backgroundPlayback'] is bool) {
    ref.read(backgroundPlaybackProvider.notifier).state =
        settings['backgroundPlayback'] as bool;
  }
  if (settings['autoPlayNext'] is bool) {
    ref.read(autoPlayNextProvider.notifier).state =
        settings['autoPlayNext'] as bool;
  }
  if (settings['watchedThreshold'] is num) {
    ref.read(watchedThresholdProvider.notifier).state =
        (settings['watchedThreshold'] as num).toInt();
  }
  if (settings['danmakuEnabled'] is bool) {
    ref.read(danmakuEnabledProvider.notifier).state =
        settings['danmakuEnabled'] as bool;
  }
  if (settings['danmakuOpacity'] is num) {
    ref.read(danmakuOpacityProvider.notifier).state =
        (settings['danmakuOpacity'] as num).toDouble();
  }
  if (settings['danmakuFontSize'] is num) {
    ref.read(danmakuFontSizeProvider.notifier).state =
        (settings['danmakuFontSize'] as num).toDouble();
  }
  if (settings['danmakuSpeed'] is num) {
    ref.read(danmakuSpeedProvider.notifier).state =
        (settings['danmakuSpeed'] as num).toDouble();
  }
  if (settings['danmakuDensity'] is num) {
    ref.read(danmakuDensityProvider.notifier).state =
        (settings['danmakuDensity'] as num).toDouble();
  }
  if (settings['preferredSubtitleLanguage'] is String) {
    ref.read(preferredSubtitleLanguageProvider.notifier).state =
        settings['preferredSubtitleLanguage'] as String;
  }
  if (settings['preferredAudioLanguage'] is String) {
    ref.read(preferredAudioLanguageProvider.notifier).state =
        settings['preferredAudioLanguage'] as String;
  }
  if (settings['preferredVersion'] is String) {
    ref.read(preferredVersionProvider.notifier).state =
        settings['preferredVersion'] as String;
  }
  if (settings['rememberBrightness'] is bool) {
    ref.read(rememberBrightnessProvider.notifier).state =
        settings['rememberBrightness'] as bool;
  }
  if (settings['subtitleFont'] is String) {
    ref.read(subtitleFontProvider.notifier).state =
        settings['subtitleFont'] as String;
  }
  if (settings['mpvDolbyVisionFix'] is bool) {
    ref.read(mpvDolbyVisionFixProvider.notifier).state =
        settings['mpvDolbyVisionFix'] as bool;
  }
  if (settings['externalMpvPath'] is String) {
    ref.read(externalMpvPathProvider.notifier).state =
        settings['externalMpvPath'] as String;
  }
  if (settings['impellerEnabled'] is bool) {
    ref.read(impellerEnabledProvider.notifier).state =
        settings['impellerEnabled'] as bool;
  }
  if (settings['exoLibass'] is bool) {
    ref.read(exoLibassProvider.notifier).state = settings['exoLibass'] as bool;
  }
  if (settings['subtitleBackground'] is bool) {
    ref.read(subtitleBackgroundProvider.notifier).state =
        settings['subtitleBackground'] as bool;
  }
  if (settings['hideDailyRecommendations'] is bool) {
    ref.read(hideDailyRecommendationsProvider.notifier).state =
        settings['hideDailyRecommendations'] as bool;
  }
  if (settings['useVideoBackground'] is bool) {
    ref.read(useVideoBackgroundProvider.notifier).state =
        settings['useVideoBackground'] as bool;
  }
}
