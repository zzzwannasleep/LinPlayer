import '../../providers/server_providers.dart';
import '../source_http.dart';
import 'anirss_token.dart';
import 'models/about.dart';
import 'models/ani.dart';
import 'models/ani_config.dart';
import 'models/bgm_info.dart';
import 'models/play_item.dart';
import 'models/tmdb_group.dart';
import 'models/torrent_info.dart';

/// Ani-rss 类型化客户端：浏览/详情/订阅/下载/设置全部端点。
/// 复用 [AniRssAuth] 的 token 生命周期（与播放后端 `AniRssBackend` 共享）。
class AniRssApi {
  final ServerConfig server;
  AniRssApi(this.server);

  AniRssAuth get _auth => AniRssAuth.instance;

  // ---- 浏览 / 详情 ----

  /// 订阅列表 → 展平 weekList[].items 去重。
  Future<List<AniModel>> listAni() async {
    final resp = await _auth.authed(server, '/api/listAni');
    final data = _auth.unwrap(resp);
    final weekList = (data is Map ? data['weekList'] as List? : null) ?? const [];
    final out = <AniModel>[];
    final seen = <String>{};
    for (final w in weekList) {
      final items = (w is Map ? w['items'] as List? : null) ?? const [];
      for (final a in items) {
        final ani = AniModel.fromJson(a);
        final key = ani.id.isNotEmpty ? ani.id : ani.title;
        if (key.isEmpty || !seen.add(key)) continue;
        out.add(ani);
      }
    }
    return out;
  }

  /// 某番剧的剧集文件列表。
  Future<List<PlayItemModel>> playList(AniModel ani) async {
    final resp = await _auth.authed(server, '/api/playList', data: ani.toJson());
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => PlayItemModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// TMDB 剧集组（进阶用）。
  Future<List<TmdbGroupModel>> getThemoviedbGroup(AniModel ani) async {
    final resp =
        await _auth.authed(server, '/api/getThemoviedbGroup', data: ani.toJson());
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => TmdbGroupModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  // ---- 下载进度 ----

  Future<List<TorrentInfoModel>> torrentsInfos() async {
    final resp = await _auth.authed(server, '/api/torrentsInfos');
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => TorrentInfoModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  // ---- 订阅管理 ----

  /// BGM 搜索（添加订阅用）。
  Future<List<BgmInfoModel>> searchBgm(String name) async {
    final resp = await _auth.authed(server, '/api/searchBgm',
        queryParameters: {'name': name});
    final list = (_auth.unwrap(resp) as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => BgmInfoModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 由 BGM 条目 id 生成可添加的订阅 Ani。
  Future<AniModel> getAniBySubjectId(String id) async {
    final resp = await _auth.authed(server, '/api/getAniBySubjectId',
        queryParameters: {'id': id});
    return AniModel.fromJson(_auth.unwrap(resp));
  }

  Future<void> addAni(AniModel ani) =>
      _auth.authed(server, '/api/addAni', data: ani.toJson());

  Future<void> setAni(AniModel ani) =>
      _auth.authed(server, '/api/setAni', data: ani.toJson());

  Future<void> deleteAni(List<String> ids, {bool deleteFiles = false}) =>
      _auth.authed(server, '/api/deleteAni',
          data: ids, queryParameters: {'deleteFiles': deleteFiles});

  Future<void> refreshAni(String id) =>
      _auth.authed(server, '/api/refreshAni', data: {'id': id});

  Future<void> refreshAll() => _auth.authed(server, '/api/refreshAll');

  Future<void> updateTotalEpisodeNumber(List<String> ids,
          {bool force = false}) =>
      _auth.authed(server, '/api/updateTotalEpisodeNumber',
          data: ids, queryParameters: {'force': force});

  Future<void> batchEnable(List<String> ids, bool value) =>
      _auth.authed(server, '/api/batchEnable',
          data: ids, queryParameters: {'value': value});

  // ---- 设置 / 关于 ----

  Future<ConfigModel> config() async {
    final resp = await _auth.authed(server, '/api/config');
    return ConfigModel.fromJson(_auth.unwrap(resp));
  }

  Future<void> setConfig(ConfigModel config) =>
      _auth.authed(server, '/api/setConfig', data: config.toJson());

  Future<AboutModel> about() async {
    final resp = await _auth.authed(server, '/api/about');
    return AboutModel.fromJson(_auth.unwrap(resp));
  }

  // ---- 图片代理 ----

  /// 经 ani-rss 服务端代理/缓存取图（TMDB 相对路径等）。需 token → async。
  Future<String> proxyImageUrl(String imgUrl) async {
    final token = await _auth.ensureToken(server);
    return buildProxyImageUrl(server, imgUrl, token);
  }

  /// 同步构造 proxyImage URL（已有 token 时用，如详情 provider 预解析后）。
  static String buildProxyImageUrl(
      ServerConfig server, String imgUrl, String token) {
    final base = normalizeBaseUrl(server.activeLineUrl);
    return '$base/api/proxyImage'
        '?imgUrl=${Uri.encodeQueryComponent(imgUrl)}'
        '&${AniRssAuth.header}=${Uri.encodeQueryComponent(token)}';
  }
}
