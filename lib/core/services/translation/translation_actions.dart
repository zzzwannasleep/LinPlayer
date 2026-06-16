import '../../api/api_interfaces.dart';
import 'subtitle_document.dart';
import 'subtitle_translation_service.dart';
import 'translation_engine.dart';

/// 三端共用的「翻译某条字幕轨」协调器。
///
/// 把「取字幕流 URL → 调用批量翻译服务 → 返回中文 SRT 路径」收敛成一处，
/// 各端只需用各自的 UI 展示进度并把结果交给 `loadLibassSubtitle`。
class TranslationActions {
  /// 翻译指定 Emby 字幕轨，返回生成的中文 SRT 文件路径。
  ///
  /// 以 srt 形式拉取源字幕以获得干净文本；缓存键含 itemId+streamIndex，
  /// 同一轨同一引擎不会重复翻译。
  static Future<String> translateEmbyStream({
    required ApiClientFactory api,
    required SubtitleTranslationService service,
    required TranslationEngine engine,
    required String itemId,
    required String mediaSourceId,
    required MediaStream stream,
    required String targetLang,
    required BilingualLayout layout,
    String? authToken,
    TranslationProgress? onProgress,
  }) {
    final urls = buildSubtitleUrlCandidates(
      api: api,
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      stream: stream,
    );
    final sourceLang = (stream.language == null || stream.language!.isEmpty)
        ? 'auto'
        : stream.language!;
    return service.translateSubtitleUrl(
      urls: urls,
      engine: engine,
      sourceLang: sourceLang,
      targetLang: targetLang,
      layout: layout,
      authToken: authToken,
      cacheKeySeed: '$itemId:${stream.index}',
      onProgress: onProgress,
    );
  }

  /// 构造内封/外挂字幕的候选下载地址（按命中概率排序）。
  ///
  /// 不同 Emby/Jellyfin 服务端的字幕导出路由不一：有的是
  /// `/Subtitles/{i}/Stream.srt`，有的需要 `/Subtitles/{i}/0/Stream.srt`
  /// （StartPositionTicks 段），还可能直接给 deliveryUrl/path。逐个尝试以兼容。
  static List<String> buildSubtitleUrlCandidates({
    required ApiClientFactory api,
    required String itemId,
    required String mediaSourceId,
    required MediaStream stream,
  }) {
    final candidates = <String>[];

    // 服务端直接给出的地址优先（仅取绝对地址）。
    final delivery = stream.deliveryUrl?.trim();
    if (delivery != null && delivery.startsWith('http')) {
      candidates.add(delivery);
    }
    final path = stream.path?.trim();
    if (path != null && path.startsWith('http')) {
      candidates.add(path);
    }

    // 各封装格式 × 是否带 StartPositionTicks 段；ticks 变体优先（覆盖面更广）。
    for (final codec in const ['srt', 'vtt', 'ass']) {
      final base =
          api.playback.getSubtitleStreamUrl(itemId, mediaSourceId, stream.index, codec);
      final ticks = base.replaceFirst('/Stream.$codec', '/0/Stream.$codec');
      candidates.add(ticks);
      candidates.add(base);
    }

    // 去重并保持顺序。
    final seen = <String>{};
    return candidates.where((u) => u.isNotEmpty && seen.add(u)).toList();
  }
}
