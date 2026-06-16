import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../app_logger.dart';

/// 下载进度回调。
typedef BinaryDownloadProgress = void Function(
    int received, int total, double progress);

/// 桌面端外部二进制（ffmpeg / whisper-cli）的定位与下载管理。
///
/// 解析顺序：用户指定路径 → 已下载缓存 → 随应用打包(可执行文件同级) → 系统 PATH
/// → 常见安装位置。ffmpeg 若全部落空，可经用户许可自动下载官方静态构建。
class DesktopBinaryManager {
  DesktopBinaryManager({AppLogger? logger}) : _logger = logger ?? AppLogger();

  final AppLogger _logger;
  static const _tag = 'DesktopBinary';
  CancelToken? _cancel;

  // 官方/官网指向的静态构建下载地址。
  static const _ffmpegWinGyan =
      'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip';
  static const _ffmpegMacEvermeet =
      'https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip';
  static const _ffmpegLinuxStatic =
      'https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz';

  String get _ffmpegName => Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  String get _whisperName =>
      Platform.isWindows ? 'whisper-cli.exe' : 'whisper-cli';

  Future<Directory> _binDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/bin');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  // ============ ffmpeg ============

  /// 定位 ffmpeg，找不到返回 null。
  Future<String?> resolveFfmpeg({String configured = ''}) async {
    if (configured.isNotEmpty && File(configured).existsSync()) {
      return configured;
    }
    final cached = File('${(await _binDir()).path}/$_ffmpegName');
    if (cached.existsSync()) return cached.path;
    for (final c in [
      '$_exeDir/$_ffmpegName',
      '$_exeDir/ffmpeg/$_ffmpegName',
      '$_exeDir/bin/$_ffmpegName',
    ]) {
      if (File(c).existsSync()) return c;
    }
    if (await _runsOk(_ffmpegName)) return _ffmpegName; // PATH
    for (final c in _commonFfmpegLocations()) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  List<String> _commonFfmpegLocations() {
    if (Platform.isWindows) {
      return [r'C:\ffmpeg\bin\ffmpeg.exe', r'C:\Program Files\ffmpeg\bin\ffmpeg.exe'];
    }
    if (Platform.isMacOS) {
      return ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'];
    }
    return ['/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/snap/bin/ffmpeg'];
  }

  /// 下载并安装 ffmpeg 到应用 bin 目录，返回可执行文件路径。
  Future<String> downloadFfmpeg({BinaryDownloadProgress? onProgress}) async {
    final url = Platform.isWindows
        ? _ffmpegWinGyan
        : Platform.isMacOS
            ? _ffmpegMacEvermeet
            : _ffmpegLinuxStatic;
    final isTarXz = url.endsWith('.tar.xz');
    final tmpName = isTarXz ? 'ffmpeg_dl.tar.xz' : 'ffmpeg_dl.zip';
    final binDir = await _binDir();
    final tmp = File('${binDir.path}/$tmpName');

    _cancel = CancelToken();
    _logger.i(_tag, '下载 ffmpeg: $url');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 20),
      followRedirects: true,
    ));
    await dio.download(
      url,
      tmp.path,
      cancelToken: _cancel,
      onReceiveProgress: (r, t) =>
          onProgress?.call(r, t, t > 0 ? r / t : 0.0),
    );

    final outPath = '${binDir.path}/$_ffmpegName';
    final bytes = await tmp.readAsBytes();
    final archive = isTarXz
        ? TarDecoder().decodeBytes(XZDecoder().decodeBytes(bytes))
        : ZipDecoder().decodeBytes(bytes);
    final entry = archive.files.firstWhere(
      (f) => f.isFile &&
          (f.name.endsWith('/bin/$_ffmpegName') ||
              f.name.endsWith('/$_ffmpegName') ||
              f.name == _ffmpegName),
      orElse: () => throw StateError('压缩包内未找到 $_ffmpegName'),
    );
    await File(outPath).writeAsBytes(entry.content as List<int>);
    try {
      await tmp.delete();
    } catch (_) {}
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', outPath]);
    }
    _logger.i(_tag, 'ffmpeg 已安装: $outPath');
    return outPath;
  }

  // ============ whisper-cli ============

  /// 定位 whisper-cli（内置/缓存/PATH），找不到返回 null。
  Future<String?> resolveWhisper({String configured = ''}) async {
    if (configured.isNotEmpty && File(configured).existsSync()) {
      return configured;
    }
    final cached = File('${(await _binDir()).path}/$_whisperName');
    if (cached.existsSync()) return cached.path;
    // 随应用打包：可执行文件同级 / Resources。
    for (final c in [
      '$_exeDir/$_whisperName',
      '$_exeDir/whisper/$_whisperName',
      '$_exeDir/bin/$_whisperName',
      '$_exeDir/../Resources/whisper/$_whisperName', // macOS .app
    ]) {
      if (File(c).existsSync()) return c;
    }
    if (await _runsOk(_whisperName)) return _whisperName; // PATH
    // 兼容旧名 main / whisper。
    for (final alt in ['main', 'whisper']) {
      final altName = Platform.isWindows ? '$alt.exe' : alt;
      if (File('$_exeDir/$altName').existsSync()) {
        return '$_exeDir/$altName';
      }
    }
    return null;
  }

  void cancelDownload() => _cancel?.cancel('user cancelled');

  Future<bool> _runsOk(String exe) async {
    try {
      final r = await Process.run(exe, ['-version']);
      return r.exitCode == 0;
    } catch (_) {
      try {
        final r = await Process.run(exe, ['--help']);
        return r.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
  }
}
