class ServerShareTextGroup {
  final String password;
  final List<ServerShareTextLine> lines;

  const ServerShareTextGroup({
    required this.password,
    required this.lines,
  });
}

class ServerShareTextLine {
  final String name;
  final String url;

  /// Suggested default selection in UI.
  final bool selectedByDefault;

  const ServerShareTextLine({
    required this.name,
    required this.url,
    required this.selectedByDefault,
  });
}

class ServerShareTextParser {
  static final RegExp _passwordRe =
      RegExp(r'用户密码\s*[:：]\s*([^\s\r\n]+)', multiLine: true);
  static final RegExp _portRe = RegExp(r'端口\s*[:：]\s*(\d{1,5})');
  static final RegExp _urlRe = RegExp(r'https?://[^\s]+', caseSensitive: false);

  static final Set<String> _denyHosts = {
    't.me',
    'telegram.me',
    'telegram.dog',
    'github.com',
    'gitlab.com',
    'gitee.com',
  };

  static List<ServerShareTextGroup> parse(String raw) {
    final text = raw.replaceAll('\r\n', '\n');
    final lines = text.split('\n');

    final groups = <_MutableGroup>[];
    var current = _MutableGroup(password: '');
    String? lastLabel;

    void flushIfNeeded() {
      if (current.entries.isNotEmpty) {
        groups.add(current);
      }
      current = _MutableGroup(password: '');
      lastLabel = null;
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final pwMatch = _passwordRe.firstMatch(line);
      if (pwMatch != null) {
        flushIfNeeded();
        current = _MutableGroup(password: (pwMatch.group(1) ?? '').trim());
        lastLabel = null;
        continue;
      }

      final portMatch = _portRe.firstMatch(line);
      if (portMatch != null) {
        current.globalPort = int.tryParse(portMatch.group(1) ?? '');
        continue;
      }

      final urlMatches = _urlRe.allMatches(line).toList();
      if (urlMatches.isNotEmpty) {
        for (final m in urlMatches) {
          final rawUrl = m.group(0) ?? '';
          final cleanedUrl = _cleanUrlToken(rawUrl);
          final uri = Uri.tryParse(cleanedUrl);
          if (uri == null ||
              (uri.scheme != 'http' && uri.scheme != 'https') ||
              uri.host.trim().isEmpty) {
            continue;
          }

          final before = line.substring(0, m.start).trim();
          final nameFromInline = _stripLabelPunctuation(before);
          final name = nameFromInline.isNotEmpty
              ? nameFromInline
              : (lastLabel ?? '').trim();

          final portAfter = _parsePortAfterUrl(line.substring(m.end));
          final entryPort = uri.hasPort ? uri.port : portAfter;
          current.entries.add(
            _RawEntry(
              name: name,
              uri: uri.replace(query: null, fragment: null),
              hasPortHint: uri.hasPort || portAfter != null,
              port: entryPort,
            ),
          );
        }
        // A label is assumed to only apply to the next URL line.
        lastLabel = null;
        continue;
      }

      if (_isSkippableLabelNoise(line)) continue;
      lastLabel = _stripLabelPunctuation(line);
    }

    if (current.entries.isNotEmpty) {
      groups.add(current);
    }

    return groups.map(_finalizeGroup).where((g) => g.lines.isNotEmpty).toList();
  }

