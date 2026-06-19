import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;

import '../providers/app_preferences.dart';
import 'app_logger.dart';

/// 自定义字体（App 全局字体 + 弹幕字体）的运行时加载与持久化。
///
/// 用户可导入本地 ttf/otf 字体文件：
/// - App 全局字体：应用到三端 ThemeData 的 fontFamily。
/// - 弹幕字体：应用到弹幕渲染（[DanmakuPainter]）。
///
/// FontLoader 注册的字体不跨进程，故每次启动需按持久化路径重新加载
/// （见 [initialize]，在偏好初始化后、构建 UI 前调用）。已注册的字体无法卸载，
/// 「清除」仅置标志位 + 删除持久化路径，重启后即不再加载。
class FontService {
  FontService._();

  /// App 全局自定义字体家族名（加载成功后用此名引用）。
  static const String appFontFamily = 'LinPlayerUserAppFont';

  /// 弹幕自定义字体家族名。
  static const String danmakuFontFamily = 'LinPlayerUserDanmakuFont';

  static const String appFontPathKey = 'linplayer_custom_app_font_path';
  static const String danmakuFontPathKey = 'linplayer_custom_danmaku_font_path';

  static bool _appFontLoaded = false;
  static bool _danmakuFontLoaded = false;

  static bool get hasAppFont => _appFontLoaded;
  static bool get hasDanmakuFont => _danmakuFontLoaded;

  /// 启动时按持久化路径重新加载字体。
  static Future<void> initialize() async {
    final prefs = AppPreferencesStore.instance;
    await _loadFromPath(prefs.getString(appFontPathKey), appFontFamily,
        isApp: true);
    await _loadFromPath(prefs.getString(danmakuFontPathKey), danmakuFontFamily,
        isApp: false);
  }

  static Future<bool> _loadFromPath(String? path, String family,
      {required bool isApp}) async {
    if (path == null || path.trim().isEmpty) return false;
    final file = File(path);
    if (!file.existsSync()) {
      AppLogger().w('FontService', '字体文件不存在，跳过加载: $path');
      return false;
    }
    try {
      final Uint8List bytes = await file.readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future<ByteData>.value(bytes.buffer.asByteData()));
      await loader.load();
      if (isApp) {
        _appFontLoaded = true;
      } else {
        _danmakuFontLoaded = true;
      }
      AppLogger().i('FontService', '字体加载成功: $family <- $path');
      return true;
    } catch (e, st) {
      AppLogger().eWithStack('FontService', '字体加载失败: $path', e, st);
      return false;
    }
  }

  /// 导入并持久化 App 全局字体。成功返回 true。
  static Future<bool> setAppFont(String path) async {
    final ok = await _loadFromPath(path, appFontFamily, isApp: true);
    if (ok) {
      await AppPreferencesStore.instance.setString(appFontPathKey, path);
    }
    return ok;
  }

  /// 导入并持久化弹幕字体。成功返回 true。
  static Future<bool> setDanmakuFont(String path) async {
    final ok = await _loadFromPath(path, danmakuFontFamily, isApp: false);
    if (ok) {
      await AppPreferencesStore.instance.setString(danmakuFontPathKey, path);
    }
    return ok;
  }

  static Future<void> clearAppFont() async {
    _appFontLoaded = false;
    await AppPreferencesStore.instance.remove(appFontPathKey);
  }

  static Future<void> clearDanmakuFont() async {
    _danmakuFontLoaded = false;
    await AppPreferencesStore.instance.remove(danmakuFontPathKey);
  }

  static String appFontPath() =>
      AppPreferencesStore.instance.getString(appFontPathKey) ?? '';

  static String danmakuFontPath() =>
      AppPreferencesStore.instance.getString(danmakuFontPathKey) ?? '';
}
