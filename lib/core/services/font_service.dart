import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  /// 把用户选择的字体复制进应用持久目录，返回稳定路径。
  ///
  /// 关键修复：FilePicker 在移动端返回的是缓存临时路径（…/cache/file_picker/…），
  /// 系统随时可能清理 → 重启后字体文件不存在 → 字体「失效」。复制到
  /// appSupport/fonts/ 后路径稳定、跨重启可用。复制失败则回退原路径。
  static Future<String> _persistFontFile(String srcPath,
      {required bool isApp}) async {
    final src = File(srcPath);
    final dir = await getApplicationSupportDirectory();
    final fontsDir = Directory(p.join(dir.path, 'fonts'));
    if (!fontsDir.existsSync()) {
      fontsDir.createSync(recursive: true);
    }
    final ext = p.extension(srcPath).toLowerCase();
    final destName = '${isApp ? 'app_font' : 'danmaku_font'}'
        '${ext.isEmpty ? '.ttf' : ext}';
    final destPath = p.join(fontsDir.path, destName);
    // 已经是目标文件（用户重选同一持久文件）就不必复制。
    if (p.equals(src.absolute.path, destPath)) return destPath;
    final dest = File(destPath);
    if (dest.existsSync()) dest.deleteSync();
    await src.copy(destPath);
    return destPath;
  }

  /// 导入并持久化 App 全局字体。成功返回最终持久化路径，失败返回 null。
  static Future<String?> setAppFont(String path) async {
    final effective = await _resolvePersistentPath(path, isApp: true);
    final ok = await _loadFromPath(effective, appFontFamily, isApp: true);
    if (ok) {
      await AppPreferencesStore.instance.setString(appFontPathKey, effective);
      return effective;
    }
    return null;
  }

  /// 导入并持久化弹幕字体。成功返回最终持久化路径，失败返回 null。
  static Future<String?> setDanmakuFont(String path) async {
    final effective = await _resolvePersistentPath(path, isApp: false);
    final ok = await _loadFromPath(effective, danmakuFontFamily, isApp: false);
    if (ok) {
      await AppPreferencesStore.instance
          .setString(danmakuFontPathKey, effective);
      return effective;
    }
    return null;
  }

  static Future<String> _resolvePersistentPath(String path,
      {required bool isApp}) async {
    try {
      return await _persistFontFile(path, isApp: isApp);
    } catch (e, st) {
      AppLogger()
          .eWithStack('FontService', '字体持久化失败，回退原路径: $path', e, st);
      return path;
    }
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
