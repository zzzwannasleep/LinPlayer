import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../utils/platform_utils.dart';
import 'app_preferences.dart';

String get defaultPlayerCoreKey {
  if (isDesktopPlatform) return 'mpv';
  // Android 默认使用原生 MPV（通过 libplayer.so + 平台通道）
  return 'nativeMpv';
}

String normalizePlayerCore(String? value) {
  // 桌面端（Windows/Linux/macOS）只有 media_kit(mpv) 内核；
  // ExoPlayer / 原生 MPV 都是移动端（平台通道）专属，桌面无此实现。
  // 因此桌面统一归一到 mpv，避免历史/误存的值导致播放器初始化失败。
  if (isDesktopPlatform) return 'mpv';
  switch (value) {
    case 'mpv':
    case 'media_kit':
      return 'mpv';
    case 'exoPlayer':
    case 'video_player':
      return 'exoPlayer';
    case 'nativeMpv':
      return 'nativeMpv';
    default:
      return defaultPlayerCoreKey;
  }
}

final playerCoreProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: defaultPlayerCoreKey,
    readValue: (prefs) =>
        normalizePlayerCore(prefs.getString('linplayer_player_core')),
    writeValue: (prefs, value) async {
      await prefs.setString(
          'linplayer_player_core', normalizePlayerCore(value));
    },
  );
});

final defaultPlaybackSpeedProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 1.0,
    readValue: (prefs) => prefs.getDouble('linplayer_default_playback_speed'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_default_playback_speed', value);
    },
  );
});

final skipForwardStepProvider =
    StateNotifierProvider<PreferenceNotifier<int>, int>((ref) {
  return PreferenceNotifier<int>(
    defaultValue: 10,
    readValue: (prefs) => prefs.getInt('linplayer_skip_forward_step'),
    writeValue: (prefs, value) async {
      await prefs.setInt('linplayer_skip_forward_step', value);
    },
  );
});

final longPressSpeedProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 2.0,
    readValue: (prefs) => prefs.getDouble('linplayer_long_press_speed'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_long_press_speed', value);
    },
  );
});

/// 竖向滑动手势的动作取值：'brightness' 调亮度 / 'volume' 调音量 / 'none' 关闭。
const kGestureActionBrightness = 'brightness';
const kGestureActionVolume = 'volume';
const kGestureActionNone = 'none';

/// 左半屏竖向滑动的动作（默认亮度）。
final leftVerticalGestureProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: kGestureActionBrightness,
    readValue: (prefs) => prefs.getString('linplayer_gesture_left_vertical'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_gesture_left_vertical', value);
    },
  );
});

/// 右半屏竖向滑动的动作（默认音量）。
final rightVerticalGestureProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: kGestureActionVolume,
    readValue: (prefs) => prefs.getString('linplayer_gesture_right_vertical'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_gesture_right_vertical', value);
    },
  );
});

/// 是否启用横向滑动调节进度（默认开）。
final horizontalSeekGestureProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_gesture_horizontal_seek'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_gesture_horizontal_seek', value);
    },
  );
});

/// 是否启用双击屏幕两侧快进/快退（默认开）。
final doubleTapSeekGestureProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_gesture_double_tap_seek'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_gesture_double_tap_seek', value);
    },
  );
});

final hardwareDecodingProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_hardware_decoding'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_hardware_decoding', value);
    },
  );
});

final backgroundPlaybackProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_background_playback'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_background_playback', value);
    },
  );
});

final autoPlayNextProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_auto_play_next'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_auto_play_next', value);
    },
  );
});

/// 自动跳过片头/片尾（接入 introdb.app），默认开启，可关闭。
final autoSkipSegmentsProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_auto_skip_segments'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_auto_skip_segments', value);
    },
  );
});

/// 跨服务器续播：在一个服务器看过的进度，换到另一个服务器打开同一部影片 / 同一集时，
/// 自动续播到所有服务器中记录的最新进度（基于本地观看记录跨服匹配）。默认开启。
final crossServerResumeProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_cross_server_resume'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_cross_server_resume', value);
    },
  );
});

