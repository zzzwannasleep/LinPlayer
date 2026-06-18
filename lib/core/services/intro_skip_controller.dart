import 'package:flutter/foundation.dart';

import '../api/api_interfaces.dart';
import 'intro_skip_service.dart';

enum SkipKind { intro, outro }

/// 当前应显示的「跳过」提示：种类、按钮文案、点按后要 seek 到的目标位置。
class SkipPrompt {
  const SkipPrompt(this.kind, this.label, this.target);

  final SkipKind kind;
  final String label;
  final Duration target;
}

/// 平台无关的「自动跳过片头/片尾」控制器。
///
/// 三端共用：各屏只负责
/// 1) 拿到 item 后调 [loadForItem]（连播切集后再调一次）；
/// 2) 在已有的播放 tick 里调 [onPosition]；
/// 3) 监听 [prompt] 画左下角按钮、并在点按时按 [SkipPrompt] 自行 seek / 连播。
///
/// 控制器只产出「现在该显示什么按钮」，不触碰具体播放器/连播逻辑（各端不同）。
class IntroSkipController {
  IntroSkipController({required this.service});

  final IntroSkipService service;

  /// 当前提示（null = 不显示按钮）。
  final ValueNotifier<SkipPrompt?> prompt = ValueNotifier<SkipPrompt?>(null);

  // 过短的段忽略，避免无意义按钮。
  static const int _minSegmentSec = 2;

  IntroSkipSegments? _segments;
  String? _loadKey; // 防止加载竞态：异步期间切集则丢弃旧结果
  final Map<String, String?> _seriesImdbCache = <String, String?>{}; // seriesId->imdb

  /// 为当前播放项加载片段。[enabled] 来自设置开关；非剧集或无季集信息直接清空。
  /// [fetchItem] 用于按 id 取剧集详情拿系列 IMDb（解耦具体 API 类型）。
  Future<void> loadForItem(
    MediaItem item, {
    required bool enabled,
    required Future<MediaItem?> Function(String itemId) fetchItem,
  }) async {
    _segments = null;
    prompt.value = null;
    _loadKey = null;

    if (!enabled) return;
    if (item.type != 'Episode' || item.seriesId == null) return;
    final season = item.parentIndexNumber;
    final episode = item.indexNumber;
    if (season == null || episode == null) return;

    final loadKey = '${item.seriesId}|$season|$episode';
    _loadKey = loadKey;

    // 系列 IMDb（introdb 以剧集级 imdb 为键），按 seriesId 缓存跨集复用。
    String? imdb;
    if (_seriesImdbCache.containsKey(item.seriesId)) {
      imdb = _seriesImdbCache[item.seriesId];
    } else {
      try {
        final series = await fetchItem(item.seriesId!);
        imdb = series?.imdbId;
      } catch (_) {
        imdb = null;
      }
      _seriesImdbCache[item.seriesId!] = imdb;
    }
    if (imdb == null || imdb.isEmpty) return;
    if (_loadKey != loadKey) return; // 期间已切集

    final seg =
        await service.fetch(imdbId: imdb, season: season, episode: episode);
    if (_loadKey != loadKey) return;
    _segments = seg;
  }

  /// 在播放 tick 中喂入当前位置；据此更新 [prompt]（仅在种类变化时赋值）。
  void onPosition(Duration pos) {
    final seg = _segments;
    SkipPrompt? next;
    if (seg != null) {
      final s = pos.inSeconds;
      final intro = seg.intro;
      final outro = seg.outro;
      if (intro != null &&
          intro.durationSec >= _minSegmentSec &&
          s >= intro.startSec &&
          s < intro.endSec) {
        next = SkipPrompt(
            SkipKind.intro, '跳过片头', Duration(seconds: intro.endSec));
      } else if (outro != null &&
          outro.durationSec >= _minSegmentSec &&
          s >= outro.startSec &&
          s < outro.endSec) {
        next = SkipPrompt(
            SkipKind.outro, '跳过片尾', Duration(seconds: outro.endSec));
      }
    }
    if (prompt.value?.kind != next?.kind) {
      prompt.value = next;
    }
  }

  void clear() {
    _segments = null;
    _loadKey = null;
    prompt.value = null;
  }

  void dispose() {
    prompt.dispose();
  }
}
