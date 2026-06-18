import 'package:dio/dio.dart';

import '../network/proxy_http_client.dart';
import 'app_logger.dart';

/// 单个可跳过片段（片头/片尾），单位为秒。
/// 片尾若"直到结尾"（数据源给出空结束时间），[endSec] 取 [endOfMediaSec] 哨兵：
/// 区间检测视为持续到结尾，点按跳过时 seek 会被播放器钳到末尾（或走连播）。
class SkipSegment {
  const SkipSegment(this.startSec, this.endSec);

  final int startSec;
  final int endSec;

  /// "直到媒体结尾"的哨兵秒数（24h，远超任何片长，seek 时被钳到末尾）。
  static const int endOfMediaSec = 86400;

  int get durationSec => endSec - startSec;

  /// introdb.app `/segments` 的单个段对象（`{start_sec, end_sec, ...}`，秒）。
  static SkipSegment? fromIntroDbApp(dynamic json) {
    if (json is! Map) return null;
    final s = (json['start_sec'] as num?)?.round();
    final e = (json['end_sec'] as num?)?.round();
    if (s == null || e == null || s < 0 || e <= s) return null;
    return SkipSegment(s, e);
  }

  /// theintrodb.org `/v3/media` 的段数组里的首个元素（`{start_ms, end_ms, ...}`，毫秒）。
  /// `start_ms` 为空记 0；`end_ms` 为空表示"直到结尾"，记 [endOfMediaSec]。
  static SkipSegment? fromTheIntroDb(dynamic listJson) {
    if (listJson is! List || listJson.isEmpty) return null;
    final first = listJson.first;
    if (first is! Map) return null;
    final startMs = first['start_ms'] as num?;
    final endMs = first['end_ms'] as num?;
    final s = startMs == null ? 0 : (startMs / 1000).round();
    final e = endMs == null ? endOfMediaSec : (endMs / 1000).round();
    if (s < 0 || e <= s) return null;
    return SkipSegment(s, e);
  }
}

/// 一集的片头/片尾片段集合（recap 前情提要、preview 预告按需求不采用）。
class IntroSkipSegments {
  const IntroSkipSegments({this.intro, this.outro});

  final SkipSegment? intro;
  final SkipSegment? outro;

  bool get isEmpty => intro == null && outro == null;
}

/// 单个数据源的查询结果：[ok] 区分"已响应（可能无段）"与"请求失败"，
/// 失败不应污染缓存。
class _SourceResult {
  const _SourceResult(this.ok, {this.intro, this.outro});
  const _SourceResult.failed() : this(false);

  final bool ok;
  final SkipSegment? intro;
  final SkipSegment? outro;
}

/// 多源「片头/片尾」时间段查询：合并 TheIntroDB 与 introdb.app 两个公共众包库。
///
/// - 两者都是只读、免鉴权、免 key（fair-use 限流），均支持以剧集 IMDb id + 季 + 集查询。
/// - 合并策略：按 片头 / 片尾 各取第一个命中的源（互补提高覆盖率）；两段都拿到即提前结束。
/// - 都走 [applyProxyToDio]，兼容用户自定义代理。
/// - 命中（含"确实无段"）按 `imdb|s|e` 内存缓存；全部源请求失败则不缓存，留待重试。
class IntroSkipService {
  IntroSkipService({AppLogger? logger}) : _logger = logger ?? AppLogger() {
    _theIntroDb = _makeDio('https://api.theintrodb.org/v3');
    _introDbApp = _makeDio('https://api.introdb.app');
  }

  static const String _tag = 'IntroSkip';

  final AppLogger _logger;
  late final Dio _theIntroDb;
  late final Dio _introDbApp;

  final Map<String, IntroSkipSegments?> _cache = <String, IntroSkipSegments?>{};

  Dio _makeDio(String baseUrl) {
    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: const {'Accept': 'application/json'},
    ));
    applyProxyToDio(dio);
    return dio;
  }

  Future<IntroSkipSegments?> fetch({
    required String imdbId,
    required int season,
    required int episode,
  }) async {
    final key = '$imdbId|$season|$episode';
    if (_cache.containsKey(key)) return _cache[key];

    SkipSegment? intro;
    SkipSegment? outro;
    var anyResponded = false;

    // 源顺序：TheIntroDB（片尾覆盖好、含"直到结尾"语义）优先，introdb.app 兜底补缺。
    for (final source in <Future<_SourceResult> Function()>[
      () => _fetchTheIntroDb(imdbId, season, episode),
      () => _fetchIntroDbApp(imdbId, season, episode),
    ]) {
      if (intro != null && outro != null) break; // 两段都已命中
      final r = await source();
      if (!r.ok) continue;
      anyResponded = true;
      intro ??= r.intro;
      outro ??= r.outro;
    }

    if (!anyResponded) return null; // 全部失败：不缓存，留待重试

    final merged = (intro == null && outro == null)
        ? null
        : IntroSkipSegments(intro: intro, outro: outro);
    _cache[key] = merged;
    if (merged != null) {
      _logger.i(
          _tag,
          '片段命中 $imdbId s${season}e$episode: '
          'intro=${intro != null}, outro=${outro != null}');
    }
    return merged;
  }

  /// TheIntroDB：`GET /media?imdb_id=&season=&episode=`，段为数组、毫秒；片尾叫 credits。
  Future<_SourceResult> _fetchTheIntroDb(
      String imdbId, int season, int episode) async {
    try {
      final resp = await _theIntroDb.get<Map<String, dynamic>>(
        '/media',
        queryParameters: <String, dynamic>{
          'imdb_id': imdbId,
          'season': season,
          'episode': episode,
        },
      );
      final data = resp.data;
      if (data == null) return const _SourceResult(true);
      return _SourceResult(
        true,
        intro: SkipSegment.fromTheIntroDb(data['intro']),
        outro: SkipSegment.fromTheIntroDb(data['credits']),
      );
    } catch (e) {
      _logger.w(_tag, 'TheIntroDB 查询失败 $imdbId s${season}e$episode: $e');
      return const _SourceResult.failed();
    }
  }

  /// introdb.app：`GET /segments?imdb_id=&season=&episode=`，段为对象、秒；片尾叫 outro。
  Future<_SourceResult> _fetchIntroDbApp(
      String imdbId, int season, int episode) async {
    try {
      final resp = await _introDbApp.get<Map<String, dynamic>>(
        '/segments',
        queryParameters: <String, dynamic>{
          'imdb_id': imdbId,
          'season': season,
          'episode': episode,
        },
      );
      final data = resp.data;
      if (data == null) return const _SourceResult(true);
      return _SourceResult(
        true,
        intro: SkipSegment.fromIntroDbApp(data['intro']),
        outro: SkipSegment.fromIntroDbApp(data['outro']),
      );
    } catch (e) {
      _logger.w(_tag, 'introdb.app 查询失败 $imdbId s${season}e$episode: $e');
      return const _SourceResult.failed();
    }
  }
}