  static ServerShareTextGroup _finalizeGroup(_MutableGroup g) {
    final globalPort = g.globalPort;
    final hasAnyPortHint =
        globalPort != null || g.entries.any((e) => e.hasPortHint);

    bool selectedByDefault(_RawEntry e, Uri normalized) {
      final host = normalized.host.toLowerCase();
      if (_denyHosts.contains(host)) return false;

      final pathSegs = normalized.pathSegments;
      final pathLooksLikeRoot = pathSegs.isEmpty ||
          (pathSegs.length == 1 && pathSegs.first.toLowerCase() == 'emby');
      if (!pathLooksLikeRoot) return false;

      final hasStrongCue = e.hasPortHint ||
          globalPort != null ||
          host.contains('emby') ||
          (pathSegs.isNotEmpty && pathSegs.first.toLowerCase() == 'emby');

      if (hasAnyPortHint) return hasStrongCue;
      return true;
    }

    final byUrl = <String, _MergedLine>{};
    for (final e in g.entries) {
      final normalizedUrl = _normalizeHttpUrl(
        e.uri,
        port: e.port ?? globalPort,
      );
      if (normalizedUrl == null) continue;
      final normalizedUri = Uri.parse(normalizedUrl);
      final name = (e.name).trim().isEmpty ? normalizedUri.host : e.name.trim();
      final selected = selectedByDefault(e, normalizedUri);

      final existing = byUrl[normalizedUrl];
      if (existing == null) {
        byUrl[normalizedUrl] = _MergedLine(
          name: name,
          url: normalizedUrl,
          selectedByDefault: selected,
        );
      } else {
        if (existing.name.trim().isEmpty && name.trim().isNotEmpty) {
          existing.name = name;
        }
        existing.selectedByDefault = existing.selectedByDefault || selected;
      }
    }

    return ServerShareTextGroup(
      password: g.password.trim(),
      lines: byUrl.values
          .map(
            (e) => ServerShareTextLine(
              name: e.name.trim().isEmpty ? e.url : e.name.trim(),
              url: e.url,
              selectedByDefault: e.selectedByDefault,
            ),
          )
          .toList(growable: false),
    );
  }

  static String _cleanUrlToken(String token) {
    var v = token.trim();
    while (v.isNotEmpty) {
      final last = v.codeUnitAt(v.length - 1);
      final isTrimChar = last == 0x29 || // )
          last == 0x5D || // ]
          last == 0x7D || // }
          last == 0x3E || // >
          last == 0x3001 || // 、
          last == 0xFF0C || // ，
          last == 0x3002 || // 。
          last == 0xFF1B || // ；
          last == 0x3B || // ;
          last == 0xFF09 || // ）
          last == 0x3011 || // 】
          last == 0xFF1F || // ？
          last == 0x3F; // ?
      if (!isTrimChar) break;
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  static int? _parsePortAfterUrl(String after) {
    final m = RegExp(r'^\s*(\d{1,5})\b').firstMatch(after);
    if (m == null) return null;
    final port = int.tryParse(m.group(1) ?? '');
    if (port == null || port <= 0 || port > 65535) return null;
    return port;
  }

  static bool _isSkippableLabelNoise(String line) {
    final v = line.trim();
    if (v.isEmpty) return true;
    if ((v.startsWith('(') && v.endsWith(')')) ||
        (v.startsWith('（') && v.endsWith('）'))) {
      return true;
    }
    if (v.startsWith('· ')) return true;
    if (v.startsWith('▎')) return true;
    if (v.startsWith('http://') || v.startsWith('https://')) return true;
    if (_portRe.hasMatch(v)) return true;
    return false;
  }

  static String _stripLabelPunctuation(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return '';
    // Common "label: url" or "线路1：" patterns.
    v = v.replaceAll(RegExp(r'[:：]\s*$'), '').trim();
    v = v.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    // If this is an obvious sentence, don't use as label.
    if (v.length > 40) return '';
    return v;
  }

  static String? _normalizeHttpUrl(Uri uri, {int? port}) {
    if (uri.host.trim().isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.trim();
    final path = (uri.path.isEmpty || uri.path == '/') ? '' : uri.path;

    final defaultPort = scheme == 'http' ? 80 : 443;
    final effectivePort = uri.hasPort ? uri.port : port;
    final portPart = (effectivePort == null || effectivePort == defaultPort)
        ? ''
        : ':$effectivePort';

    return '$scheme://$host$portPart$path';
  }
}

class _MutableGroup {
  final String password;
  int? globalPort;
  final List<_RawEntry> entries = [];

  _MutableGroup({required this.password});
}

class _RawEntry {
  final String name;
  final Uri uri;
  final bool hasPortHint;
  final int? port;

  _RawEntry({
    required this.name,
    required this.uri,
    required this.hasPortHint,
    required this.port,
  });
}

class _MergedLine {
  String name;
  final String url;
  bool selectedByDefault;

  _MergedLine({
    required this.name,
    required this.url,
    required this.selectedByDefault,
  });
}

