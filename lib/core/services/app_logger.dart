import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel { verbose, debug, info, warning, error }

extension LogLevelX on LogLevel {
  /// 5 字定宽标签，便于 grep / 对齐。
  String get label => switch (this) {
        LogLevel.verbose => 'VERB',
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO',
        LogLevel.warning => 'WARN',
        LogLevel.error => 'ERROR',
      };

  /// 映射到 dart:developer / 原生 logcat 级别。
  int get developerLevel => switch (this) {
        LogLevel.verbose => 300,
        LogLevel.debug => 500,
        LogLevel.info => 800,
        LogLevel.warning => 900,
        LogLevel.error => 1000,
      };
}

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  /// 单行原生格式：`2026-06-16T14:30:01.234  INFO  [Tag] message`。
  /// 固定列宽、ISO 时间戳、无装饰字符——方便人/AI/工具直接 grep 与解析。
  String format() {
    final ts = timestamp.toIso8601String();
    final lvl = level.label.padRight(5);
    return '$ts  $lvl [$tag] $message';
  }

  @override
  String toString() => format();
}

/// 应用日志系统（全局单例）。
///
/// 设计为「原生、详尽、可被 AI 精确读取」：
/// - 所有构建（含 release）都输出到原生控制台（`dart:developer.log` → Android logcat /
///   桌面 stdout），不再仅限 debug、不经 `debugPrint` 截断。
/// - 同步落盘到滚动日志文件（`<support>/logs/linplayer.log`，超限轮转 .1），
///   崩溃/重启不丢日志；AI 可直接读取该文件。
/// - 单行 ISO 时间戳 + 定宽级别 + `[tag]`，无 box-drawing 装饰。
/// - 捕获未处理异常（[installErrorHandlers]）写入日志。
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal();

  final Queue<LogEntry> _logs = Queue<LogEntry>();
  static const int _maxLogs = 20000;
  static const int _maxFileBytes = 50 * 1024 * 1024; // 单日志文件 50MB，超限轮转
  static const int _maxLogDays = 7; // 保留最近 7 天日志

  IOSink? _sink;
  File? _logFile;
  bool _fileReady = false;
  final List<String> _pending = <String>[]; // 文件就绪前缓冲
  Timer? _flushTimer;

  String? get logFilePath => _logFile?.path;

  /// 获取今天的日志文件名：linplayer-YYYY-MM-DD.log
  String _getTodayFileName() {
    final now = DateTime.now();
    final year = now.year;
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return 'linplayer-$year-$month-$day.log';
  }

  /// 清理超过保留期的旧日志文件
  void _cleanOldLogs(Directory logDir) {
    try {
      final now = DateTime.now();
      final cutoff = now.subtract(const Duration(days: _maxLogDays));

      for (final entity in logDir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('linplayer-')) continue;

        // 解析日期：linplayer-2026-06-16.log
        final match =
            RegExp(r'linplayer-(\d{4})-(\d{2})-(\d{2})').firstMatch(name);
        if (match == null) continue;

        final fileDate = DateTime(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
        );

        if (fileDate.isBefore(cutoff)) {
          entity.deleteSync();
          developer.log('已删除旧日志: $name', name: 'AppLogger', level: 800);
        }
      }
    } catch (e) {
      developer.log('清理旧日志失败: $e', name: 'AppLogger', level: 900);
    }
  }

  /// 初始化文件日志（在 main 中尽早 await）。可重复调用，幂等。
  Future<void> init() async {
    if (_fileReady) return;
    try {
      // 滚动日志放系统 temp 下（不进 AppData/Roaming），属临时产物、随清理可弃。
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/linplayer_logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // 清理旧日志（保留最近 N 天）
      _cleanOldLogs(dir);

      // 打开今天的日志文件
      final fileName = _getTodayFileName();
      final file = File('${dir.path}/$fileName');

      // 轮转：如果今天的文件已超限，重命名为 .1（覆盖旧的 .1）
      if (file.existsSync() && await file.length() > _maxFileBytes) {
        final rotated = File('${dir.path}/$fileName.1');
        if (rotated.existsSync()) rotated.deleteSync();
        file.renameSync(rotated.path);
      }

      _logFile = file;
      _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      _fileReady = true;

      // 写入会话分隔头（纯文本注释行）。
      _sink!.writeln('');
      _sink!.writeln('# ==== session start ${DateTime.now().toIso8601String()} '
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion} ====');
      if (_pending.isNotEmpty) {
        for (final line in _pending) {
          _sink!.writeln(line);
        }
        _pending.clear();
      }
      _flushTimer ??=
          Timer.periodic(const Duration(seconds: 2), (_) => _sink?.flush());
      i('AppLogger', '日志系统已初始化，文件: ${file.path}');
    } catch (e) {
      // 文件不可用（如部分平台权限）时退化为内存 + 控制台。
      developer.log('日志文件初始化失败: $e', name: 'AppLogger', level: 900);
    }
  }

  /// 捕获 Flutter 框架错误与平台异步异常，统一写入日志。
  void installErrorHandlers() {
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      eWithStack('FlutterError', details.exceptionAsString(),
          details.exception, details.stack);
      prevFlutter?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      eWithStack('PlatformDispatcher', '未捕获异步异常', error, stack);
      return false;
    };
  }

  void _log(LogLevel level, String tag, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );
    _logs.add(entry);
    while (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }

    final line = entry.format();
    // 原生控制台（所有构建）：Android→logcat / 桌面→stdout，不截断。
    developer.log(message,
        time: entry.timestamp,
        level: level.developerLevel,
        name: tag);

    // 落盘。
    if (_fileReady) {
      _sink?.writeln(line);
      if (level == LogLevel.error) _sink?.flush();
    } else {
      _pending.add(line);
      if (_pending.length > 1000) _pending.removeAt(0);
    }
  }

  void v(String tag, String message) => _log(LogLevel.verbose, tag, message);
  void d(String tag, String message) => _log(LogLevel.debug, tag, message);
  void i(String tag, String message) => _log(LogLevel.info, tag, message);
  void w(String tag, String message) => _log(LogLevel.warning, tag, message);
  void e(String tag, String message) => _log(LogLevel.error, tag, message);

  void eWithStack(String tag, String message, Object error,
      [StackTrace? stackTrace]) {
    final buffer = StringBuffer()
      ..writeln(message)
      ..writeln('  error: $error');
    if (stackTrace != null) {
      buffer.writeln('  stack:');
      for (final frame in stackTrace.toString().split('\n')) {
        if (frame.trim().isEmpty) continue;
        buffer.writeln('    $frame');
      }
    }
    _log(LogLevel.error, tag, buffer.toString().trimRight());
  }

  List<LogEntry> getLogs({LogLevel? minLevel}) {
    if (minLevel == null) return List.unmodifiable(_logs);
    return List.unmodifiable(
        _logs.where((l) => l.level.index >= minLevel.index));
  }

  void clear() => _logs.clear();

  /// 会话分隔标记前缀（与 init 写入的一致）。
  static const _sessionMarker = '# ==== session start';

  /// 仅保留日志文本中最后 [sessions] 个会话（含分隔头）。
  String _trimToLastSessions(String content, int sessions) {
    final indices = <int>[];
    var idx = content.indexOf(_sessionMarker);
    while (idx != -1) {
      indices.add(idx);
      idx = content.indexOf(_sessionMarker, idx + 1);
    }
    if (indices.length <= sessions) return content;
    return content.substring(indices[indices.length - sessions]);
  }

  /// 导出为纯文本（用于界面显示）：仅最近两次会话。
  Future<String> exportAsString() async {
    try {
      if (_logFile == null || !_logFile!.existsSync()) {
        return '# 当天日志文件不存在\n# 内存日志条数: ${_logs.length}';
      }
      await _sink?.flush();
      final content = await _logFile!.readAsString();
      return _trimToLastSessions(content, 2);
    } catch (e) {
      w('AppLogger', '读取日志文件失败: $e');
      return '# 读取日志文件失败: $e\n# 内存日志条数: ${_logs.length}';
    }
  }

  /// 导出今天的日志文件到下载目录（复制文件）。
  Future<String> exportToFile() async {
    if (_logFile == null || !_logFile!.existsSync()) {
      throw Exception('当天日志文件不存在');
    }

    // 先 flush 确保最新日志已落盘
    await _sink?.flush();

    // 仅导出最近两次会话（当前 + 上一次），更早的不带。
    final content = _trimToLastSessions(await _logFile!.readAsString(), 2);

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final fileName = 'linplayer_log_$timestamp.txt';

    // Android：写到 Download 方便取出。
    if (Platform.isAndroid) {
      try {
        final downloads = Directory('/storage/emulated/0/Download');
        if (downloads.existsSync()) {
          final exportFile = File('${downloads.path}/$fileName');
          await exportFile.writeAsString(content);
          i('AppLogger', '日志已导出: ${exportFile.path}');
          return exportFile.path;
        }
      } catch (e) {
        w('AppLogger', '导出到 Download 失败，回退应用目录: $e');
      }
    }

    // 其他平台：写到应用文档目录
    final dir = await getApplicationDocumentsDirectory();
    final exportFile = File('${dir.path}/$fileName');
    await exportFile.writeAsString(content);
    i('AppLogger', '日志已导出: ${exportFile.path}');
    return exportFile.path;
  }

  /// 释放（flush + close），通常无需手动调用。
  Future<void> dispose() async {
    _flushTimer?.cancel();
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _fileReady = false;
  }
}

/// 全局日志便捷实例。
final log = AppLogger();
