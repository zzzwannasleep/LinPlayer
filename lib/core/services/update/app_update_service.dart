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

      // 用「原始 tag」对比「当前 APP_VERSION」，二者都保留 -buildN/-pre 信息。
      // 不能用归一化后的 x.y.z 对比：CI 每个预发布都是 vX.Y.Z-build<run>-pre，
      // 主版本号不变，归一化后恒等 → 预览版永远检测不到更新（本次修复点）。
      if (compareVersions(info.tag, kCurrentAppVersion) > 0) {
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

  /// 版本比较：a>b 返回 1，相等 0，a<b 返回 -1。
  ///
  /// 识别本项目的实际版本形态 `vX.Y.Z[-build<N>][-pre]`（如 `v1.2.0-build88-pre`、
  /// `1.2.0-build88`、`v1.2.0`），按以下优先级排序，**新者为大**：
  /// 主版本 > 次版本 > 修订号 > 构建号(build N) > 稳定优于预览(pre)。
  ///
  /// 关键：同一 x.y.z 下更高的 `-buildN` 视为更新——这正是修复「预览版同号漏检」
  /// 的核心（旧实现只比 x.y.z，丢掉了唯一能区分预发布迭代的构建号）。
  static int compareVersions(String a, String b) {
    final pa = _VersionParts.parse(a);
    final pb = _VersionParts.parse(b);
    if (pa.major != pb.major) return pa.major > pb.major ? 1 : -1;
    if (pa.minor != pb.minor) return pa.minor > pb.minor ? 1 : -1;
    if (pa.patch != pb.patch) return pa.patch > pb.patch ? 1 : -1;
    if (pa.build != pb.build) return pa.build > pb.build ? 1 : -1;
    // 同一构建号下，稳定版（非 pre）视为比预览版更新（发布即由 pre 晋升而来）。
    if (pa.isPre != pb.isPre) return pa.isPre ? -1 : 1;
    return 0;
  }
}

/// 解析后的版本组成，供 [AppUpdateService.compareVersions] 排序使用。
class _VersionParts {
  const _VersionParts(
      this.major, this.minor, this.patch, this.build, this.isPre);

  final int major;
  final int minor;
  final int patch;
  final int build; // -build<N>，缺省 0
  final bool isPre; // 含 -pre 后缀

  static _VersionParts parse(String raw) {
    final core = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(raw);
    final major = core != null ? int.tryParse(core.group(1)!) ?? 0 : 0;
    final minor = core != null ? int.tryParse(core.group(2)!) ?? 0 : 0;
    final patch = core != null ? int.tryParse(core.group(3)!) ?? 0 : 0;
    final b = RegExp(r'-build(\d+)', caseSensitive: false).firstMatch(raw);
    final build = b != null ? int.tryParse(b.group(1)!) ?? 0 : 0;
    final isPre = RegExp(r'-pre\b', caseSensitive: false).hasMatch(raw) ||
        raw.toLowerCase().endsWith('-pre');
    return _VersionParts(major, minor, patch, build, isPre);
  }
}
