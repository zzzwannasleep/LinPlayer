import 'dart:convert';

enum DanmakuType {
  scrolling,
  top,
  bottom,
}

class DanmakuItem {
  final Duration time;
  final String text;
  final DanmakuType type;

  const DanmakuItem({
    required this.time,
    required this.text,
    required this.type,
  });
}

class DanmakuSource {
  final String name;
  final List<DanmakuItem> items;
  const DanmakuSource({required this.name, required this.items});
}

class DanmakuParser {
  static final RegExp _biliDanmakuRe = RegExp(
    r'<d\s+p="([^"]+)">([\s\S]*?)</d>',
    caseSensitive: false,
  );

  static DanmakuType _typeFromMode(int mode) {
    // Bilibili: 1/2/3 scrolling, 4 bottom, 5 top, 6 reversed (treat as scroll)
    // Keep it simple: only map top/bottom explicitly.
    switch (mode) {
      case 4:
        return DanmakuType.bottom;
      case 5:
        return DanmakuType.top;
      default:
        return DanmakuType.scrolling;
    }
  }

  static List<DanmakuItem> parseBilibiliXml(String xml) {
    final items = <DanmakuItem>[];
    for (final m in _biliDanmakuRe.allMatches(xml)) {
      final p = m.group(1);
      final rawText = m.group(2);
      if (p == null || rawText == null) continue;
      final parts = p.split(',');
      if (parts.isEmpty) continue;
      final sec = double.tryParse(parts.first);
      if (sec == null || sec.isNaN || sec.isInfinite || sec < 0) continue;
      final mode = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
      final text = _unescapeXmlText(rawText).trim();
      if (text.isEmpty) continue;
      items.add(
        DanmakuItem(
          time: Duration(milliseconds: (sec * 1000).round()),
          text: text,
          type: _typeFromMode(mode),
        ),
      );
    }
    items.sort((a, b) => a.time.compareTo(b.time));
    return items;
  }

  static List<DanmakuItem> parseDandanplayComments(
    List<Map<String, dynamic>> comments, {
    double shiftSeconds = 0,
  }) {
    final items = <DanmakuItem>[];
    for (final c in comments) {
      final p = c['p'] as String?;
      final rawText = c['m'] as String?;
      if (p == null || rawText == null) continue;
      final parts = p.split(',');
      if (parts.isEmpty) continue;
      final sec = double.tryParse(parts.first);
      if (sec == null || sec.isNaN || sec.isInfinite) continue;
      final mode = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
      final shifted = sec + shiftSeconds;
      if (shifted < 0) continue;
      final text = _unescapeXmlText(rawText).trim();
      if (text.isEmpty) continue;
      items.add(
        DanmakuItem(
          time: Duration(milliseconds: (shifted * 1000).round()),
          text: text,
          type: _typeFromMode(mode),
        ),
      );
    }
    items.sort((a, b) => a.time.compareTo(b.time));
    return items;
  }

  static int lowerBoundByTime(List<DanmakuItem> items, Duration time) {
    var lo = 0;
    var hi = items.length;
    while (lo < hi) {
      final mid = lo + ((hi - lo) >> 1);
      if (items[mid].time < time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static String _unescapeXmlText(String v) {
    // Keep this minimal: common XML/HTML entities used in danmaku files.
    return v
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&#34;', '"')
        .replaceAllMapped(RegExp(r'&#(\\d+);'), (m) {
      final n = int.tryParse(m.group(1) ?? '');
      if (n == null) return m.group(0) ?? '';
      return String.fromCharCode(n);
    }).replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final n = int.tryParse(m.group(1) ?? '', radix: 16);
      if (n == null) return m.group(0) ?? '';
      return String.fromCharCode(n);
    });
  }

  static String decodeBytes(List<int> bytes) {
    // Try UTF-8 first; fall back to Latin1 to avoid crashes on weird encodings.
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }
}
