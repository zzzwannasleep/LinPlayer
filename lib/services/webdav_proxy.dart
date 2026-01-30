import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'emby_api.dart';
import 'webdav_api.dart';

class WebDavProxyServer {
  WebDavProxyServer._();

  static final WebDavProxyServer instance = WebDavProxyServer._();

  HttpServer? _server;
  Uri? _baseUri;
  final Map<String, _WebDavProxyEntry> _entries = {};

  final HttpClient _client = HttpClient()
    ..userAgent = EmbyApi.userAgent
    ..badCertificateCallback = (_, __, ___) => true;

  Future<Uri> ensureStarted() async {
    final existing = _baseUri;
    if (existing != null && _server != null) return existing;

    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: true,
    );
    _server = server;
    _baseUri = Uri.parse('http://${server.address.address}:${server.port}/');
    unawaited(_serve(server));
    return _baseUri!;
  }

  Future<Uri> registerFile({
    required Uri remoteUri,
    required String username,
    required String password,
    String? fileName,
  }) async {
    final base = await ensureStarted();
    final id = _randomId();
    _entries[id] = _WebDavProxyEntry(
      remoteUri: remoteUri,
      auth: WebDavAuth(username: username, password: password),
    );
    final safeName = (fileName ?? '').trim().isEmpty
        ? (remoteUri.pathSegments.isEmpty
            ? 'file'
            : remoteUri.pathSegments.last)
        : fileName!.trim();
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        'webdav',
        id,
        safeName,
      ],
    );
  }

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(22, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      // Best-effort: keep handler isolated per request.
      // ignore: unawaited_futures
      _handle(request);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments[0] != 'webdav') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final id = segments[1];
      final entry = _entries[id];
      if (entry == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final method = request.method.toUpperCase();
      if (method != 'GET' && method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await response.close();
        return;
      }

      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);

      final remote = await _openRemote(
        entry,
        method: method,
        range: range,
        ifRange: ifRange,
      );

      response.statusCode = remote.statusCode;
      _copyHeaders(remote.headers, response.headers);

      if (method != 'HEAD') {
        await response.addStream(remote);
      } else {
        // Drain to free the connection.
        await remote.drain<void>();
      }
    } catch (_) {
      response.statusCode = HttpStatus.badGateway;
      response.headers
          .set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8');
      response.write('WebDAV proxy error');
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<HttpClientResponse> _openRemote(
    _WebDavProxyEntry entry, {
    required String method,
    String? range,
    String? ifRange,
  }) async {
    HttpClientResponse res = await _openRemoteOnce(
      entry,
      method: method,
      range: range,
      ifRange: ifRange,
      authorization: entry.auth
          .buildAuthorizationHeader(method: method, uri: entry.remoteUri),
    );

    if (res.statusCode != HttpStatus.unauthorized) return res;

    final challenges =
        res.headers[HttpHeaders.wwwAuthenticateHeader] ?? const <String>[];
    final updated = entry.auth.updateFromChallenges(challenges);
    if (!updated) return res;

    await res.drain<void>();

    res = await _openRemoteOnce(
      entry,
      method: method,
      range: range,
      ifRange: ifRange,
      authorization: entry.auth
          .buildAuthorizationHeader(method: method, uri: entry.remoteUri),
    );
    return res;
  }

  Future<HttpClientResponse> _openRemoteOnce(
    _WebDavProxyEntry entry, {
    required String method,
    required String? authorization,
    String? range,
    String? ifRange,
  }) async {
    final req = await _client.openUrl(method, entry.remoteUri);
    req.followRedirects = true;
    req.maxRedirects = 5;
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    if (authorization != null && authorization.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, authorization);
    }
    if (range != null && range.trim().isNotEmpty) {
      req.headers.set(HttpHeaders.rangeHeader, range.trim());
    }
    if (ifRange != null && ifRange.trim().isNotEmpty) {
      req.headers.set(HttpHeaders.ifRangeHeader, ifRange.trim());
    }
    return req.close();
  }

  static void _copyHeaders(HttpHeaders from, HttpHeaders to) {
    const allow = <String>{
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.cacheControlHeader,
    };

    from.forEach((name, values) {
      final lower = name.toLowerCase();
      if (!allow.contains(lower)) return;
      for (final v in values) {
        to.add(lower, v);
      }
    });
  }
}

class _WebDavProxyEntry {
  final Uri remoteUri;
  final WebDavAuth auth;
  const _WebDavProxyEntry({required this.remoteUri, required this.auth});
}
