import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app_identity.dart';
import '../../network/proxy_http_client.dart';
import '../../utils/platform_utils.dart';
import '../app_logger.dart';
import 'app_update_service.dart';

/// 应用更新的「下载 + 落地」结果。
enum ApplyResult {
  /// Android/TV：已下载并调起系统安装器（用户在系统界面确认覆盖安装）。
  androidInstalling,

  /// 桌面：已下载压缩包并在文件管理器中定位，用户解压覆盖即可。
  desktopRevealed,

  /// 当前平台没有匹配的安装包（如 iOS/tvOS 未签名构建）。
  noAsset,

  /// 下载/调起失败。
  failed,

  /// 用户取消。
  canceled,
}

/// 应用内更新落地器：按当前平台挑选发布资产，下载后调起安装器（Android/TV）
/// 或在文件管理器中定位压缩包（桌面，供用户解压覆盖）。
///
/// iOS / Apple TV 为未签名构建，无法应用内安装，返回 [ApplyResult.noAsset]，
/// 由调用方回退到「前往发布页」。
class UpdateInstaller {
  UpdateInstaller._();

  static final _logger = AppLogger();
  static const _tag = 'UpdateInstaller';

  /// 当前平台是否支持应用内下载落地（Android/TV 安装、桌面揭示）。
  static bool get isSupported =>
      Platform.isAndroid || isDesktopPlatform;

  /// 当前平台应下载的资产名关键字（全部命中才算匹配）。null = 不支持。
  static List<String>? assetKeywords() {
    if (Platform.isAndroid) {
      return isTvPlatform
          ? const ['android', 'tv']
          : const ['android', 'mobile'];
    }
    if (Platform.isWindows) return const ['windows'];
    if (Platform.isMacOS) return const ['macos'];
    if (Platform.isLinux) return const ['linux'];
    return null; // iOS / tvOS
  }

  /// 按当前平台从一次更新里挑出对应安装包，挑不到返回 null。
  static UpdateAsset? pickAsset(UpdateInfo info) {
    final kw = assetKeywords();
    if (kw == null) return null;
    return info.assetMatching(kw);
  }

  /// 下载并落地。[onProgress] 回调 (已收字节, 总字节)。不抛异常，统一以 [ApplyResult] 返回。
  static Future<ApplyResult> downloadAndApply({
    required UpdateInfo info,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final asset = pickAsset(info);
    if (asset == null || asset.url.isEmpty) {
      _logger.w(_tag, '当前平台无匹配安装包: ${info.tag}');
      return ApplyResult.noAsset;
    }

    final String savePath;
    try {
      final dir = await _downloadDir();
      savePath = p.join(dir.path, asset.name);
      // 已存在的旧文件先删，避免半成品/占用。
      final existing = File(savePath);
      if (existing.existsSync()) {
        try {
          existing.deleteSync();
        } catch (_) {}
      }

      final dio = Dio(BaseOptions(headers: {'User-Agent': kAppUserAgent}));
      applyProxyToDio(dio);
      await dio.download(
        asset.url,
        savePath,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return ApplyResult.canceled;
      _logger.eWithStack(_tag, '下载安装包失败', e, e.stackTrace);
      return ApplyResult.failed;
    } catch (e, st) {
      _logger.eWithStack(_tag, '下载安装包异常', e, st);
      return ApplyResult.failed;
    }

    if (Platform.isAndroid) {
      try {
        final res = await OpenFilex.open(
          savePath,
          type: 'application/vnd.android.package-archive',
        );
        if (res.type == ResultType.done) {
          return ApplyResult.androidInstalling;
        }
        _logger.w(_tag, '调起安装器失败: ${res.type} ${res.message}');
        return ApplyResult.failed;
      } catch (e, st) {
        _logger.eWithStack(_tag, '调起安装器异常', e, st);
        return ApplyResult.failed;
      }
    }

    // 桌面：在文件管理器中定位下载好的压缩包，供用户解压覆盖。
    await _revealInFileManager(savePath);
    return ApplyResult.desktopRevealed;
  }

  /// 下载目录：Android 用应用私有缓存（open_filex 经自带 FileProvider 授权安装）；
  /// 桌面优先系统「下载」目录，便于用户找到后解压。
  static Future<Directory> _downloadDir() async {
    if (Platform.isAndroid) {
      return getTemporaryDirectory();
    }
    final downloads = await getDownloadsDirectory();
    return downloads ?? await getTemporaryDirectory();
  }

  /// 在系统文件管理器中定位文件（桌面）。失败则退一步打开所在目录。
  static Future<void> _revealInFileManager(String filePath) async {
    final folder = File(filePath).parent.path;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', ['/select,$filePath']);
        return;
      }
      if (Platform.isMacOS) {
        await Process.start('open', ['-R', filePath]);
        return;
      }
      if (Platform.isLinux) {
        await Process.start('xdg-open', [folder]);
        return;
      }
    } catch (e) {
      _logger.w(_tag, '定位文件失败，改为打开目录: $e');
    }
    try {
      await OpenFilex.open(folder);
    } catch (_) {}
  }
}
