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
    final url =
        api.playback.getSubtitleStreamUrl(itemId, mediaSourceId, stream.index, 'srt');
    final sourceLang = (stream.language == null || stream.language!.isEmpty)
        ? 'auto'
        : stream.language!;
    return service.translateSubtitleUrl(
      url: url,
      engine: engine,
      sourceLang: sourceLang,
      targetLang: targetLang,
      layout: layout,
      authToken: authToken,
      cacheKeySeed: '$itemId:${stream.index}',
      onProgress: onProgress,
    );
  }
}
