import '../providers/server_providers.dart';

export 'source_kind.dart';

/// 浏览返回的一行：文件夹或文件。
class SourceEntry {
  /// 该源用于继续浏览 / 取流的标识：夸克=fid，OpenList=完整路径，Ani-rss=filename。
  final String id;
  final String name;
  final bool isDir;
  final bool isVideo;
  final int? size;
  final String? thumbUrl;

  /// 源原始数据，供 resolvePlay 复用（避免二次请求）。
  final Map<String, dynamic>? raw;

  const SourceEntry({
    required this.id,
    required this.name,
    required this.isDir,
    this.isVideo = false,
    this.size,
    this.thumbUrl,
    this.raw,
  });
}

/// 外挂字幕轨。
class SourceSubtitle {
  final String url;
  final String? title;
  final String? language;
  final Map<String, String> httpHeaders;

  const SourceSubtitle({
    required this.url,
    this.title,
    this.language,
    this.httpHeaders = const {},
  });
}

/// 交给播放器的最小可播单元：URL + 逐流 headers（Cookie/Authorization/Referer）。
class ResolvedPlay {
  final String url;
  final String title;
  final Map<String, String> httpHeaders;
  final String? userAgentOverride;
  final List<SourceSubtitle> subtitles;

  const ResolvedPlay({
    required this.url,
    required this.title,
    this.httpHeaders = const {},
    this.userAgentOverride,
    this.subtitles = const [],
  });
}

/// 源后端统一异常（登录失效、解析失败等），UI 据此提示并可触发重登。
class SourceException implements Exception {
  final String message;
  final Object? cause;

  /// 鉴权失效（401/登录过期）——UI 可引导用户重新登录。
  final bool isAuth;

  SourceException(this.message, {this.cause, this.isAuth = false});

  @override
  String toString() => 'SourceException: $message';
}

/// 文件浏览型源后端的最小抽象（三端复用，纯逻辑、无 UI/Riverpod 依赖）。
///
/// 初版只要求三件事：登录后能列目录、能搜索（可降级）、能把文件解析成可播 URL。
abstract class MediaSourceBackend {
  SourceKind get kind;

  /// 列出目录。[dirId] 为 null 表示根目录。
  Future<List<SourceEntry>> listDir(ServerConfig server, {String? dirId});

  /// 源内搜索。无源端搜索能力的实现抛 [UnsupportedError]，UI 退回本地过滤。
  Future<List<SourceEntry>> search(ServerConfig server, String query) =>
      throw UnsupportedError('search not supported');

  /// 把文件解析成可播单元（含取流所需 headers）。短效直链由播放层按
  /// [StreamServerKind.cloud302] 在过期后回调本方法重解析。
  Future<ResolvedPlay> resolvePlay(ServerConfig server, SourceEntry entry);
}

/// 视频扩展名判定（各后端列目录时统一用它标记 [SourceEntry.isVideo]）。
bool isVideoFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = name.substring(dot + 1).toLowerCase();
  return _videoExtensions.contains(ext);
}

const _videoExtensions = <String>{
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg',
  'ts', 'm2ts', 'mts', 'rmvb', 'rm', 'vob', '3gp', 'f4v', 'ogv', 'm3u8',
  'iso', 'divx', 'asf', 'mxf',
};
