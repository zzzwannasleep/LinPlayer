import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'emby_api.dart';

class EmosUser {
  const EmosUser({
    required this.emyaUrl,
    required this.userId,
    required this.username,
    required this.emyaPassword,
    this.avatar,
  });

  final String emyaUrl;
  final String userId;
  final String username;
  final String emyaPassword;
  final String? avatar;

  factory EmosUser.fromJson(Map<String, dynamic> json) {
    return EmosUser(
      emyaUrl: (json['emya_url'] as String? ?? '').trim(),
      userId: (json['user_id'] as String? ?? '').trim(),
      username: (json['username'] as String? ?? '').trim(),
      emyaPassword: (json['emya_password'] as String? ?? '').trim(),
      avatar: (json['avatar'] as String?)?.trim(),
    );
  }
}

class EmosEmyaLoginPassword {
  const EmosEmyaLoginPassword({required this.password, required this.second});

  final String password;
  final int second;

  factory EmosEmyaLoginPassword.fromJson(Map<String, dynamic> json) {
    return EmosEmyaLoginPassword(
      password: json['password']?.toString().trim() ?? '',
      second: json['second'] as int? ?? 0,
    );
  }
}

class EmosApi {
  EmosApi({
    required this.baseUrl,
    required this.token,
    http.Client? client,
  }) : _client = client ??
            IOClient(
              HttpClient()
                ..userAgent = EmbyApi.userAgent
                ..badCertificateCallback = (_, __, ___) => true,
            );

  final String baseUrl;
  final String token;
  final http.Client _client;

  String get _baseUrlNormalized => baseUrl.replaceAll(RegExp(r'/+$'), '');

  Uri _uri(String path, [Map<String, String?>? query]) {
    final base = Uri.parse(_baseUrlNormalized);
    final joined = base.resolve(path.startsWith('/') ? path.substring(1) : path);
    if (query == null || query.isEmpty) return joined;
    return joined.replace(
      queryParameters: <String, String>{
        ...joined.queryParameters,
        ...query.map((k, v) => MapEntry(k, v ?? '')),
      },
    );
  }

