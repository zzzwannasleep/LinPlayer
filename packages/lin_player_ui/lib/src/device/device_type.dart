import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DeviceType {
  static const MethodChannel _channel = MethodChannel('linplayer/device');

  static bool _initialized = false;
  static bool _isTv = false;

  static bool get isTv => _isTv;

  static Future<String?> primaryAbi() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final v = await _channel.invokeMethod<String>('primaryAbi');
      return (v ?? '').trim().isEmpty ? null : v!.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> setExecutable(String path) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    final p = path.trim();
    if (p.isEmpty) return false;
    try {
      final ok =
          await _channel.invokeMethod<bool>('setExecutable', {'path': p});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> nativeLibraryDir() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final v = await _channel.invokeMethod<String>('nativeLibraryDir');
      return (v ?? '').trim().isEmpty ? null : v!.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> setHttpProxy({
    required String host,
    required int port,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    final h = host.trim();
    if (h.isEmpty) return false;
    if (port <= 0 || port > 65535) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setHttpProxy',
        {'host': h, 'port': port},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> clearHttpProxy() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setHttpProxy',
        {'host': '', 'port': 0},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> batteryLevel() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

    try {
      final v = await _channel.invokeMethod<int>('batteryLevel');
      if (v == null) return null;
      if (v < 0 || v > 100) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      final result = await _channel.invokeMethod<bool>('isAndroidTv');
      _isTv = result ?? false;
    } catch (_) {
      _isTv = false;
    }
  }
}
