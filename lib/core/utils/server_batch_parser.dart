/// 批量解析「分享文本」。
///
/// 机场/Emby 分享出来的开通信息通常长这样（可能一次包含多个账号块）：
///
///     ▎创建用户成功🎉
///     · 用户名称 | 南屿
///     · 用户密码 | PKq0Bgca
///     · 安全密码 | 8898（仅发送一次）
///     · 到期时间 | 2026-06-30 23:34:28
///     主线路（可尝试直连）
///     https://iris.niceduck.lol:443
///     海外备用（国际优化 CDN）
///     https://cdn.irisnb.com:443
///     弹幕 API
///     https://justdanmu.irisnb.com/iris-danmu
///
/// 本解析器把这种自由文本结构化成 [ParsedServerBlock] 列表：每个块含用户名/密码、
/// 若干服务器线路、若干弹幕线路。用户通常只需补一个用户名即可（[ParsedServerBlock.username]
/// 解析不到时由 UI 让用户填一次并一键套用到所有块）。
library;

/// 一条带名字的线路（服务器线路或弹幕线路通用）。
class ParsedLine {
  final String name;
  final String url;
  const ParsedLine(this.name, this.url);
}

/// 一个账号块：一台服务器(可能多线路) + 该账号的弹幕线路 + 用户名/密码。
class ParsedServerBlock {
  String? username;
  String? password;
  final List<ParsedLine> lines;
  final List<ParsedLine> danmakuLines;

  ParsedServerBlock({
    this.username,
    this.password,
    List<ParsedLine>? lines,
    List<ParsedLine>? danmakuLines,
  })  : lines = lines ?? <ParsedLine>[],
        danmakuLines = danmakuLines ?? <ParsedLine>[];

  bool get isEmpty => lines.isEmpty && danmakuLines.isEmpty;
}

class ServerBatchParser {
  // 行内「键值」分隔符：| ： :
  static final _kvSameLineUrl =
      RegExp(r'^(.{1,40}?)\s*[\|:：]\s*((?:https?://)\S+)', caseSensitive: false);
  static final _kvField =
      RegExp(r'^([^\|:：]{1,16})\s*[\|:：]\s*(.+)$');
  static final _urlRegex = RegExp(r'https?://[^\s|，,)）；;]+', caseSensitive: false);
  static final _leadingBullets =
      RegExp(r'^[\s·•\-\*▎▍►>《　]+');
  // 行首形如 "创建用户成功" 的块头。
  static final _blockHeader = RegExp(r'创建用户|【\s*服务器\s*】|账号信息|开通成功');

  static const _userKeys = [
    '用户名称', '用户名', '账户名', '账号名', '账户', '账号', '帐号', '用户',
    'username', 'user', 'account', 'name',
  ];
  static const _passKeys = [
    '用户密码', '登录密码', '登陆密码', '密码', 'password', 'passwd', 'pwd', 'pass',
  ];
  // 这些键即便带「密码/时间」字样也不是登录凭据，忽略。
  static const _ignoreKeys = [
    '安全密码', '安全密碼', '到期时间', '到期時間', '过期时间', '有效期', 'expire',
    'expiry', '到期', '剩余', '当前线路', '当前線路',
  ];

  /// 解析整段文本为多个账号块。
  static List<ParsedServerBlock> parse(String text) {
    final blocks = <ParsedServerBlock>[];
    var current = ParsedServerBlock();
    String? pendingLabel;

    void flush() {
      if (!current.isEmpty || current.username != null) {
        blocks.add(current);
      }
      current = ParsedServerBlock();
      pendingLabel = null;
    }

    for (final raw in text.split('\n')) {
      final line = raw.replaceFirst(_leadingBullets, '').trim();
      if (line.isEmpty) continue;

      // 显式块头：开启新块。
      if (_blockHeader.hasMatch(line) && !current.isEmpty) {
        flush();
        continue;
      }

      // ① 同一行「标签: URL」
      final sameLine = _kvSameLineUrl.firstMatch(line);
      if (sameLine != null) {
        final label = sameLine.group(1)!.trim();
        final url = _cleanUrl(sameLine.group(2)!);
        _addUrl(current, label.isEmpty ? pendingLabel : label, url);
        pendingLabel = null;
        continue;
      }

      // ② 行内直接含 URL（标签在上一行）
      final urls = _urlRegex.allMatches(line).map((m) => _cleanUrl(m.group(0)!)).toList();
      if (urls.isNotEmpty) {
        for (final url in urls) {
          _addUrl(current, pendingLabel, url);
        }
        pendingLabel = null;
        continue;
      }

      // ③ 无 URL：键值字段（用户名/密码）或纯标签。
      final kv = _kvField.firstMatch(line);
      if (kv != null) {
        final key = kv.group(1)!.trim().toLowerCase();
        final value = kv.group(2)!.trim();
        if (_matchesAny(key, _ignoreKeys)) {
          continue;
        }
        // 先判密码：「用户密码」同时含「用户」与「密码」字样，必须优先归为密码，
        // 否则会被用户名键的子串匹配误吞。
        if (_matchesAny(key, _passKeys)) {
          current.password ??= _stripNote(value);
          continue;
        }
        if (_matchesAny(key, _userKeys)) {
          // 新用户名 → 若当前块已有内容，开新块。
          if (current.username != null ||
              current.lines.isNotEmpty ||
              current.danmakuLines.isNotEmpty) {
            flush();
          }
          current.username = _stripNote(value);
          continue;
        }
        // 未知键值 → 当作标签（键名）。
        pendingLabel = kv.group(1)!.trim();
        continue;
      }

      // ④ 纯文本行 → 作为下一条 URL 的标签（取最靠近 URL 的一行）。
      pendingLabel = line;
    }
    flush();

    // 去掉完全空的块。
    return blocks.where((b) => !b.isEmpty).toList();
  }

  static void _addUrl(ParsedServerBlock block, String? label, String url) {
    if (url.isEmpty) return;
    final name = (label == null || label.isEmpty) ? _hostOf(url) : _stripNote(label);
    final isDanmaku = _looksDanmaku(label) || _looksDanmaku(url);
    final target = isDanmaku ? block.danmakuLines : block.lines;
    if (target.any((l) => l.url == url)) return; // 去重
    target.add(ParsedLine(name, url));
  }

  static bool _looksDanmaku(String? s) {
    if (s == null) return false;
    final t = s.toLowerCase();
    return t.contains('danmu') || t.contains('danmaku') || t.contains('弹幕');
  }

  static bool _matchesAny(String key, List<String> keys) {
    for (final k in keys) {
      if (key == k.toLowerCase() || key.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  /// 去掉值里的括号备注，如 "8898（仅发送一次）" → "8898"，"南屿 " → "南屿"。
  static String _stripNote(String value) {
    var v = value.trim();
    final paren = RegExp(r'[（(].*$');
    v = v.replaceFirst(paren, '').trim();
    return v;
  }

  static String _cleanUrl(String url) {
    var u = url.trim();
    // 去掉尾部常见标点。
    u = u.replaceFirst(RegExp(r'[，,。；;、)）】\]]+$'), '');
    return u;
  }

  static String _hostOf(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    return '线路';
  }
}
