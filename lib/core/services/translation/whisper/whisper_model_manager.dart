import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../app_logger.dart';
import 'whisper_model.dart';

/// 模型下载进度：[received]/[total] 字节，[progress] 0..1。
typedef WhisperDownloadProgress = void Function(
    int received, int total, double progress);

/// Whisper 模型管理：定位存储目录、查询是否已下载、下载/删除模型。
///
/// 模型存放于 ApplicationSupport 目录（持久，不随缓存清理被删）。下载用 dio
/// 流式写入临时文件，完成后原子改名，避免中断产生半截损坏文件。
class WhisperModelManager {
  WhisperModelManager({AppLogger? logger}) : _logger = logger ?? AppLogger();

  final AppLogger _logger;
  static const _tag = 'WhisperModel';
  CancelToken? _cancelToken;

  Future<Directory> modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/whisper_models');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> modelFile(WhisperModel model) async {
    final dir = await modelsDir();
    return File('${dir.path}/${model.fileName}');
  }

  Future<bool> isDownloaded(WhisperModel model) async {
    final f = await modelFile(model);
    return f.existsSync() && await f.length() > 1024 * 1024;
  }

  /// 已下载模型的体积（字节），未下载返回 0。
  Future<int> downloadedSize(WhisperModel model) async {
    final f = await modelFile(model);
    return f.existsSync() ? await f.length() : 0;
  }

  /// 下载模型；[mirrorBase] 为空用官方源。支持取消。
  Future<void> download(
    WhisperModel model, {
    String mirrorBase = '',
    WhisperDownloadProgress? onProgress,
  }) async {
    final target = await modelFile(model);
    final tmp = File('${target.path}.part');
    final url = model.downloadUrl(mirrorBase);
    _cancelToken = CancelToken();
    _logger.i(_tag, '开始下载 ${model.fileName}: $url');

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 30),
    ));
    try {
      await dio.download(
        url,
        tmp.path,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          final p = total > 0 ? received / total : 0.0;
          onProgress?.call(received, total, p);
        },
      );
      if (target.existsSync()) await target.delete();
      await tmp.rename(target.path);
      _logger.i(_tag, '下载完成: ${target.path}');
    } catch (e) {
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      if (e is DioException && CancelToken.isCancel(e)) {
        _logger.w(_tag, '下载已取消: ${model.fileName}');
        rethrow;
      }
      _logger.e(_tag, '下载失败: $e');
      rethrow;
    } finally {
      _cancelToken = null;
    }
  }

  void cancelDownload() => _cancelToken?.cancel('user cancelled');

  Future<void> delete(WhisperModel model) async {
    final f = await modelFile(model);
    if (f.existsSync()) {
      await f.delete();
      _logger.i(_tag, '已删除模型: ${model.fileName}');
    }
  }
}
