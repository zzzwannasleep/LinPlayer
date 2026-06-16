import 'dart:io';

/// 一条字幕对白（归一化后的中间表示）。
///
/// 翻译管线统一以 [SubtitleCue] 列表为中心：解析阶段把 SRT/ASS/VTT 归一成 cue，
/// 翻译阶段填充 [translatedText]，序列化阶段再写回 SRT。
class SubtitleCue {
  SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
    this.translatedText,
  });

  final Duration start;
  final Duration end;

  /// 原文（多行以 `\n` 连接，已去除 ASS 覆盖标签）。
  final String text;

  /// 译文，翻译完成后填充。
  String? translatedText;

  SubtitleCue copyWith({String? translatedText}) => SubtitleCue(
        start: start,
        end: end,
        text: text,
        translatedText: translatedText ?? this.translatedText,
      );
}

/// 双语字幕排版方式。
enum BilingualLayout {
  /// 仅译文。
  translatedOnly,

  /// 译文在上，原文在下。
  translatedFirst,

  /// 原文在上，译文在下。
  originalFirst,
}

/// 字幕文档：负责把各格式解析成 [SubtitleCue]，并序列化成 SRT。
class SubtitleDocument {
  SubtitleDocument(this.cues);

  final List<SubtitleCue> cues;

  bool get isEmpty => cues.isEmpty;
  bool get isNotEmpty => cues.isNotEmpty;

  /// 从文件解析；按扩展名选择解析器，未知扩展名时按内容嗅探。
  static Future<SubtitleDocument> parseFile(String path) async {
    final content = await File(path).readAsString();
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    return parseString(content, ext: ext);
  }

  static SubtitleDocument parseString(String content, {String ext = ''}) {
    switch (ext) {
      case 'srt':
        return SubtitleDocument(_parseSrt(content));
      case 'vtt':
      case 'webvtt':
        return SubtitleDocument(_parseVtt(content));
      case 'ass':
      case 'ssa':
        return SubtitleDocument(_parseAss(content));
      default:
        // 内容嗅探兜底。
        final trimmed = content.trimLeft();
        if (trimmed.startsWith('[Script Info]') ||
            trimmed.contains('[Events]')) {
          return SubtitleDocument(_parseAss(content));
        }
        if (trimmed.startsWith('WEBVTT')) {
          return SubtitleDocument(_parseVtt(content));
        }
        return SubtitleDocument(_parseSrt(content));
    }
  }

  /// 序列化为 SRT。[layout] 控制是否带原文双语。
  String toSrt({BilingualLayout layout = BilingualLayout.translatedOnly}) {
    final buffer = StringBuffer();
    var index = 1;
    for (final cue in cues) {
      final body = _composeBody(cue, layout);
      if (body.trim().isEmpty) continue;
      buffer
        ..writeln(index)
        ..writeln('${_fmtSrt(cue.start)} --> ${_fmtSrt(cue.end)}')
        ..writeln(body)
        ..writeln();
      index++;
    }
    return buffer.toString();
  }

  static String _composeBody(SubtitleCue cue, BilingualLayout layout) {
    final translated = cue.translatedText?.trim() ?? '';
    final original = cue.text.trim();
    if (translated.isEmpty) return original;
    switch (layout) {
      case BilingualLayout.translatedOnly:
        return translated;
      case BilingualLayout.translatedFirst:
        return '$translated\n$original';
      case BilingualLayout.originalFirst:
        return '$original\n$translated';
    }
  }

  // ============ SRT 解析 ============
  static final _srtTime = RegExp(
    r'(\d{1,2}):(\d{2}):(\d{2})[,\.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,\.](\d{1,3})',
  );

