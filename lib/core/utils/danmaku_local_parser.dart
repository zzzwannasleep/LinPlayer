import 'dart:convert';

import 'package:xml/xml.dart';

import '../api/api_interfaces.dart';

/// 本地弹幕文件解析：把用户导入的 .xml / .json / .ass 文件转成 [DanmakuItem]。
///
/// - **.xml**：B站 / 弹弹Play 导出的 `<d p="time,mode,fontsize,color,...">text</d>` 格式。
/// - **.json**：弹弹Play 评论 JSON（`{comments:[{p:"time,mode,color,uid", m:"text"}]}`，
///   或裸数组 / `{data:[...]}`）。
/// - **.ass**：Aegisub 字幕版弹幕，按 Dialogue 行尽力解析（时间 + 文本 +
///   `\an8`顶/`\an2`底 位置 + `\c` 颜色），位置/颜色取不到时退化为白色滚动。
///
/// 解析失败抛 [FormatException]，调用方据此提示用户。
class DanmakuLocalParser {
  /// 支持的扩展名（不含点）。
  static const supportedExtensions = ['xml', 'json', 'ass', 'ssa'];

  /// 按文件名后缀分派解析。[content] 为文件文本内容。
  static List<DanmakuItem> parse(String fileName, String content) {
    final ext = _ext(fileName);
    switch (ext) {
      case 'xml':
        return parseXml(content);
      case 'json':
        return parseJson(content);
      case 'ass':
      case 'ssa':
        return parseAss(content);
      default:
        // 未知后缀：按内容猜测（XML / JSON）。
        final trimmed = content.trimLeft();
        if (trimmed.startsWith('<')) return parseXml(content);
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
          return parseJson(content);
        }
        throw const FormatException('无法识别的弹幕文件格式');
    }
  }

  static String _ext(String fileName) {
    final i = fileName.lastIndexOf('.');
    if (i < 0 || i == fileName.length - 1) return '';
    return fileName.substring(i + 1).toLowerCase();
  }

  // ============ XML（B站 / 弹弹Play 导出）============

  /// `<d p="time,mode,fontsize,color,timestamp,pool,senderhash,rowid">text</d>`
  static List<DanmakuItem> parseXml(String content) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(content);
    } catch (e) {
      throw FormatException('XML 解析失败: $e');
    }
    final out = <DanmakuItem>[];
    for (final d in doc.findAllElements('d')) {
      final p = d.getAttribute('p');
      final text = d.innerText.trim();
      if (text.isEmpty) continue;
      final f = (p ?? '').split(',');
      final time = f.isNotEmpty ? (double.tryParse(f[0]) ?? 0) : 0;
      final mode = f.length > 1 ? (int.tryParse(f[1]) ?? 1) : 1;
      // B站 p：index2=字号, index3=颜色(十进制)。
      final color = f.length > 3 ? (int.tryParse(f[3]) ?? 16777215) : 16777215;
      out.add(DanmakuItem(
        time: time.toDouble(),
        text: text,
        type: _normalizeMode(mode),
        color: color,
        source: '本地导入',
      ));
    }
    if (out.isEmpty) {
      throw const FormatException('XML 中未找到弹幕（<d> 节点为空）');
    }
    return out;
  }

  // ============ JSON（弹弹Play 评论）============

  static List<DanmakuItem> parseJson(String content) {
    final dynamic data;
    try {
      data = jsonDecode(content);
    } catch (e) {
      throw FormatException('JSON 解析失败: $e');
    }
    List<dynamic>? comments;
    if (data is List) {
      comments = data;
    } else if (data is Map) {
      comments = (data['comments'] ?? data['data'] ?? data['danmuku']) as List?;
    }
    if (comments == null) {
      throw const FormatException('JSON 中未找到弹幕列表（comments/data）');
    }
    final out = <DanmakuItem>[];
    for (final c in comments) {
      if (c is! Map) continue;
      // 弹弹Play p：time,mode,color,uid（4 段，无字号）。
      final p = (c['p'] as String?)?.split(',') ?? const [];
      final text = (c['m'] ?? c['text'] ?? '').toString();
      if (text.isEmpty) continue;
      final time = p.isNotEmpty ? (double.tryParse(p[0]) ?? 0) : 0;
      final mode = p.length > 1 ? (int.tryParse(p[1]) ?? 1) : 1;
      final color = p.length > 2 ? (int.tryParse(p[2]) ?? 16777215) : 16777215;
      out.add(DanmakuItem(
        time: time.toDouble(),
        text: text,
        type: _normalizeMode(mode),
        color: color,
        source: '本地导入',
        cid: c['cid']?.toString(),
        userId: p.length > 3 ? p[3] : null,
      ));
    }
    if (out.isEmpty) {
      throw const FormatException('JSON 中没有可用弹幕');
    }
    return out;
  }

  // ============ ASS / SSA（字幕版弹幕，尽力解析）============

  static final _assColorRe = RegExp(r'\\c&H([0-9A-Fa-f]{6,8})&');
  static final _assOverrideRe = RegExp(r'\{[^}]*\}');

  static List<DanmakuItem> parseAss(String content) {
    final out = <DanmakuItem>[];
    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trim();
      if (!line.startsWith('Dialogue:')) continue;
      // Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
      final rest = line.substring('Dialogue:'.length);
      final parts = rest.split(',');
      if (parts.length < 10) continue;
      final start = _parseAssTime(parts[1].trim());
      if (start == null) continue;
      // 文本是第 10 段起的全部（文本里可能含逗号，故 join 回来）。
      final rawText = parts.sublist(9).join(',');
      // 位置：\an8=顶, \an2/\an1/\an3=底，其余视为滚动。
      int type = 1;
      if (rawText.contains(r'\an8') ||
          rawText.contains(r'\a6') ||
          rawText.contains(r'\a7')) {
        type = 5;
      } else if (rawText.contains(r'\an2') ||
          rawText.contains(r'\an1') ||
          rawText.contains(r'\an3')) {
        type = 4;
      }
      // 颜色：取第一个 \c&Hbbggrr&（ASS 是 BGR）。
      int color = 16777215;
      final m = _assColorRe.firstMatch(rawText);
      if (m != null) {
        final hex = m.group(1)!;
        final bgr = hex.substring(hex.length - 6);
        final b = int.parse(bgr.substring(0, 2), radix: 16);
        final g = int.parse(bgr.substring(2, 4), radix: 16);
        final r = int.parse(bgr.substring(4, 6), radix: 16);
        color = (r << 16) | (g << 8) | b;
      }
      final text =
          rawText.replaceAll(_assOverrideRe, '').replaceAll(r'\N', ' ').trim();
      if (text.isEmpty) continue;
      out.add(DanmakuItem(
        time: start,
        text: text,
        type: type,
        color: color,
        source: '本地导入',
      ));
    }
    if (out.isEmpty) {
      throw const FormatException('ASS 中未解析到弹幕（Dialogue 行为空）');
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  /// `H:MM:SS.cc` → 秒。
  static double? _parseAssTime(String s) {
    final m = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?$').firstMatch(s);
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    final sec = int.parse(m.group(3)!);
    final cs = m.group(4);
    final frac = cs == null ? 0.0 : double.parse('0.$cs');
    return h * 3600 + min * 60 + sec + frac;
  }

  /// 把各家弹幕 mode 归一到弹弹Play 标准：1=滚动, 4=底部, 5=顶部。
  static int _normalizeMode(int mode) {
    switch (mode) {
      case 4:
        return 4; // 底部
      case 5:
        return 5; // 顶部
      case 1:
      case 2:
      case 3:
      case 6:
      default:
        return 1; // 滚动（含逆向，渲染层按滚动处理）
    }
  }
}
