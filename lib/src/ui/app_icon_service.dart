import 'dart:io';

import 'package:flutter/services.dart';

class AppIconService {
  static const MethodChannel _channel = MethodChannel('linplayer/app_icon');

  static bool get isSupported => Platform.isAndroid;

  static Future<String?> getCurrentIconId() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('getIcon');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> setIconId(String id) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setIcon', {'id': id});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}

