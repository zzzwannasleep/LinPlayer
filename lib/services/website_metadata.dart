import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'emby_api.dart';

class WebsiteMetadata {
  const WebsiteMetadata({
    required this.displayName,
    required this.faviconUrl,
  });

  final String? displayName;
  final String? faviconUrl;
}

class WebsiteMetadataService {
  WebsiteMetadataService._(this._client);

  static final WebsiteMetadataService instance = WebsiteMetadataService._(
    IOClient(
      HttpClient()
        ..userAgent = EmbyApi.userAgent
        ..badCertificateCallback = (_, __, ___) => true,
    ),
  );

  final http.Client _client;

  Future<WebsiteMetadata> fetch(
    Uri url, {
    Duration timeout = const Duration(seconds: 6),
    int maxBytes = 512 * 1024,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw ArgumentError.value(url, 'url', 'Only http/https is supported');
    }

    final resolvedUrl = url.replace(fragment: '');
    final request = http.Request('GET', resolvedUrl)
      ..headers.addAll({
        'User-Agent': EmbyApi.userAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      });

    final response =
        await _client.send(request).timeout(timeout, onTimeout: () {
      throw TimeoutException('Timeout fetching $resolvedUrl');
    });

    final html = await _readLimitedText(response, maxBytes: maxBytes);
    final parsed = parseHtml(html, baseUrl: resolvedUrl);

    return WebsiteMetadata(
      displayName: parsed.displayName,
      faviconUrl: parsed.faviconUrl ?? _fallbackFavicon(resolvedUrl),
    );
  }

  static WebsiteMetadata parseHtml(String html, {required Uri baseUrl}) {
    final tagRegex = RegExp(r'<(meta|link)\b[^>]*>', caseSensitive: false);
    final titleRegex = RegExp(r'<title\b[^>]*>(.*?)</title>',
        caseSensitive: false, dotAll: true);

    String? siteName;
    String? title;
    String? faviconUrl;
    double faviconScore = -1;

    for (final match in tagRegex.allMatches(html)) {
      final raw = match.group(0);
      if (raw == null) continue;
      final tagName = match.group(1)?.toLowerCase();
      final attrs = _parseAttributes(raw);
      if (tagName == 'meta') {
        final property = (attrs['property'] ?? '').toLowerCase();
        final name = (attrs['name'] ?? '').toLowerCase();
        final content = _cleanupText(attrs['content'] ?? '');
        if (content.isEmpty) continue;
        if (property == 'og:site_name' && siteName == null) {
          siteName = content;
        } else if (name == 'application-name' && siteName == null) {
          siteName = content;
        } else if (name == 'apple-mobile-web-app-title' && siteName == null) {
          siteName = content;
        }
      } else if (tagName == 'link') {
        final rel = (attrs['rel'] ?? '').toLowerCase();
        if (rel.isEmpty) continue;
        final href = (attrs['href'] ?? '').trim();
        if (href.isEmpty) continue;
        if (href.startsWith('data:')) continue;

        final score = _faviconRelScore(rel);
        if (score <= faviconScore) continue;

        faviconUrl = baseUrl.resolve(href).toString();
        faviconScore = score;
      }
    }

    final titleMatch = titleRegex.firstMatch(html);
    if (titleMatch != null) {
      title = _cleanupText(titleMatch.group(1) ?? '');
    }

    final bestName = (siteName ?? title);
    return WebsiteMetadata(
      displayName: bestName != null && bestName.trim().isNotEmpty
          ? bestName.trim()
          : null,
      faviconUrl: faviconUrl,
    );
  }

  static Future<String> _readLimitedText(
    http.StreamedResponse response, {
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream) {
      if (chunk.isEmpty) continue;
      final remaining = maxBytes - received;
      if (remaining <= 0) break;
      if (chunk.length <= remaining) {
        builder.add(chunk);
        received += chunk.length;
      } else {
        builder.add(chunk.sublist(0, remaining));
        received += remaining;
        break;
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  static double _faviconRelScore(String rel) {
    final r = rel.toLowerCase();
    if (r.contains('apple-touch-icon')) return 3.0;
    if (r.contains('icon')) return 2.0;
    if (r.contains('shortcut')) return 1.5;
    return 0.0;
  }

  static String? _fallbackFavicon(Uri baseUrl) {
    try {
      return baseUrl.replace(path: '/favicon.ico', query: '', fragment: '').toString();
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _parseAttributes(String rawTag) {
    final attrs = <String, String>{};
    final attrRegex = RegExp(
      r'''([a-zA-Z0-9:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))''',
    );
    for (final m in attrRegex.allMatches(rawTag)) {
      final key = (m.group(1) ?? '').toLowerCase();
      if (key.isEmpty) continue;
      final value = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
      attrs[key] = value;
    }
    return attrs;
  }

  static String _cleanupText(String text) {
    var s = text.replaceAll('\u00A0', ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return '';
    s = _decodeHtmlEntities(s);
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static String _decodeHtmlEntities(String text) {
    var s = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");

    s = s.replaceAllMapped(RegExp(r'&#(x?[0-9A-Fa-f]+);'), (m) {
      final raw = m.group(1);
      if (raw == null || raw.isEmpty) return m.group(0) ?? '';
      try {
        final value =
            raw.startsWith('x') || raw.startsWith('X')
                ? int.parse(raw.substring(1), radix: 16)
                : int.parse(raw, radix: 10);
        return String.fromCharCode(value);
      } catch (_) {
        return m.group(0) ?? '';
      }
    });

    return s;
  }
}
