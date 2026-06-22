import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// 颜色提取工具类
///
/// 取色跟随用户当前主题明暗：
/// - 深色模式 → 取「深色系」背景（低明度），前景走浅色字；
/// - 浅色模式 → 取「浅色系」背景（高明度、低饱和），前景走深色字。
///
/// 背景明暗交给调用方的 [ColorExtractor.extractFromUrl] `brightness` 决定，
/// 文字明暗则由 DynamicBackground 依据背景真实亮度反向推导（深底浅字/浅底深字）。
class ColorExtractor {
  static const int _maxCacheEntries = 96;
  static final LinkedHashMap<String, ExtractedColors> _cache =
      LinkedHashMap<String, ExtractedColors>();
  static final Map<String, Future<ExtractedColors>> _pending =
      <String, Future<ExtractedColors>>{};

  static String _cacheKey(String imageUrl, Brightness brightness) =>
      '${brightness.index}|$imageUrl';

  /// 从图片URL提取主色调与背景色（按 [brightness] 取深色系/浅色系）。
  /// 降低采样分辨率以减少主线程阻塞。
  static Future<ExtractedColors> extractFromUrl(
    String imageUrl, {
    Brightness brightness = Brightness.dark,
  }) async {
    final key = _cacheKey(imageUrl, brightness);
    final cached = _readCache(key);
    if (cached != null) {
      return cached;
    }

    final pending = _pending[key];
    if (pending != null) {
      return pending;
    }

    final future = _extract(imageUrl, brightness);
    _pending[key] = future;
    return future.whenComplete(() {
      _pending.remove(key);
    });
  }

  static Future<ExtractedColors> _extract(
    String imageUrl,
    Brightness brightness,
  ) async {
    final key = _cacheKey(imageUrl, brightness);
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(imageUrl),
        size: const Size(100, 100),
        maximumColorCount: 16,
        filters: [],
      );

      // 收集所有颜色样本
      final colors = palette.colors.toList();

      if (colors.isEmpty) {
        return _writeCache(key, ExtractedColors.fallback(brightness));
      }

      // 计算加权平均颜色（基于像素占比）
      final avgColor = _computeWeightedAverage(colors, palette);

      // 找到最具代表性的鲜艳颜色（用于强调色）
      final vibrant = palette.vibrantColor?.color ?? avgColor;

      final bool isLight = brightness == Brightness.light;
      final Color safeBackground;
      final Color gradientStart;

      if (isLight) {
        // 浅色模式：同色相的「浅色系」背景——高明度、压低饱和，保证深色文字可读。
        final base =
            HSLColor.fromColor(palette.lightMutedColor?.color ?? avgColor);
        safeBackground = base
            .withSaturation((base.saturation * 0.55).clamp(0.0, 0.45))
            .withLightness(0.90)
            .toColor();
        final g = HSLColor.fromColor(avgColor);
        gradientStart = g
            .withSaturation((g.saturation * 0.5).clamp(0.0, 0.4))
            .withLightness(0.82)
            .toColor()
            .withValues(alpha: 0.7);
      } else {
        // 深色模式：「深色系」背景——足够暗以显示白色文字。
        final darkMuted =
            palette.darkMutedColor?.color ?? _darken(avgColor, 0.5);
        final bgHsl = HSLColor.fromColor(darkMuted);
        safeBackground = bgHsl.lightness < 0.15
            ? darkMuted
            : bgHsl
                .withSaturation(bgHsl.saturation * 0.7)
                .withLightness(0.12)
                .toColor();
        gradientStart = _mute(avgColor, 0.2).withValues(alpha: 0.7);
      }

      return _writeCache(
        key,
        ExtractedColors(
          primary: vibrant,
          background: safeBackground,
          gradientStart: gradientStart,
          gradientEnd: safeBackground,
        ),
      );
    } catch (e) {
      return _writeCache(key, ExtractedColors.fallback(brightness));
    }
  }

  static ExtractedColors? _readCache(String key) {
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
    }
    return cached;
  }

  static ExtractedColors _writeCache(String key, ExtractedColors colors) {
    _cache.remove(key);
    _cache[key] = colors;
    if (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    return colors;
  }

  /// 计算颜色的加权平均值
  static Color _computeWeightedAverage(List<Color> colors, PaletteGenerator palette) {
    if (colors.isEmpty) return Colors.black;

    double r = 0, g = 0, b = 0;
    double totalWeight = 0;

    for (final color in colors) {
      // 计算颜色的"重要性"权重：鲜艳且不太暗的颜色权重更高
      final hsl = HSLColor.fromColor(color);
      final weight = (hsl.saturation * 0.5 + 0.5) * (hsl.lightness.clamp(0.1, 0.9));

      r += color.r * weight;
      g += color.g * weight;
      b += color.b * weight;
      totalWeight += weight;
    }

    if (totalWeight == 0) return colors.first;

    return Color.fromARGB(
      255,
      (r / totalWeight).round().clamp(0, 255),
      (g / totalWeight).round().clamp(0, 255),
      (b / totalWeight).round().clamp(0, 255),
    );
  }

  /// 加深颜色
  static Color _darken(Color color, [double amount = 0.4]) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// 降低饱和度
  static Color _mute(Color color, [double amount = 0.3]) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation((hsl.saturation - amount).clamp(0.0, 1.0))
        .toColor();
  }
}

/// 提取的颜色集合
class ExtractedColors {
  final Color primary;
  final Color background;
  final Color gradientStart;
  final Color gradientEnd;

  const ExtractedColors({
    required this.primary,
    required this.background,
    required this.gradientStart,
    required this.gradientEnd,
  });

  /// 取色失败的兜底色：按明暗给浅/深底，避免浅色模式下兜底成黑底。
  factory ExtractedColors.fallback([Brightness brightness = Brightness.dark]) {
    if (brightness == Brightness.light) {
      return const ExtractedColors(
        primary: Color(0xFF5B8DEF),
        background: Color(0xFFF2F3F5),
        gradientStart: Color(0x99F2F3F5),
        gradientEnd: Color(0xFFF2F3F5),
      );
    }
    return const ExtractedColors(
      primary: Color(0xFF5B8DEF),
      background: Color(0xFF121212),
      gradientStart: Color(0x99121212),
      gradientEnd: Color(0xFF121212),
    );
  }
}