  Map<String, String> _headers({bool json = true}) {
    return <String, String>{
      'User-Agent': EmbyApi.userAgent,
      'Accept': 'application/json',
      if (json) 'Content-Type': 'application/json',
      if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
    };
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final resp = await _client.get(uri, headers: _headers(json: false));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}', uri: uri);
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected JSON object');
    }
    return decoded;
  }

  Future<dynamic> _getAny(Uri uri) async {
    final resp = await _client.get(uri, headers: _headers(json: false));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}', uri: uri);
    }
    return jsonDecode(resp.body);
  }

  Future<dynamic> _postJson(Uri uri, Object body) async {
    final resp =
        await _client.post(uri, headers: _headers(), body: jsonEncode(body));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}', uri: uri);
    }
    if (resp.body.trim().isEmpty) return null;
    return jsonDecode(resp.body);
  }

  Future<dynamic> _patchJson(Uri uri, [Object? body]) async {
    final resp = await _client.patch(
      uri,
      headers: _headers(json: body != null),
      body: body == null ? null : jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}', uri: uri);
    }
    if (resp.body.trim().isEmpty) return null;
    return jsonDecode(resp.body);
  }

  Future<dynamic> _putJson(Uri uri, [Object? body]) async {
    final resp = await _client.put(
      uri,
      headers: _headers(json: body != null),
      body: body == null ? null : jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}', uri: uri);
    }
    if (resp.body.trim().isEmpty) return null;
    return jsonDecode(resp.body);
  }

  Future<dynamic> _delete(Uri uri) async {
    final resp = await _client.delete(uri, headers: _headers(json: false));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('HTTP ${resp.statusCode}', uri: uri);
    }
    if (resp.body.trim().isEmpty) return null;
    return jsonDecode(resp.body);
  }

  Future<bool> checkSign() async {
    final map = await _getJson(_uri('/api/sign/check'));
    return map['is_sign'] == true;
  }

  Future<EmosUser> fetchUser() async {
    final map = await _getJson(_uri('/api/user'));
    return EmosUser.fromJson(map);
  }

  Future<EmosEmyaLoginPassword> fetchEmyaLoginPassword() async {
    final map = await _getJson(_uri('/api/emya/getLoginPassword'));
    return EmosEmyaLoginPassword.fromJson(map);
  }

  Future<dynamic> resetEmyaPassword(String password) {
    return _putJson(
      _uri(
        '/api/emya/resetPassword',
        <String, String?>{'password': password.trim()},
      ),
    );
  }

  Future<dynamic> toggleShowEmptyLibraries() {
    return _putJson(_uri('/api/user/showEmpty'));
  }

  Future<dynamic> updatePseudonym(String name) {
    return _putJson(
      _uri('/api/user/pseudonym', <String, String?>{'name': name.trim()}),
    );
  }

  Future<dynamic> agreeUploadAgreement() {
    return _putJson(_uri('/api/user/agreeUploadAgreement'));
  }

  Future<dynamic> inviteUser({required String inviteUserId}) {
    return _postJson(
      _uri('/api/invite'),
      <String, Object?>{'invite_user_id': inviteUserId.trim()},
    );
  }

  Future<dynamic> fetchInviteInfo() => _getAny(_uri('/api/invite/info'));

  Future<dynamic> fetchInviteHistory({int page = 1, int pageSize = 15}) {
    return _getAny(
      _uri(
        '/api/invite/history',
        <String, String?>{
          'page': '$page',
          'page_size': '$pageSize',
        },
      ),
    );
  }

  Future<dynamic> fetchCarrotHistory({String? type, int page = 1, int pageSize = 15}) {
    return _getAny(
      _uri(
        '/api/carrot/history',
        <String, String?>{
          'type': (type ?? '').trim(),
          'page': '$page',
          'page_size': '$pageSize',
        },
      ),
    );
  }

  Future<dynamic> transferCarrot({required String userId, required int carrot}) {
    return _putJson(
      _uri('/api/carrot/transfer'),
      <String, Object?>{
        'user_id': userId.trim(),
        'carrot': carrot,
      },
    );
  }

  Future<dynamic> fetchCarrotRank() => _getAny(_uri('/api/rank/carrot'));
  Future<dynamic> fetchUploadRank() => _getAny(_uri('/api/rank/upload'));

  Future<dynamic> fetchProxyLines({bool onlySelf = false}) {
    return _getAny(
      _uri(
        '/api/proxy/line',
        <String, String?>{'only_self': onlySelf ? '1' : ''},
      ),
    );
  }

  Future<dynamic> createProxyLine({
    required String name,
    required String url,
    String? tagline,
  }) {
    return _postJson(
      _uri('/api/proxy/line'),
      <String, Object?>{
        'name': name.trim(),
        'url': url.trim(),
        'tagline': (tagline ?? '').trim(),
      },
    );
  }

  Future<dynamic> deleteProxyLine({required int id}) {
    return _delete(_uri('/api/proxy/line', <String, String?>{'id': '$id'}));
  }

  Future<dynamic> syncVideos({String? tmdbId, String? todbId}) {
    return _patchJson(
      _uri(
        '/api/video/sync',
        <String, String?>{
          'tmdb_id': (tmdbId ?? '').trim(),
          'todb_id': (todbId ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> fetchVideoTree({
    String? type,
    String? title,
    String? tmdbId,
    String? todbId,
    String? videoId,
  }) {
    return _getAny(
      _uri(
        '/api/video/tree',
        <String, String?>{
          'type': (type ?? '').trim(),
          'title': (title ?? '').trim(),
          'tmdb_id': (tmdbId ?? '').trim(),
          'todb_id': (todbId ?? '').trim(),
          'video_id': (videoId ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> getVideoId({
    required String videoIdType,
    required String videoIdValue,
    String? seasonNumber,
    String? episodeNumber,
  }) {
    return _getAny(
      _uri(
        '/api/video/getVideoId',
        <String, String?>{
          'video_id_type': videoIdType.trim(),
          'video_id_value': videoIdValue.trim(),
          'season_number': (seasonNumber ?? '').trim(),
          'episode_number': (episodeNumber ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> fetchVideoList({
    String? tmdbId,
    String? todbId,
    String? videoId,
    String? type,
    String? title,
    String? onlyDelete,
    String? withMedia,
    int page = 1,
    int pageSize = 15,
  }) {
    return _getAny(
      _uri(
        '/api/video/list',
        <String, String?>{
          'tmdb_id': (tmdbId ?? '').trim(),
          'todb_id': (todbId ?? '').trim(),
          'video_id': (videoId ?? '').trim(),
          'type': (type ?? '').trim(),
          'title': (title ?? '').trim(),
          'only_delete': (onlyDelete ?? '').trim(),
          'with_media': (withMedia ?? '').trim(),
          'page': '$page',
          'page_size': '$pageSize',
        },
      ),
    );
  }

  Future<dynamic> searchVideos({
    String? lastId,
    String? tmdbId,
    String? todbId,
    String? videoId,
    String? type,
    String? title,
    String? withGenre,
    String? sortBy,
    int page = 1,
    int pageSize = 15,
  }) {
    return _getAny(
      _uri(
        '/api/video/search',
        <String, String?>{
          'last_id': (lastId ?? '').trim(),
          'tmdb_id': (tmdbId ?? '').trim(),
          'todb_id': (todbId ?? '').trim(),
          'video_id': (videoId ?? '').trim(),
          'type': (type ?? '').trim(),
          'title': (title ?? '').trim(),
          'with_genre': (withGenre ?? '').trim(),
          'sort_by': (sortBy ?? '').trim(),
          'page': '$page',
          'page_size': '$pageSize',
        },
      ),
    );
  }

  Future<dynamic> toggleVideoDelete(String videoId) {
    return _putJson(_uri('/api/video/$videoId/delete'));
  }

  Future<dynamic> fetchVideoSeasons(String videoId) {
    return _getAny(_uri('/api/video/$videoId/season'));
  }

  Future<dynamic> fetchVideoEpisodes(
    String videoId, {
    String? seasonNumber,
    bool withSeek = false,
    bool withSeekIsRequest = false,
  }) {
    return _getAny(
      _uri(
        '/api/video/$videoId/episode',
        <String, String?>{
          'season_number': (seasonNumber ?? '').trim(),
          'with_seek': withSeek ? '1' : '',
          'with_seek_is_request': withSeekIsRequest ? '1' : '',
        },
      ),
    );
  }

  Future<dynamic> fetchMediaList({
    String? videoListId,
    String? videoSeasonId,
    String? videoEpisodeId,
    String? videoPartId,
  }) {
    return _getAny(
      _uri(
        '/api/video/media/list',
        <String, String?>{
          'video_list_id': (videoListId ?? '').trim(),
          'video_season_id': (videoSeasonId ?? '').trim(),
          'video_episode_id': (videoEpisodeId ?? '').trim(),
          'video_part_id': (videoPartId ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> deleteMedia(String mediaId) {
    return _delete(_uri('/api/video/media/delete', <String, String?>{'media_id': mediaId.trim()}));
  }

  Future<dynamic> moveMedia({
    required String mediaId,
    required String itemType,
    required String itemId,
  }) {
    return _putJson(
      _uri(
        '/api/video/media/move',
        <String, String?>{
          'media_id': mediaId.trim(),
          'item_type': itemType.trim(),
          'item_id': itemId.trim(),
        },
      ),
    );
  }

  Future<dynamic> renameMedia({required String mediaId, required String name}) {
    return _putJson(
      _uri(
        '/api/video/media/rename',
        <String, String?>{'media_id': mediaId.trim(), 'name': name.trim()},
      ),
    );
  }

  Future<dynamic> fetchSubtitleList({
    String? videoListId,
    String? videoEpisodeId,
    String? videoPartId,
    String? videoMediaId,
  }) {
    return _getAny(
      _uri(
        '/api/video/subtitle/list',
        <String, String?>{
          'video_list_id': (videoListId ?? '').trim(),
          'video_episode_id': (videoEpisodeId ?? '').trim(),
          'video_part_id': (videoPartId ?? '').trim(),
          'video_media_id': (videoMediaId ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> deleteSubtitle(String subtitleId) {
    return _delete(
      _uri('/api/video/subtitle/delete', <String, String?>{'subtitle_id': subtitleId.trim()}),
    );
  }

  Future<dynamic> renameSubtitle({required String subtitleId, required String title}) {
    return _putJson(
      _uri(
        '/api/video/subtitle/rename',
        <String, String?>{
          'subtitle_id': subtitleId.trim(),
          'title': title.trim(),
        },
      ),
    );
  }

  Future<dynamic> getUploadToken({
    required String type,
    required String fileType,
    required String fileName,
    required int fileSize,
    String? fileStorage,
  }) {
    return _postJson(
      _uri('/api/upload/getUploadToken'),
      <String, Object?>{
        'type': type.trim(),
        'file_type': fileType.trim(),
        'file_name': fileName.trim(),
        'file_size': fileSize,
        'file_storage': (fileStorage ?? '').trim(),
      },
    );
  }

  Future<dynamic> fetchUploadVideoBase({
    required String itemType,
    required String itemId,
  }) {
    return _getAny(
      _uri(
        '/api/upload/video/base',
        <String, String?>{'item_type': itemType.trim(), 'item_id': itemId.trim()},
      ),
    );
  }

  Future<dynamic> saveUploadedVideo({
    required String itemType,
    required String itemId,
    required String fileId,
  }) {
    return _postJson(
      _uri('/api/upload/video/save'),
      <String, Object?>{
        'item_type': itemType.trim(),
        'item_id': itemId,
        'file_id': fileId.trim(),
      },
    );
  }

  Future<dynamic> saveUploadedSubtitle({
    required String itemType,
    required String itemId,
    required String fileId,
  }) {
    return _postJson(
      _uri('/api/upload/subtitle/save'),
      <String, Object?>{
        'item_type': itemType.trim(),
        'item_id': itemId,
        'file_id': fileId.trim(),
      },
    );
  }

  Future<dynamic> exchangeWatchSlot() => _postJson(_uri('/api/watch/slot'), const {});

  Future<dynamic> fetchWatches({
    String? watchId,
    String? name,
    String? authorId,
    String? isPublic,
    String? isSelf,
    String? isSubscribe,
  }) {
    return _getAny(
      _uri(
        '/api/watch',
        <String, String?>{
          'watch_id': (watchId ?? '').trim(),
          'name': (name ?? '').trim(),
          'author_id': (authorId ?? '').trim(),
          'is_public': (isPublic ?? '').trim(),
          'is_self': (isSelf ?? '').trim(),
          'is_subscribe': (isSubscribe ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> upsertWatch(Map<String, Object?> body) {
    return _postJson(_uri('/api/watch'), body);
  }

  Future<dynamic> updateWatchMaintainers({
    required String watchId,
    required List<String> maintainers,
  }) {
    return _putJson(
      _uri('/api/watch/$watchId/maintainer'),
      <String, Object?>{'maintainers': maintainers.map((e) => e.trim()).where((e) => e.isNotEmpty).toList()},
    );
  }

  Future<dynamic> deleteWatch(String watchId) => _delete(_uri('/api/watch/$watchId'));

  Future<dynamic> sortWatch({required String watchId, required int sort}) {
    return _putJson(_uri('/api/watch/$watchId/sort', <String, String?>{'sort': '$sort'}));
  }

  Future<dynamic> fetchWatchUsers(String watchId, {int page = 1, int pageSize = 15}) {
    return _getAny(
      _uri(
        '/api/watch/$watchId/user',
        <String, String?>{'page': '$page', 'page_size': '$pageSize'},
      ),
    );
  }

  Future<dynamic> toggleWatchSubscribe(String watchId, {String? sort}) {
    return _putJson(_uri('/api/watch/$watchId/subscribe', <String, String?>{'sort': (sort ?? '').trim()}));
  }

  Future<dynamic> fetchWatchVideos(String watchId, {String? videoTitle, int page = 1, int pageSize = 15}) {
    return _getAny(
      _uri(
        '/api/watch/$watchId/video',
        <String, String?>{
          'video_title': (videoTitle ?? '').trim(),
          'page': '$page',
          'page_size': '$pageSize',
        },
      ),
    );
  }

  Future<dynamic> searchWatchVideos(String watchId, {required String title, String? type}) {
    return _getAny(
      _uri(
        '/api/watch/$watchId/video/search',
        <String, String?>{
          'title': title.trim(),
          'type': (type ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> updateWatchVideo({
    required String watchId,
    required String videoId,
    required int sort,
    String? remark,
  }) {
    return _postJson(
      _uri('/api/watch/$watchId/video/$videoId'),
      <String, Object?>{
        'sort': sort,
        'remark': (remark ?? '').trim().isEmpty ? null : (remark ?? '').trim(),
      },
    );
  }

  Future<dynamic> deleteWatchVideo({required String watchId, required String videoId}) {
    return _delete(_uri('/api/watch/$watchId/video/$videoId'));
  }

  Future<dynamic> clearWatchVideos(String watchId) {
    return _delete(_uri('/api/watch/$watchId/video/empty'));
  }

  Future<dynamic> batchUpdateWatchVideos({required String watchId, required List<Object?> body}) {
    return _postJson(_uri('/api/watch/$watchId/video/update'), body);
  }

  Future<dynamic> fetchSeeks(Map<String, Object?> body) {
    return _postJson(_uri('/api/seek'), body);
  }

  Future<dynamic> pollSeeks({String? lastId, int pageSize = 10}) {
    return _getAny(
      _uri(
        '/api/seek/poll',
        <String, String?>{'last_id': (lastId ?? '').trim(), 'page_size': '$pageSize'},
      ),
    );
  }

  Future<dynamic> toggleSeekApply({required String itemType, required String itemId}) {
    return _putJson(_uri('/api/seek/apply', <String, String?>{'item_type': itemType.trim(), 'item_id': itemId.trim()}));
  }

  Future<dynamic> querySeek({required String seekId}) {
    return _getAny(_uri('/api/seek/query', <String, String?>{'seek_id': seekId.trim()}));
  }

  Future<dynamic> fetchSeekHistory({
    required String seekId,
    String? videoListId,
    String? videoSeasonId,
    String? videoEpisodeId,
  }) {
    return _getAny(
      _uri(
        '/api/seek/history',
        <String, String?>{
          'seek_id': seekId.trim(),
          'video_list_id': (videoListId ?? '').trim(),
          'video_season_id': (videoSeasonId ?? '').trim(),
          'video_episode_id': (videoEpisodeId ?? '').trim(),
        },
      ),
    );
  }

  Future<dynamic> claimSeek({required int seekId, required String type}) {
    return _putJson(
      _uri('/api/seek/claim'),
      <String, Object?>{'seek_id': seekId, 'type': type.trim()},
    );
  }

  Future<dynamic> urgeSeek({required int seekId, required int carrot}) {
    return _putJson(
      _uri('/api/seek/urge'),
      <String, Object?>{'seek_id': seekId, 'carrot': carrot},
    );
  }
}