final watchedThresholdProvider =
    StateNotifierProvider<PreferenceNotifier<int>, int>((ref) {
  int normalize(int? value) {
    final threshold = value ?? 90;
    return threshold.clamp(75, 95);
  }

  return PreferenceNotifier<int>(
    defaultValue: 90,
    readValue: (prefs) =>
        normalize(prefs.getInt('linplayer_watched_threshold')),
    writeValue: (prefs, value) async {
      await prefs.setInt(
        'linplayer_watched_threshold',
        normalize(value),
      );
    },
  );
});

final danmakuEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_danmaku_enabled'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_danmaku_enabled', value);
    },
  );
});

final danmakuOpacityProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.8,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_opacity'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_opacity', value);
    },
  );
});

final danmakuFontSizeProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.5,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_font_size'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_font_size', value);
    },
  );
});

final danmakuSpeedProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.5,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_speed'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_speed', value);
    },
  );
});

final danmakuDensityProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.5,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_density'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_density', value);
    },
  );
});

/// 弹幕显示区域（占视频高度比例）：0.25=顶部 1/4，0.5=半屏，1.0=全屏。
final danmakuDisplayAreaProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 1.0,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_display_area'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_display_area', value);
    },
  );
});

/// 弹幕描边（黑边白/彩字），关闭则用半透明底框（旧观感）。
final danmakuStrokeProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_danmaku_stroke'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_danmaku_stroke', value);
    },
  );
});

final danmakuDelayProvider = StateProvider<double>((ref) => 0.0);
final danmakuDedupProvider = StateProvider<bool>((ref) => false);
final danmakuDedupWindowProvider = StateProvider<double>((ref) => 10.0);
final loadedDanmakuProvider = StateProvider<List<DanmakuItem>>((ref) => []);

final danmakuBlockwordsProvider =
    StateNotifierProvider<DanmakuBlockwordsNotifier, List<String>>((ref) {
  return DanmakuBlockwordsNotifier();
});

class DanmakuBlockwordsNotifier extends StateNotifier<List<String>> {
  DanmakuBlockwordsNotifier() : super([]);

  void addWord(String word) {
    if (word.isNotEmpty && !state.contains(word)) {
      state = [...state, word];
    }
  }

  void removeWord(String word) {
    state = state.where((entry) => entry != word).toList();
  }

  void importWords(List<String> words) {
    final newWords = words
        .where((word) => word.isNotEmpty && !state.contains(word))
        .toList();
    if (newWords.isNotEmpty) {
      state = [...state, ...newWords];
    }
  }

  void importUserBlocks(List<String> userIds) {
    final prefixedIds = userIds.map((id) => 'uid:$id').toList();
    importWords(prefixedIds);
  }

  void clear() {
    state = [];
  }
}

final preferredSubtitleLanguageProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: 'chi',
    readValue: (prefs) =>
        prefs.getString('linplayer_preferred_subtitle_language'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_subtitle_language', value);
    },
  );
});

final preferredAudioLanguageProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: 'jpn',
    readValue: (prefs) => prefs.getString('linplayer_preferred_audio_language'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_audio_language', value);
    },
  );
});

final preferredVersionProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '原盘',
    readValue: (prefs) => prefs.getString('linplayer_preferred_version'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_version', value);
    },
  );
});

/// 版本选择正则偏好：进入多版本片源时，优先选中匹配该正则的媒体源
/// （反查 名称/容器/分辨率/编码）。为空则不启用正则、保持默认（首个/详情页选择）。
final preferredVersionRegexProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_preferred_version_regex'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_version_regex', value);
    },
  );
});

/// 记忆每部剧选过的画质（seriesId → 分辨率档位标签，如 "1080p"/"4K"/"720p"）。
/// 用户在某剧任一分集选了某档画质后，再进入该剧其它分集会自动选回同档画质，
/// 不必每集重选。按分辨率档位匹配（而非具体 mediaSource.id），以跨分集复用。
final seriesQualityMemoryProvider =
    StateNotifierProvider<SeriesQualityMemoryNotifier, Map<String, String>>(
        (ref) {
  return SeriesQualityMemoryNotifier();
});

class SeriesQualityMemoryNotifier extends StateNotifier<Map<String, String>> {
  SeriesQualityMemoryNotifier() : super(_load());

  static const _prefKey = 'linplayer_series_quality_memory';

