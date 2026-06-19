import 'dart:io';

import 'package:flutter/services.dart';

import '../providers/app_preferences.dart';
import 'app_logger.dart';

/// 原生崩溃诊断（Android）。
///
/// 原生 SIGSEGV（如 libmpv 闪退）发生在 Dart/Java 之下，`FlutterError.onError`
/// 与应用日志都抓不到，表现为日志"戛然而止"。本类启动时用
/// `ActivityManager.getHistoricalProcessExitReasons`（API 30+，免权限）读取上次
/// 进程退出原因；若为崩溃/ANR，则把原生回溯（tombstone / anr trace）写入可导出的
/// App 日志，便于事后定位。按 timestamp 去重，避免每次启动重复记录同一崩溃。
class CrashDiagnostics {
  static const _channel = MethodChannel('com.linplayer/diagnostics');
  static const _prefKey = 'linplayer_last_exit_report_ts';

  // ApplicationExitInfo.REASON_* 常量。
  static const int _reasonCrash = 4; // REASON_CRASH（JVM 未捕获异常）
  static const int _reasonCrashNative = 5; // REASON_CRASH_NATIVE（原生信号）
  static const int _reasonAnr = 6; // REASON_ANR

  static Future<void> reportRecentExits() async {
    if (!Platform.isAndroid) return;
    try {
      final result =
          await _channel.invokeMethod<List<dynamic>>('getRecentExitReasons');
      if (result == null || result.isEmpty) return;

      final prefs = AppPreferencesStore.instance;
      final lastReported = prefs.getInt(_prefKey) ?? 0;
      var newest = lastReported;

      for (final entry in result) {
        if (entry is! Map) continue;
        final ts = (entry['timestamp'] as num?)?.toInt() ?? 0;
        if (ts <= lastReported) continue;
        if (ts > newest) newest = ts;

        final reason = (entry['reason'] as num?)?.toInt() ?? -1;
        final desc = entry['description']?.toString() ?? '';
        final trace = entry['trace']?.toString();
        final when = DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String();
        final reasonName = _reasonName(reason);

        if (reason == _reasonCrashNative ||
            reason == _reasonCrash ||
            reason == _reasonAnr) {
          final buffer = StringBuffer()
            ..writeln('检测到上次异常退出: $reasonName（$desc） @ $when');
          if (trace != null && trace.trim().isNotEmpty) {
            buffer.writeln('原生回溯 trace:');
            // 限长，避免超大 tombstone 撑爆单条日志。
            buffer.writeln(
                trace.length > 16000 ? '${trace.substring(0, 16000)}\n…(截断)' : trace);
          } else {
            buffer.writeln('（系统未提供回溯文本）');
          }
          AppLogger().e('NativeCrash', buffer.toString().trimRight());
        } else {
          AppLogger().i('ExitInfo', '上次退出: $reasonName（$desc） @ $when');
        }
      }

      if (newest > lastReported) {
        await prefs.setInt(_prefKey, newest);
      }
    } catch (_) {
      // 诊断失败不影响启动。
    }
  }

  static String _reasonName(int reason) {
    switch (reason) {
      case 1:
        return 'EXIT_SELF';
      case 2:
        return 'SIGNALED';
      case 3:
        return 'LOW_MEMORY';
      case 4:
        return 'CRASH(JVM)';
      case 5:
        return 'CRASH_NATIVE';
      case 6:
        return 'ANR';
      case 7:
        return 'INITIALIZATION_FAILURE';
      case 8:
        return 'PERMISSION_CHANGE';
      case 9:
        return 'EXCESSIVE_RESOURCE_USAGE';
      case 10:
        return 'USER_REQUESTED';
      case 11:
        return 'USER_STOPPED';
      case 12:
        return 'DEPENDENCY_DIED';
      case 13:
        return 'OTHER';
      default:
        return 'UNKNOWN($reason)';
    }
  }
}
