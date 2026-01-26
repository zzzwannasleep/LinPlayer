import 'dart:math' as math;

import 'danmaku.dart';

class DanmakuTextFilter {
  DanmakuTextFilter._(this._rules);

  final List<_Rule> _rules;

  factory DanmakuTextFilter.fromText(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n');
    final rules = <_Rule>[];
    for (final line in normalized.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.length >= 2 && t.startsWith('/') && t.endsWith('/')) {
        final pattern = t.substring(1, t.length - 1);
        if (pattern.trim().isEmpty) continue;
        try {
          rules.add(_RegexRule(RegExp(pattern)));
        } catch (_) {
          // Ignore invalid regex.
        }
      } else {
        rules.add(_SubstringRule(t.toLowerCase()));
      }
    }
    return DanmakuTextFilter._(rules);
  }

  bool get isEmpty => _rules.isEmpty;

  bool matches(String text) {
    if (_rules.isEmpty) return false;
    final lower = text.toLowerCase();
    for (final r in _rules) {
      if (r.matches(text, lower)) return true;
    }
    return false;
  }
}

abstract class _Rule {
  bool matches(String original, String lower);
}

class _SubstringRule implements _Rule {
  _SubstringRule(this.needleLower);

  final String needleLower;

  @override
  bool matches(String original, String lower) => lower.contains(needleLower);
}

class _RegexRule implements _Rule {
  _RegexRule(this.re);

  final RegExp re;

  @override
  bool matches(String original, String lower) => re.hasMatch(original);
}

List<DanmakuItem> mergeDuplicateDanmakuItems(
  List<DanmakuItem> items, {
  Duration threshold = const Duration(milliseconds: 250),
}) {
  if (items.isEmpty) return items;
  final merged = <DanmakuItem>[];
  DanmakuItem? prev;
  for (final item in items) {
    if (prev != null &&
        item.type == prev.type &&
        item.text == prev.text &&
        (item.time - prev.time).abs() <= threshold) {
      continue;
    }
    merged.add(item);
    prev = item;
  }
  return merged;
}

List<DanmakuItem> processDanmakuItems(
  List<DanmakuItem> items, {
  required String blockWords,
  required bool mergeDuplicates,
}) {
  var out = items;

  final filter = DanmakuTextFilter.fromText(blockWords);
  if (!filter.isEmpty) {
    out = out.where((e) => !filter.matches(e.text)).toList(growable: false);
  }

  if (mergeDuplicates) {
    out = mergeDuplicateDanmakuItems(out);
  }

  return out;
}

List<DanmakuSource> processDanmakuSources(
  List<DanmakuSource> sources, {
  required String blockWords,
  required bool mergeDuplicates,
}) {
  if (sources.isEmpty) return sources;
  return sources
      .map(
        (s) => DanmakuSource(
          name: s.name,
          items: processDanmakuItems(
            s.items,
            blockWords: blockWords,
            mergeDuplicates: mergeDuplicates,
          ),
        ),
      )
      .where((s) => s.items.isNotEmpty)
      .toList(growable: false);
}

List<double> buildDanmakuHeatmap(
  List<DanmakuItem> items, {
  required Duration duration,
  int bins = 80,
}) {
  final totalMs = duration.inMilliseconds;
  if (items.isEmpty || totalMs <= 0 || bins <= 0) return const [];

  final counts = List<int>.filled(bins, 0, growable: false);
  for (final item in items) {
    final ms = item.time.inMilliseconds;
    if (ms < 0) continue;
    var idx = ((ms / totalMs) * bins).floor();
    if (idx < 0) continue;
    if (idx >= bins) idx = bins - 1;
    counts[idx]++;
  }

  var maxCount = 0;
  for (final c in counts) {
    if (c > maxCount) maxCount = c;
  }
  if (maxCount <= 0) return List<double>.filled(bins, 0, growable: false);

  return counts
      .map((c) => math.sqrt(c / maxCount).clamp(0.0, 1.0).toDouble())
      .toList(growable: false);
}
