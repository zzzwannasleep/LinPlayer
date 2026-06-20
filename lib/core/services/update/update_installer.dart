import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
      // 更新下载强制严格 TLS：不复用可能放行自签名证书的客户端，杜绝 MITM 投递。
      applyStrictProxyToDio(dio);
      await dio.download(
        asset.url,
        savePath,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
      );

      // 完整性校验：若发布提供了 SHA256 校验文件，必须匹配才放行；不匹配一律
      // 删除并失败，防止被篡改/损坏的安装包被交给系统安装器执行。
      final expected = await _expectedSha256(info, asset, dio);
      if (expected != null) {
        final actual = await _sha256OfFile(savePath);
        if (actual.toLowerCase() != expected.toLowerCase()) {
          _logger.e(_tag, '安装包 SHA256 校验失败: 期望 $expected 实得 $actual，已删除');
          try {
            File(savePath).deleteSync();
          } catch (_) {}
          return ApplyResult.failed;
        }
        _logger.i(_tag, '安装包 SHA256 校验通过');
      } else {
        _logger.w(_tag, '发布未提供 SHA256 校验文件，跳过完整性校验');
      }
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

  /// 从发布资产里找到本安装包的预期 SHA256（十六进制）。
  ///
  /// 约定（任一命中即可，均经严格 TLS 从同一发布获取）：
  /// - 同名 `<asset>.sha256` 资产，内容为 `<hex>` 或 `<hex>  <name>`；
  /// - 汇总文件 `SHA256SUMS` / `SHA256SUMS.txt` / `checksums.txt`，逐行
  ///   `<hex>  <name>`，匹配本资产名。
  ///
  /// 找不到或获取失败返回 null（记录告警，不阻断更新）；一旦提供则强制校验。
  static Future<String?> _expectedSha256(
      UpdateInfo info, UpdateAsset asset, Dio dio) async {
    final sidecarName = '${asset.name}.sha256'.toLowerCase();
    const sumsNames = {'sha256sums', 'sha256sums.txt', 'checksums.txt'};

    UpdateAsset? sidecar;
    UpdateAsset? sums;
    for (final a in info.assets) {
      final lower = a.name.toLowerCase();
      if (lower == sidecarName) sidecar = a;
      if (sumsNames.contains(lower)) sums = a;
    }

    try {
      if (sidecar != null && sidecar.url.isNotEmpty) {
        final resp = await dio.get<String>(
          sidecar.url,
          options: Options(responseType: ResponseType.plain),
        );
        return _parseHashFor(resp.data, asset.name, singleLine: true);
      }
      if (sums != null && sums.url.isNotEmpty) {
        final resp = await dio.get<String>(
          sums.url,
          options: Options(responseType: ResponseType.plain),
        );
        return _parseHashFor(resp.data, asset.name, singleLine: false);
      }
    } catch (e) {
      _logger.w(_tag, '获取校验文件失败，跳过完整性校验: $e');
    }
    return null;
  }

  /// 从校验文件文本解出 64 位十六进制 SHA256。
  /// [singleLine]=true 按“单文件 .sha256”取首个 hex；否则汇总文件逐行匹配资产名。
  static String? _parseHashFor(String? text, String assetName,
      {required bool singleLine}) {
    if (text == null || text.trim().isEmpty) return null;
    final hex = RegExp(r'\b[a-fA-F0-9]{64}\b');
    if (singleLine) {
      return hex.firstMatch(text)?.group(0);
    }
    for (final line in const LineSplitter().convert(text)) {
      if (line.toLowerCase().contains(assetName.toLowerCase())) {
        final m = hex.firstMatch(line);
        if (m != null) return m.group(0);
      }
    }
    return null;
  }

  /// 流式计算文件 SHA256（十六进制小写）。
  static Future<String> _sha256OfFile(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
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
