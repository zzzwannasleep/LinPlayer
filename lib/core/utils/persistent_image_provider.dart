import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui show Codec;
import 'package:extended_image/extended_image.dart' show ExtendedImageProvider, keyToMd5;
import 'package:http_client_helper/http_client_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart';

import '../network/proxy_http_client.dart';
import '../network/proxy_settings.dart';
import '../services/cache_service.dart';

/// 持久化网络图片 Provider
/// 
/// 基于 ExtendedNetworkImageProvider 修改，将缓存目录从临时目录改为应用文档目录，
/// 确保图片缓存持久化，退出应用后重新进入不需要重新下载。
class PersistentNetworkImageProvider
    extends ImageProvider<PersistentNetworkImageProvider>
    with ExtendedImageProvider<PersistentNetworkImageProvider> {
  
  PersistentNetworkImageProvider(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cache = true,
    this.retries = 5,
    this.timeLimit,
    this.timeRetry = const Duration(milliseconds: 350),
    this.cacheKey,
    this.requestKey,
    this.printError = true,
    this.cacheRawData = false,
    this.cancelToken,
    this.imageCacheName,
    this.cacheMaxAge,
  });

  @override
  final String? imageCacheName;
  @override
  final bool cacheRawData;
  final Duration? timeLimit;
  final int retries;
  final Duration timeRetry;
  final bool cache;
  final String url;
  final double scale;
  final Map<String, String>? headers;
  final CancellationToken? cancelToken;
  final String? cacheKey;
  final Object? requestKey;
  final bool printError;
  final Duration? cacheMaxAge;

  static String? _persistentCachePath;

  /// 标准化 URL 用于缓存 key 生成
  /// 
  /// 去除可变查询参数（maxWidth/maxHeight/api_key/quality），
  /// 保留图片身份标识参数（tag/imageType/itemId），
  /// 使得不同页面请求同一张图片的不同尺寸时能复用同一个缓存。
  static String _normalizeUrlForCache(String url) {
    try {
      final uri = Uri.parse(url);
      final params = Map<String, String>.from(uri.queryParameters);
      // 移除可变参数（尺寸、认证、压缩质量）
      params.remove('maxWidth');
      params.remove('maxHeight');
      params.remove('api_key');
      params.remove('quality');
      // 保留 tag、format 等标识参数
      final normalizedUri = uri.replace(queryParameters: params);
      return normalizedUri.toString();
    } catch (e) {
      return url;
    }
  }

  static Future<String> get _cachePath async {
    if (_persistentCachePath != null) return _persistentCachePath!;
    // 与 CacheService 共用统一的便携 temp 缓存根目录（程序目录下的 temp/image_cache），
    // 自包含、不污染系统目录，也避免被 OneDrive 同步。
    _persistentCachePath = await CacheService.imageCacheDirPath;
    return _persistentCachePath!;
  }

  @override
  ImageStreamCompleter loadImage(
    PersistentNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final StreamController<ImageChunkEvent> chunkEvents =
        StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      scale: key.scale,
      chunkEvents: chunkEvents.stream,
      debugLabel: key.url,
      informationCollector: () {
        return <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<PersistentNetworkImageProvider>('Image key', key),
        ];
      },
    );
  }

  @override
  Future<PersistentNetworkImageProvider> obtainKey(
      ImageConfiguration configuration) {
    return SynchronousFuture<PersistentNetworkImageProvider>(this);
  }

  Future<ui.Codec> _loadAsync(
    PersistentNetworkImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    assert(key == this);
    // 使用标准化后的 URL 生成缓存 key，不同 maxWidth 的请求可以复用同一个缓存
    final String normalizedUrl = _normalizeUrlForCache(key.url);
    final String md5Key = cacheKey ?? keyToMd5(normalizedUrl);
    ui.Codec? result;
    if (cache) {
      try {
        final Uint8List? data = await _loadCache(key, chunkEvents, md5Key);
        if (data != null) {
          result = await instantiateImageCodec(data, decode);
        }
      } catch (e) {
        if (printError) debugPrint('PersistentNetworkImageProvider: $e');
      }
    }

    if (result == null) {
      try {
        final Uint8List? data = await _loadNetwork(key, chunkEvents);
        if (data != null) {
          result = await instantiateImageCodec(data, decode);
        }
      } catch (e) {
        if (printError) debugPrint('PersistentNetworkImageProvider: $e');
      }
    }

    if (result == null) {
      return Future<ui.Codec>.error(StateError('Failed to load $url.'));
    }

    return result;
  }

  Future<Uint8List?> _loadCache(
    PersistentNetworkImageProvider key,
    StreamController<ImageChunkEvent>? chunkEvents,
    String md5Key,
  ) async {
    final Directory cacheDir = Directory(await _cachePath);
    Uint8List? data;

    if (cacheDir.existsSync()) {
      final File cacheFile = File(join(cacheDir.path, md5Key));
      if (cacheFile.existsSync()) {
        if (key.cacheMaxAge != null) {
          final DateTime now = DateTime.now();
          final FileStat fs = cacheFile.statSync();
          if (now.subtract(key.cacheMaxAge!).isAfter(fs.changed)) {
            cacheFile.deleteSync(recursive: true);
          } else {
            data = await cacheFile.readAsBytes();
          }
        } else {
          data = await cacheFile.readAsBytes();
        }
      }
    } else {
      await cacheDir.create(recursive: true);
    }

    if (data == null) {
      data = await _loadNetwork(key, chunkEvents);
      if (data != null) {
        await File(join(cacheDir.path, md5Key)).writeAsBytes(data);
      }
    }

    return data;
  }

  Future<Uint8List?> _loadNetwork(
    PersistentNetworkImageProvider key,
    StreamController<ImageChunkEvent>? chunkEvents,
  ) async {
    try {
      final Uri resolved = Uri.base.resolve(key.url);
      final HttpClientResponse? response = await _tryGetResponse(resolved);
      if (response == null || response.statusCode != HttpStatus.ok) {
        if (response != null) {
          await response.drain<List<int>>(<int>[]);
        }
        return null;
      }

      final Uint8List bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: chunkEvents != null
            ? (int cumulative, int? total) {
                chunkEvents.add(ImageChunkEvent(
                  cumulativeBytesLoaded: cumulative,
                  expectedTotalBytes: total,
                ));
              }
            : null,
      );
      if (bytes.lengthInBytes == 0) {
        return Future<Uint8List>.error(
            StateError('NetworkImage is an empty file: $resolved'));
      }

      return bytes;
    } on OperationCanceledError catch (_) {
      if (printError) debugPrint('User cancel request $url.');
      return Future<Uint8List>.error(StateError('User cancel request $url.'));
    } catch (e) {
      if (printError) debugPrint('$e');
    } finally {
      await chunkEvents?.close();
    }
    return null;
  }

  Future<HttpClientResponse> _getResponse(Uri resolved) async {
    final HttpClientRequest request = await httpClient.getUrl(resolved);
    headers?.forEach((String name, String value) {
      request.headers.add(name, value);
    });
    final HttpClientResponse response = await request.close();
    if (timeLimit != null) {
      response.timeout(timeLimit!);
    }
    return response;
  }

  Future<HttpClientResponse?> _tryGetResponse(Uri resolved) async {
    cancelToken?.throwIfCancellationRequested();
    return await RetryHelper.tryRun<HttpClientResponse>(
      () {
        return CancellationTokenSource.register(
          cancelToken,
          _getResponse(resolved),
        );
      },
      cancelToken: cancelToken,
      timeRetry: timeRetry,
      retries: retries,
    );
  }

  // 共享 HttpClient 跟随用户代理配置；代理变更（revision 自增）时重建。
  // createProxiedHttpClient 已内置自签名证书放行，与 Dio 配置保持一致。
  static HttpClient? _sharedHttpClient;
  static int _sharedClientRevision = -1;

  static HttpClient get httpClient {
    final revision = ProxyRuntime.instance.revision;
    if (_sharedHttpClient == null || _sharedClientRevision != revision) {
      _sharedHttpClient?.close(force: true);
      _sharedHttpClient = createProxiedHttpClient()..autoUncompress = false;
      _sharedClientRevision = revision;
    }
    HttpClient client = _sharedHttpClient!;
    assert(() {
      if (debugNetworkImageHttpClientProvider != null) {
        client = debugNetworkImageHttpClientProvider!();
      }
      return true;
    }());
    return client;
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is PersistentNetworkImageProvider &&
        url == other.url &&
        scale == other.scale &&
        cache == other.cache &&
        cacheKey == other.cacheKey &&
        requestKey == other.requestKey &&
        retries == other.retries &&
        imageCacheName == other.imageCacheName &&
        cacheMaxAge == other.cacheMaxAge;
  }

  @override
  int get hashCode => Object.hash(
        url,
        scale,
        cache,
        cacheKey,
        requestKey,
        retries,
        imageCacheName,
        cacheMaxAge,
      );

  @override
  String toString() => '$runtimeType("$url", scale: $scale)';
}