  static Map<String, String> _load() {
    try {
      final raw = AppPreferencesStore.instance.getString(_prefKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded
            .map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }

  /// 取出该剧记忆的画质档位；无记忆返回 null。
  String? recall(String? seriesId) {
    if (seriesId == null || seriesId.isEmpty) return null;
    final v = state[seriesId];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 记住该剧选用的画质档位。
  void remember(String? seriesId, String label) {
    if (seriesId == null || seriesId.isEmpty || label.isEmpty) return;
    if (state[seriesId] == label) return;
    state = {...state, seriesId: label};
    _persist();
  }

  void _persist() {
    try {
      AppPreferencesStore.instance.setString(_prefKey, jsonEncode(state));
    } catch (_) {
      // 持久化失败不影响内存记忆。
    }
  }
}

/// 字幕选择正则偏好：自动选轨时优先选中匹配该正则的字幕轨
/// （匹配 显示名/标题/语言/编码，如 `中文|简|繁|chi|zh`）。为空则回退到首选字幕语言。
final preferredSubtitleRegexProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_preferred_subtitle_regex'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_subtitle_regex', value);
    },
  );
});

/// 音频选择正则偏好：自动选轨时优先选中匹配该正则的音频轨
/// （匹配 显示名/标题/语言/编码/声道，如 `jpn|日|flac|7.1`）。为空则回退到首选音频语言。
final preferredAudioRegexProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_preferred_audio_regex'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_audio_regex', value);
    },
  );
});

/// 弹幕自定义字体文件路径（空 = 用系统默认字体）。
/// 实际字体由 FontService 在启动时按此路径加载，key 与 FontService.danmakuFontPathKey 一致。
final customDanmakuFontPathProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_custom_danmaku_font_path'),
    writeValue: (prefs, value) async {
      if (value.isEmpty) {
        await prefs.remove('linplayer_custom_danmaku_font_path');
      } else {
        await prefs.setString('linplayer_custom_danmaku_font_path', value);
      }
    },
  );
});

final rememberBrightnessProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_remember_brightness'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_remember_brightness', value);
    },
  );
});

final playerBrightnessProvider = StateProvider<double>((ref) => 1.0);

final subtitleFontProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '默认',
    readValue: (prefs) => prefs.getString('linplayer_subtitle_font'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_subtitle_font', value);
    },
  );
});

final mpvDolbyVisionFixProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_mpv_dolby_vision_fix'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_mpv_dolby_vision_fix', value);
    },
  );
});

final externalMpvPathProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_external_mpv_path'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_external_mpv_path', value);
    },
  );
});

final gpuNextEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_gpu_next_enabled'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_gpu_next_enabled', value);
    },
  );
});

final exoLibassProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_exo_libass'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_exo_libass', value);
    },
  );
});

final aspectRatioProvider = StateProvider<String>((ref) => '自适应');
final skipOpeningStartProvider = StateProvider<int>((ref) => 0);
final skipOpeningEndProvider = StateProvider<int>((ref) => 0);
final skipEndingStartProvider = StateProvider<int>((ref) => 0);
final skipEndingEndProvider = StateProvider<int>((ref) => 0);
final skipAutoModeProvider = StateProvider<bool>((ref) => false);
final sleepTimerRemainingProvider = StateProvider<Duration?>((ref) => null);
final subtitleDelayProvider = StateProvider<double>((ref) => 0.0);
final audioDelayProvider = StateProvider<double>((ref) => 0.0);
final subtitleSizeProvider = StateProvider<double>((ref) => 0.5);
final subtitlePositionProvider = StateProvider<double>((ref) => 0.0);

final subtitleBackgroundProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_subtitle_background'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_subtitle_background', value);
    },
  );
});

final anime4KLevelProvider = StateProvider<String>((ref) => 'off');

/// PGS/SUP 图形字幕混合渲染模式（mpv blend-subtitles）：'no'/'video'/'yes'。
/// 实验项，用于排查图形字幕在 UI 重绘时的闪现，默认 'no'（OSD 覆盖层=原行为）。
/// 键名与 [CacheService.getPgsBlendMode] 一致，桌面 libmpv 初始化时也会读取。
final pgsBlendModeProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: 'no',
    readValue: (prefs) {
      final v = prefs.getString('linplayer_pgs_blend_mode');
      return (v == 'yes' || v == 'video') ? v : 'no';
    },
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_pgs_blend_mode', value);
    },
  );
});
