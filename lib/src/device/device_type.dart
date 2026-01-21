import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DeviceType {
  static const MethodChannel _channel = MethodChannel('linplayer/device');

  static bool _initialized = false;
  static bool _isTv = false;

  static bool get isTv => _isTv;

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
