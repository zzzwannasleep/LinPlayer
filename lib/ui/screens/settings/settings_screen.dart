import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/font_service.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/services/sync/sync_models.dart';
import '../../../core/services/sync/trakt_sync_service.dart';
import '../../../core/services/webdav_service.dart';
import '../../../core/services/backup_crypto.dart';
import '../../../core/services/common_config.dart';
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
import '../../../core/providers/proxy_providers.dart';
import '../../../core/network/proxy_settings.dart';
import '../../../core/network/proxy_http_client.dart';
import '../../../core/services/update/app_update_service.dart';
import '../../../core/services/watch_history/watch_history_writeback_service.dart';
import '../../widgets/common/app_update_gate.dart';
import '../../../plugins/ui/plugin_management_screen.dart';
import 'wallpaper_crop_screen.dart';

part 'settings_backup_restore.dart';
part 'settings_danmaku.dart';
part 'settings_general.dart';
part 'settings_home.dart';
part 'settings_interaction.dart';
part 'settings_network.dart';
part 'settings_player.dart';
part 'settings_resume_sync.dart';
part 'settings_sync.dart';
part 'settings_translation.dart';

/// 导入自定义字体（ttf/otf/ttc）。[isApp] 区分 App 全局字体 / 弹幕字体。
/// 加载成功后写入对应路径 Provider（持久化 + 触发主题/弹幕重建）。
Future<void> _importCustomFont(
  BuildContext context,
  WidgetRef ref, {
  required bool isApp,
}) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: isApp ? '选择 App 字体文件' : '选择弹幕字体文件',
    allowMultiple: false,
    type: FileType.custom,
    allowedExtensions: const ['ttf', 'otf', 'ttc'],
  );
  final path = result?.files.single.path;
  if (path == null || path.isEmpty) return;

  // setApp/DanmakuFont 会把字体复制进应用持久目录并返回稳定路径；必须用这个
  // 返回值更新 Provider，否则会用 FilePicker 的临时缓存路径覆盖已持久化路径，
  // 重启后文件被清理 → 字体「失效」。
  final savedPath = isApp
      ? await FontService.setAppFont(path)
      : await FontService.setDanmakuFont(path);
  if (!context.mounted) return;
  if (savedPath != null) {
    if (isApp) {
      ref.read(customAppFontPathProvider.notifier).state = savedPath;
    } else {
      ref.read(customDanmakuFontPathProvider.notifier).state = savedPath;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('字体已应用：${p.basename(savedPath)}')),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('字体加载失败，请确认文件为有效的 ttf/otf 字体')),
    );
  }
}

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
      'preloadEnabled': ref.read(preloadEnabledProvider),
      'strmDirectPlay': ref.read(strmDirectPlayProvider),
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
      'dolbyAutoGpuNextSw': ref.read(dolbyAutoGpuNextSwProvider),
      'externalMpvPath': ref.read(externalMpvPathProvider),
      'exoLibass': ref.read(exoLibassProvider),
      'pgsBlendMode': ref.read(pgsBlendModeProvider),
      'subtitleBackground': ref.read(subtitleBackgroundProvider),
      'hideDailyRecommendations': ref.read(hideDailyRecommendationsProvider),
      'useVideoBackground': ref.read(useVideoBackgroundProvider),
      'customAppFontPath': ref.read(customAppFontPathProvider),
      'customDanmakuFontPath': ref.read(customDanmakuFontPathProvider),
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
  if (settings['preloadEnabled'] is bool) {
    ref.read(preloadEnabledProvider.notifier).state =
        settings['preloadEnabled'] as bool;
  }
  if (settings['strmDirectPlay'] is bool) {
    ref.read(strmDirectPlayProvider.notifier).state =
        settings['strmDirectPlay'] as bool;
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
  if (settings['dolbyAutoGpuNextSw'] is bool) {
    ref.read(dolbyAutoGpuNextSwProvider.notifier).state =
        settings['dolbyAutoGpuNextSw'] as bool;
  }
  if (settings['externalMpvPath'] is String) {
    ref.read(externalMpvPathProvider.notifier).state =
        settings['externalMpvPath'] as String;
  }
  if (settings['exoLibass'] is bool) {
    ref.read(exoLibassProvider.notifier).state = settings['exoLibass'] as bool;
  }
  if (settings['pgsBlendMode'] is String) {
    ref.read(pgsBlendModeProvider.notifier).state =
        settings['pgsBlendMode'] as String;
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
  // 字体路径：还原后下次启动由 FontService 按路径加载。
  if (settings['customAppFontPath'] is String) {
    ref.read(customAppFontPathProvider.notifier).state =
        settings['customAppFontPath'] as String;
  }
  if (settings['customDanmakuFontPath'] is String) {
    ref.read(customDanmakuFontPathProvider.notifier).state =
        settings['customDanmakuFontPath'] as String;
  }
}
