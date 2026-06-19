import 'package:dio/dio.dart';

import '../../app_identity.dart';
import '../app_logger.dart';

/// 应用当前版本：统一取自 [kAppVersion]（CI 构建时通过 --dart-define=APP_VERSION 注入）。
const String kCurrentAppVersion = kAppVersion;

/// 发布仓库（GitHub）。如迁移仓库改这里即可。
const String kUpdateRepoOwner = 'zzzwannasleep';
const String kUpdateRepoName = 'LinPlayer';

/// 一个可下载的发布资产。
class UpdateAsset {
  UpdateAsset({required this.name, required this.url, required this.size});
  final String name;
  final String url;
  final int size;
}

/// 一次可用更新的信息。
class UpdateInfo {
  UpdateInfo({
    required this.version,
    required this.tag,
    required this.title,
    required this.notes,
    required this.pageUrl,
    required this.isPrerelease,
    required this.assets,
  });

  final String version; // 归一化后的 x.y.z
  final String tag; // 原始 tag，如 v1.2.0 或 v1.2.0-pre
  final String title;
  final String notes;
  final String pageUrl;
  final bool isPrerelease;
  final List<UpdateAsset> assets;

  /// 按关键字挑选本平台资产（如 'Windows'、'Android-Mobile'、'macOS'）。
  UpdateAsset? assetMatching(Iterable<String> keywords) {
    for (final a in assets) {
      final lower = a.name.toLowerCase();
      if (keywords.every((k) => lower.contains(k.toLowerCase()))) return a;
    }
    return null;
  }
}

/// 检查 GitHub Releases 是否有新版本。
class AppUpdateService {
  AppUpdateService({Dio? dio, AppLogger? logger})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'Accept': 'application/vnd.github+json',
                'User-Agent': kAppUserAgent,
              },
            )),
        _logger = logger ?? AppLogger();

  final Dio _dio;
  final AppLogger _logger;
  static const _tag = 'AppUpdate';

  String get _base =>
      'https://api.github.com/repos/$kUpdateRepoOwner/$kUpdateRepoName';

  /// 检查更新。[includePrerelease] 为 true 时也考虑最新的预发布(pre)。
  /// 无更新或失败返回 null。
  Future<UpdateInfo?> checkForUpdate({bool includePrerelease = false}) async {
    try {
      final release = includePrerelease
          ? await _latestIncludingPrerelease()
          : await _latestStable();
      if (release == null) return null;

      final info = _parseRelease(release);
      if (info == null) return null;

      if (compareVersions(info.version, normalizeVersion(kCurrentAppVersion)) >
          0) {
        _logger.i(_tag,
            '发现新版本: ${info.tag}（当前 $kCurrentAppVersion），pre=${info.isPrerelease}');
        return info;
      }
      _logger.i(_tag, '已是最新: 当前 $kCurrentAppVersion, 远端 ${info.tag}');
      return null;
    } catch (e) {
      _logger.w(_tag, '检查更新失败: $e');
      return null;
    }
  }

  Future<Map?> _latestStable() async {
    final resp = await _dio.get('$_base/releases/latest');
    return resp.data is Map ? resp.data as Map : null;
  }

  Future<Map?> _latestIncludingPrerelease() async {
    final resp = await _dio.get('$_base/releases',
        queryParameters: {'per_page': 10});
    final list = resp.data;
    if (list is! List || list.isEmpty) return null;
    // GitHub 按时间倒序返回，取第一个未草稿的（含 pre）。
    for (final r in list) {
      if (r is Map && r['draft'] != true) return r;
    }
    return null;
  }

  UpdateInfo? _parseRelease(Map r) {
    final tag = (r['tag_name'] ?? '').toString();
    if (tag.isEmpty) return null;
    final assets = <UpdateAsset>[];
    final rawAssets = r['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is Map) {
          assets.add(UpdateAsset(
            name: (a['name'] ?? '').toString(),
            url: (a['browser_download_url'] ?? '').toString(),
            size: (a['size'] is int) ? a['size'] as int : 0,
          ));
        }
      }
    }
    return UpdateInfo(
      version: normalizeVersion(tag),
      tag: tag,
      title: (r['name'] ?? tag).toString(),
      notes: (r['body'] ?? '').toString(),
      pageUrl: (r['html_url'] ?? '').toString(),
      isPrerelease: r['prerelease'] == true,
      assets: assets,
    );
  }

  /// 取出 x.y.z（去掉前缀 v 和 -pre/-build 等后缀）。
  static String normalizeVersion(String raw) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(raw);
    if (m == null) return '0.0.0';
    return '${m.group(1)}.${m.group(2)}.${m.group(3)}';
  }

  /// 语义版本比较：a>b 返回 1，相等 0，a<b 返回 -1。
  static int compareVersions(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }
}