  static List<SubtitleCue> _parseSrt(String content) {
    final cues = <SubtitleCue>[];
    final blocks = content.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      var timeLineIndex = -1;
      for (var i = 0; i < lines.length && i < 2; i++) {
        if (_srtTime.hasMatch(lines[i])) {
          timeLineIndex = i;
          break;
        }
      }
      if (timeLineIndex < 0) continue;
      final m = _srtTime.firstMatch(lines[timeLineIndex])!;
      final start = _toDuration(m, 1);
      final end = _toDuration(m, 5);
      final text = lines.sublist(timeLineIndex + 1).join('\n').trim();
      if (text.isEmpty) continue;
      cues.add(SubtitleCue(start: start, end: end, text: _stripTags(text)));
    }
    return cues;
  }

  // ============ VTT 解析 ============
  static List<SubtitleCue> _parseVtt(String content) {
    final cues = <SubtitleCue>[];
    final blocks = content.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      var timeLineIndex = -1;
      for (var i = 0; i < lines.length; i++) {
        if (_srtTime.hasMatch(lines[i])) {
          timeLineIndex = i;
          break;
        }
      }
      if (timeLineIndex < 0) continue;
      final m = _srtTime.firstMatch(lines[timeLineIndex])!;
      final start = _toDuration(m, 1);
      final end = _toDuration(m, 5);
      final text = lines.sublist(timeLineIndex + 1).join('\n').trim();
      if (text.isEmpty) continue;
      // 去掉 VTT 内联标签 <c>、<v Name> 等。
      cues.add(SubtitleCue(
        start: start,
        end: end,
        text: _stripTags(text.replaceAll(RegExp(r'<[^>]+>'), '')),
      ));
    }
    return cues;
  }

  // ============ ASS/SSA 解析 ============
  static List<SubtitleCue> _parseAss(String content) {
    final cues = <SubtitleCue>[];
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    var inEvents = false;
    List<String> format = const ['Layer', 'Start', 'End', 'Style', 'Name',
      'MarginL', 'MarginR', 'MarginV', 'Effect', 'Text'];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inEvents = line == '[Events]';
        continue;
      }
      if (!inEvents) continue;
      if (line.startsWith('Format:')) {
        format = line
            .substring('Format:'.length)
            .split(',')
            .map((e) => e.trim())
            .toList();
        continue;
      }
      if (!line.startsWith('Dialogue:')) continue;
      final body = line.substring('Dialogue:'.length).trimLeft();
      final fields = _splitAssFields(body, format.length);
      final startIdx = format.indexOf('Start');
      final endIdx = format.indexOf('End');
      final textIdx = format.indexOf('Text');
      if (startIdx < 0 || endIdx < 0 || textIdx < 0) continue;
      if (fields.length <= textIdx) continue;
      final start = _parseAssTime(fields[startIdx].trim());
      final end = _parseAssTime(fields[endIdx].trim());
      final text = _stripAss(fields[textIdx]);
      if (text.isEmpty) continue;
      cues.add(SubtitleCue(start: start, end: end, text: text));
    }
    return cues;
  }

  static List<String> _splitAssFields(String input, int expected) {
    if (expected <= 1) return [input];
    final result = <String>[];
    var start = 0;
    var commas = 0;
    for (var i = 0; i < input.length; i++) {
      if (input.codeUnitAt(i) != 44) continue; // ','
      if (commas >= expected - 1) break;
      result.add(input.substring(start, i));
      start = i + 1;
      commas++;
    }
    result.add(input.substring(start));
    return result;
  }

  static String _stripAss(String text) {
    var r = text;
    r = r.replaceAll(RegExp(r'\\N', caseSensitive: false), '\n');
    r = r.replaceAll(RegExp(r'\{[^}]*\}'), ''); // 覆盖标签
    return _stripTags(r).trim();
  }

  static String _stripTags(String text) => text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\n');

  // ============ 时间工具 ============
  static Duration _toDuration(RegExpMatch m, int g) {
    final h = int.parse(m.group(g)!);
    final min = int.parse(m.group(g + 1)!);
    final s = int.parse(m.group(g + 2)!);
    final msRaw = m.group(g + 3)!;
    final ms = int.parse(msRaw.padRight(3, '0').substring(0, 3));
    return Duration(hours: h, minutes: min, seconds: s, milliseconds: ms);
  }

  static Duration _parseAssTime(String t) {
    // H:MM:SS.cc
    final parts = t.split(':');
    if (parts.length != 3) return Duration.zero;
    final h = int.tryParse(parts[0]) ?? 0;
    final min = int.tryParse(parts[1]) ?? 0;
    final secParts = parts[2].split('.');
    final s = int.tryParse(secParts[0]) ?? 0;
    final cs = secParts.length > 1
        ? int.tryParse(secParts[1].padRight(2, '0').substring(0, 2)) ?? 0
        : 0;
    return Duration(hours: h, minutes: min, seconds: s, milliseconds: cs * 10);
  }

  static String _fmtSrt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final ms = d.inMilliseconds % 1000;
    String p2(int n) => n.toString().padLeft(2, '0');
    String p3(int n) => n.toString().padLeft(3, '0');
    return '${p2(h)}:${p2(m)}:${p2(s)},${p3(ms)}';
  }
}
