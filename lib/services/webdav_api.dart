import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'emby_api.dart';

class WebDavEntry {
  final String name;
  final Uri uri;
  final bool isDirectory;
  final int? contentLength;
  final DateTime? lastModified;
  final String? etag;
  final String? contentType;

  const WebDavEntry({
    required this.name,
    required this.uri,
    required this.isDirectory,
    required this.contentLength,
    required this.lastModified,
    required this.etag,
    required this.contentType,
  });
}

class WebDavApiException implements Exception {
  final String message;
  WebDavApiException(this.message);
  @override
  String toString() => message;
}

class WebDavApi {
  WebDavApi({
    required this.baseUri,
    required this.username,
    required this.password,
    HttpClient? client,
  })  : _client = client ??
            (HttpClient()
              ..userAgent = EmbyApi.userAgent
              ..badCertificateCallback = (_, __, ___) => true),
        _auth = WebDavAuth(username: username, password: password);

  final Uri baseUri;
  final String username;
  final String password;

  final HttpClient _client;
  final WebDavAuth _auth;

  static const _davNs = 'DAV:';
  static const _propfindAllProp = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>''';

  static Uri normalizeBaseUri(String raw, {String defaultScheme = 'https'}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Empty WebDAV url');
    }

    Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      uri = Uri.tryParse('$defaultScheme://$trimmed');
    }
    if (uri == null || uri.host.isEmpty) {
      throw FormatException('Invalid WebDAV url: $raw');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw FormatException('Unsupported scheme: ${uri.scheme}');
    }
    if (uri.path.isEmpty) {
      uri = uri.replace(path: '/');
    }
    return uri.replace(query: '', fragment: '');
  }

  static Uri _ensureDirUri(Uri uri) {
    var path = uri.path;
    if (path.isEmpty) path = '/';
    if (path != '/' && !path.endsWith('/')) {
      path = '$path/';
    }
    return uri.replace(path: path);
  }

  static Uri _ensureNonEmptyPath(Uri uri) {
    if (uri.path.isNotEmpty) return uri;
    return uri.replace(path: '/');
  }

  static Uri _toggleTrailingSlash(Uri uri) {
    var path = uri.path;
    if (path.isEmpty) path = '/';
    if (path == '/') return uri.replace(path: '/');

    if (path.endsWith('/')) {
      while (path.endsWith('/') && path != '/') {
        path = path.substring(0, path.length - 1);
      }
    } else {
      path = '$path/';
    }
    return uri.replace(path: path);
  }

  static String _normalizePathForCompare(String path) {
    var p = path;
    if (p.isEmpty) p = '/';
    if (p != '/') {
      while (p.endsWith('/')) {
        p = p.substring(0, p.length - 1);
      }
    }
    try {
      return Uri.decodeFull(p);
    } catch (_) {
      return p;
    }
  }

  Future<void> validateRoot({Duration timeout = const Duration(seconds: 8)}) {
    return propfind(
      baseUri,
      depth: 0,
      timeout: timeout,
    ).then((_) => null);
  }

  Future<XmlDocument> propfind(
    Uri uri, {
    required int depth,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final original = _ensureNonEmptyPath(uri);
    final alt = _toggleTrailingSlash(original);
    final candidates = <Uri>[
      original,
      if (alt.toString() != original.toString()) alt,
    ];

    final errors = <Object>[];

    for (final target in candidates) {
      try {
        final res = await _send(
          'PROPFIND',
          target,
          headers: {
            'Depth': depth.toString(),
            HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8',
          },
          bodyBytes: utf8.encode(_propfindAllProp),
          timeout: timeout,
        );

        final status = res.statusCode;
        if (status != 207 && status != 200) {
          throw WebDavApiException(
              'PROPFIND failed ($status): ${target.toString()}');
        }

        final text = utf8.decode(res.bodyBytes, allowMalformed: true);
        try {
          return XmlDocument.parse(text);
        } catch (e) {
          throw WebDavApiException('Invalid WebDAV XML: $e');
        }
      } catch (e) {
        errors.add(e);
        if (candidates.length <= 1 || target == candidates.last) break;
      }
    }

    if (errors.length == 1) {
      // ignore: only_throw_errors
      throw errors.single;
    }
    throw WebDavApiException(
      'PROPFIND failed for ${candidates.map((u) => u.toString()).join(' / ')}: '
      '${errors.map((e) => e.toString()).join(' | ')}',
    );
  }

  Future<List<WebDavEntry>> listDirectory(
    Uri dirUri, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final requestUriRaw = _ensureNonEmptyPath(dirUri);
    final requestUri = _ensureDirUri(requestUriRaw);
    final doc = await propfind(
      requestUriRaw,
      depth: 1,
      timeout: timeout,
    );

    final requestPathNorm = _normalizePathForCompare(requestUri.path);
    final entries = <WebDavEntry>[];

    for (final resp in doc.findAllElements('response', namespace: _davNs)) {
      final hrefRaw = resp.getElement('href', namespace: _davNs)?.innerText;
      if (hrefRaw == null || hrefRaw.trim().isEmpty) continue;
      final href = hrefRaw.trim();

      final resolved = _resolveHref(base: requestUri, href: href);
      if (resolved == null) continue;

      final entryPathNorm = _normalizePathForCompare(resolved.path);
      if (entryPathNorm == requestPathNorm) {
        // The directory itself, returned in Depth:1.
        continue;
      }

      final prop = _pickOkProp(resp);

      final displayName =
          prop?.getElement('displayname', namespace: _davNs)?.innerText.trim();
      final resourceType = prop?.getElement('resourcetype', namespace: _davNs);
      final isDir =
          resourceType?.getElement('collection', namespace: _davNs) != null;

      final lenText =
          prop?.getElement('getcontentlength', namespace: _davNs)?.innerText;
      final contentLength =
          lenText == null ? null : int.tryParse(lenText.trim());

      final lmText =
          prop?.getElement('getlastmodified', namespace: _davNs)?.innerText;
      DateTime? lastModified;
      if (lmText != null && lmText.trim().isNotEmpty) {
        try {
          lastModified = HttpDate.parse(lmText.trim()).toLocal();
        } catch (_) {}
      }

      final etag =
          prop?.getElement('getetag', namespace: _davNs)?.innerText.trim();
      final contentType = prop
          ?.getElement('getcontenttype', namespace: _davNs)
          ?.innerText
          .trim();

      final name = (displayName != null && displayName.isNotEmpty)
          ? displayName
          : _fallbackNameFromUri(resolved, isDir: isDir);

      entries.add(
        WebDavEntry(
          name: name,
          uri: resolved,
          isDirectory: isDir,
          contentLength: contentLength,
          lastModified: lastModified,
          etag: (etag != null && etag.isNotEmpty) ? etag : null,
          contentType: (contentType != null && contentType.isNotEmpty)
              ? contentType
              : null,
        ),
      );
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static XmlElement? _pickOkProp(XmlElement response) {
    for (final propstat
        in response.findElements('propstat', namespace: _davNs)) {
      final status =
          propstat.getElement('status', namespace: _davNs)?.innerText ?? '';
      if (status.contains(' 200 ') || status.contains(' 200')) {
        return propstat.getElement('prop', namespace: _davNs);
      }
    }
    // Fallback: first propstat.
    return response
        .findElements('propstat', namespace: _davNs)
        .firstOrNull
        ?.getElement('prop', namespace: _davNs);
  }

  static Uri? _resolveHref({required Uri base, required String href}) {
    try {
      final u = Uri.tryParse(href);
      if (u != null && u.hasScheme && u.host.isNotEmpty) return u;
    } catch (_) {}
    try {
      return base.resolve(href);
    } catch (_) {
      return null;
    }
  }

  static String _fallbackNameFromUri(Uri uri, {required bool isDir}) {
    final segments = uri.pathSegments;
    if (segments.isEmpty) return isDir ? 'Folder' : 'File';
    var name = segments.last;
    name = name.trim();
    if (name.isEmpty) return isDir ? 'Folder' : 'File';
    return name;
  }

  Future<_WebDavRawResponse> _send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    List<int>? bodyBytes,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final res = await _sendOnce(
      method,
      uri,
      headers: headers,
      bodyBytes: bodyBytes,
      timeout: timeout,
      authorization: _auth.buildAuthorizationHeader(method: method, uri: uri),
    );

    if (res.statusCode != HttpStatus.unauthorized) return res;

    final challenges =
        res.headers[HttpHeaders.wwwAuthenticateHeader] ?? const [];
    final updated = _auth.updateFromChallenges(challenges);
    if (!updated) return res;

    // Retry once with updated auth (Digest).
    return _sendOnce(
      method,
      uri,
      headers: headers,
      bodyBytes: bodyBytes,
      timeout: timeout,
      authorization: _auth.buildAuthorizationHeader(method: method, uri: uri),
    );
  }

  Future<_WebDavRawResponse> _sendOnce(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
    required String? authorization,
    List<int>? bodyBytes,
  }) async {
    final request = await _client.openUrl(method, uri).timeout(timeout,
        onTimeout: () => throw TimeoutException('Timeout: $uri'));
    request.followRedirects = true;
    request.maxRedirects = 5;

    headers.forEach(request.headers.set);
    if (authorization != null && authorization.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
    }
    request.headers.set(HttpHeaders.acceptHeader, '*/*');

    if (bodyBytes != null && bodyBytes.isNotEmpty) {
      request.add(bodyBytes);
    }

    final response = await request.close().timeout(timeout,
        onTimeout: () => throw TimeoutException('Timeout: $uri'));

    final bytes = await _readAllBytes(response, maxBytes: 16 * 1024 * 1024);
    return _WebDavRawResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      bodyBytes: bytes,
    );
  }

  static Future<List<int>> _readAllBytes(
    HttpClientResponse response, {
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response) {
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
    return builder.takeBytes();
  }
}

class _WebDavRawResponse {
  final int statusCode;
  final HttpHeaders headers;
  final List<int> bodyBytes;

  _WebDavRawResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });
}

class WebDavAuth {
  WebDavAuth({required this.username, required this.password});

  final String username;
  final String password;

  _DigestChallenge? _digest;
  int _nonceCount = 0;
  String _cnonce = '';

  bool get _hasCreds => username.trim().isNotEmpty;

  String? buildAuthorizationHeader({
    required String method,
    required Uri uri,
  }) {
    if (!_hasCreds) return null;

    final digest = _digest;
    if (digest == null) {
      // Preemptive Basic.
      final user = username;
      final pass = password;
      final token = base64Encode(utf8.encode('$user:$pass'));
      return 'Basic $token';
    }

    _nonceCount += 1;
    if (_cnonce.isEmpty) {
      _cnonce = _randomHex(16);
    }
    final nc = _nonceCount.toRadixString(16).padLeft(8, '0');

    final uriPart = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final realm = digest.realm;
    final nonce = digest.nonce;

    final algo = digest.algorithm;
    final qop = digest.qop;
    final cnonce = _cnonce;

    final ha1Base =
        md5.convert(utf8.encode('$username:$realm:$password')).toString();
    final ha1 = (algo == 'md5-sess')
        ? md5.convert(utf8.encode('$ha1Base:$nonce:$cnonce')).toString()
        : ha1Base;
    final ha2 = md5.convert(utf8.encode('$method:$uriPart')).toString();

    final response = (qop != null && qop.isNotEmpty)
        ? md5
            .convert(utf8.encode('$ha1:$nonce:$nc:$cnonce:$qop:$ha2'))
            .toString()
        : md5.convert(utf8.encode('$ha1:$nonce:$ha2')).toString();

    final parts = <String>[
      'username="${_escape(username)}"',
      'realm="${_escape(realm)}"',
      'nonce="${_escape(nonce)}"',
      'uri="${_escape(uriPart)}"',
      'response="${_escape(response)}"',
      'algorithm="${_escape(digest.algorithmRaw)}"',
    ];
    if (digest.opaque != null && digest.opaque!.isNotEmpty) {
      parts.add('opaque="${_escape(digest.opaque!)}"');
    }
    if (qop != null && qop.isNotEmpty) {
      parts.add('qop=$qop');
      parts.add('nc=$nc');
      parts.add('cnonce="${_escape(cnonce)}"');
    }
    return 'Digest ${parts.join(', ')}';
  }

  bool updateFromChallenges(List<String> challenges) {
    if (!_hasCreds) return false;
    final parsed = _parseChallenges(challenges);
    final digest = parsed.firstWhere((c) => c.scheme == _AuthScheme.digest,
        orElse: () => const _AuthChallenge(_AuthScheme.none, {}));
    if (digest.scheme == _AuthScheme.digest) {
      final next = _DigestChallenge.fromParams(digest.params);
      if (next != null) {
        _digest = next;
        _nonceCount = 0;
        _cnonce = _randomHex(16);
        return true;
      }
    }
    // Basic doesn't require update (we already send it preemptively).
    return false;
  }

  static List<_AuthChallenge> _parseChallenges(List<String> headers) {
    final out = <_AuthChallenge>[];
    for (final raw in headers) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final space = line.indexOf(' ');
      final schemeRaw = (space < 0 ? line : line.substring(0, space)).trim();
      final rest = space < 0 ? '' : line.substring(space + 1).trim();
      final scheme = switch (schemeRaw.toLowerCase()) {
        'digest' => _AuthScheme.digest,
        'basic' => _AuthScheme.basic,
        _ => _AuthScheme.none,
      };
      if (scheme == _AuthScheme.none) continue;
      final params = _parseAuthParams(rest);
      out.add(_AuthChallenge(scheme, params));
    }
    return out;
  }

  static Map<String, String> _parseAuthParams(String input) {
    final out = <String, String>{};
    var i = 0;
    var inQuotes = false;
    final buf = StringBuffer();
    final parts = <String>[];
    while (i < input.length) {
      final ch = input[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        buf.write(ch);
      } else if (ch == ',' && !inQuotes) {
        parts.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
      i++;
    }
    if (buf.isNotEmpty) parts.add(buf.toString());

    for (final part in parts) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      final key = p.substring(0, eq).trim().toLowerCase();
      var val = p.substring(eq + 1).trim();
      if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
        val = val.substring(1, val.length - 1);
      }
      out[key] = val;
    }
    return out;
  }

  static String _randomHex(int length) {
    final rnd = Random.secure();
    const chars = '0123456789abcdef';
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }

  static String _escape(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}

enum _AuthScheme { none, basic, digest }

class _AuthChallenge {
  final _AuthScheme scheme;
  final Map<String, String> params;
  const _AuthChallenge(this.scheme, this.params);
}

class _DigestChallenge {
  final String realm;
  final String nonce;
  final String? opaque;
  final String algorithmRaw;
  final String algorithm;
  final String? qop;

  const _DigestChallenge({
    required this.realm,
    required this.nonce,
    required this.opaque,
    required this.algorithmRaw,
    required this.algorithm,
    required this.qop,
  });

  static _DigestChallenge? fromParams(Map<String, String> params) {
    final realm = (params['realm'] ?? '').trim();
    final nonce = (params['nonce'] ?? '').trim();
    if (realm.isEmpty || nonce.isEmpty) return null;
    final opaque = (params['opaque'] ?? '').trim();

    final algorithmRaw = (params['algorithm'] ?? 'MD5').trim();
    final algoNorm = algorithmRaw.toLowerCase();
    final algorithm = (algoNorm == 'md5-sess') ? 'md5-sess' : 'md5';

    final qopRaw = (params['qop'] ?? '').trim();
    String? qop;
    if (qopRaw.isNotEmpty) {
      final options = qopRaw
          .split(',')
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList();
      if (options.contains('auth')) {
        qop = 'auth';
      } else if (options.isNotEmpty) {
        qop = options.first;
      }
    }

    return _DigestChallenge(
      realm: realm,
      nonce: nonce,
      opaque: opaque.isEmpty ? null : opaque,
      algorithmRaw: algorithmRaw,
      algorithm: algorithm,
      qop: qop,
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
