import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_interfaces.dart';
import '../app_identity.dart';
import '../network/proxy_http_client.dart';
import '../utils/playback_url_resolver.dart';

/// 详情页「预加载」服务。
///
/// 进入集/电影详情页时，按规范流程解析真实播放地址（PlaybackInfo → 媒体源 →
/// 直传/直链 URL），再用 [kPreloadUserAgent]（`LinplayerPreload/<版本>`）对其
/// 发起 Range 预取请求，提前预热服务端 / CDN 缓存，使用户点「播放」时更接近秒开。
///
/// 预取量针对 **mpv / media_kit（libmpv，底层 ffmpeg）** 的起播特性设计：
/// - **头部**：固定预热 [_headBytes]（32MB）。ffmpeg 默认 `probesize≈5MB` 才能探明流，
///   探完还要预读起播缓冲；固定大块比按码率动态估算更稳，确保 mpv 系内核也能秒开
///   （不只 ExoPlayer），代价是每条目一次性多用些流量。
/// - **尾部**：非 faststart 的 MP4 其 `moov` 原子在文件尾、MKV 的 Cues 索引常在尾，
///   mpv 起播/拖动需先读到它们，故额外预热末尾一小段（[_tailBytes]）。
///
/// 设计要点：
/// - **fire-and-forget**：所有异常静默吞掉，绝不影响详情页展示与后续真正播放。
/// - **去重 / 防抖**：同一 itemId 短时间内只预热一次；切换条目自动取消上一个。
/// - **不缓冲整片**：响应体以 stream 边收边丢，读满目标字节即主动断开。
class PreloadService {
  PreloadService._();
  static final PreloadService instance = PreloadService._();

  /// 头部固定预取字节（32MB）：覆盖 ffmpeg 探流（probesize≈5MB）+ 充足起播缓冲，
  /// 保证 mpv / media_kit 等 libmpv 系内核也能秒开，而不只是 ExoPlayer。
  static const int _headBytes = 32 * 1024 * 1024;

  /// 尾部预取字节（覆盖非 faststart MP4 的 moov / MKV 的 Cues 索引）。
  static const int _tailBytes = 2 * 1024 * 1024;

  /// 同一条目预热的最短间隔，避免页面重建 / 来回切换重复打流。
  static const Duration _dedupWindow = Duration(minutes: 2);

  final Dio _dio = _buildDio();
  CancelToken? _inFlight;
  String? _lastItemId;
  DateTime? _lastAt;

  static Dio _buildDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
      // 仅预热缓存，不缓存响应体到内存：用 stream 边收边丢。
      responseType: ResponseType.stream,
      followRedirects: true,
      // 2xx 直传 + 206 Partial（Range 命中）都算成功。
      validateStatus: (code) => code != null && code >= 200 && code < 400,
      headers: const {
        'User-Agent': kPreloadUserAgent,
        'Accept': '*/*',
      },
    ));
    applyProxyToDio(dio);
    return dio;
  }

  /// 进入详情页时调用。[enabled] 为设置开关；关闭时直接 no-op。
  void preloadItem({
    required ApiClientFactory api,
    required String itemId,
    required bool enabled,
    String? preferredMediaSourceId,
    String? versionRegex,
    bool strmDirectPlay = false,
  }) {
    if (!enabled || itemId.isEmpty) return;
    // 去重：同一条目在窗口内不重复预热。
    final now = DateTime.now();
    if (_lastItemId == itemId &&
        _lastAt != null &&
        now.difference(_lastAt!) < _dedupWindow) {
      return;
    }
    // 切换条目：取消上一个未完成的预热。
    _inFlight?.cancel('switch-item');
    final cancel = CancelToken();
    _inFlight = cancel;
    _lastItemId = itemId;
    _lastAt = now;
    unawaited(_run(
      api: api,
      itemId: itemId,
      preferredMediaSourceId: preferredMediaSourceId,
      versionRegex: versionRegex,
      strmDirectPlay: strmDirectPlay,
      cancel: cancel,
    ));
  }

  Future<void> _run({
    required ApiClientFactory api,
    required String itemId,
    required String? preferredMediaSourceId,
    required String? versionRegex,
    required bool strmDirectPlay,
    required CancelToken cancel,
  }) async {
    try {
      final playbackInfo = await api.playback.getPlaybackInfo(itemId);
      if (playbackInfo.mediaSources.isEmpty) return; // 非可直接播放条目（如剧集根）
      final selection = buildPlaybackSelection(
        playbackInfo: playbackInfo,
        itemId: itemId,
        preferredMediaSourceId: preferredMediaSourceId,
        versionRegex: versionRegex,
        strmDirectPlay: strmDirectPlay,
      );
      final source = selection.mediaSource;
      final req = selection.primaryRequest;
      final serverUrl = api.playback.getVideoStreamUrl(
        req.itemId,
        mediaSourceId: req.mediaSourceId,
        container: req.container,
        playSessionId: req.playSessionId,
        staticStream: req.staticStream,
        allowDirectPlay: req.allowDirectPlay,
        allowDirectStream: req.allowDirectStream,
        allowTranscoding: req.allowTranscoding,
        enableAutoStreamCopy: req.enableAutoStreamCopy,
        enableAutoStreamCopyAudio: req.enableAutoStreamCopyAudio,
        enableAutoStreamCopyVideo: req.enableAutoStreamCopyVideo,
      );
      final url = (selection.directPlayUrl?.isNotEmpty ?? false)
          ? selection.directPlayUrl!
          : serverUrl;
      if (cancel.isCancelled) return;

      // 头部：固定 32MB，覆盖 ffmpeg 探流 + 起播缓冲。
      await _warm(url, range: 'bytes=0-${_headBytes - 1}', limit: _headBytes,
          outer: cancel);

      // 尾部：仅当已知文件大小且与头部不重叠时，预热 moov / Cues 所在的末尾。
      final size = source?.size;
      if (!cancel.isCancelled &&
          size != null &&
          size > _headBytes + _tailBytes * 2) {
        await _warm(url, range: 'bytes=-$_tailBytes', limit: _tailBytes,
            outer: cancel);
      }
    } on DioException catch (_) {
      // 网络/超时/取消：预热失败无所谓，静默。
    } catch (e) {
      if (kDebugMode) debugPrint('[Preload] 预加载失败: $e');
    }
  }

  /// 拉取一段字节并丢弃，仅为预热缓存。读满 [limit] 即主动断开底层连接。
  ///
  /// 用独立的内部 CancelToken 控制「读够即停」，同时桥接外层 [outer]（切换条目时取消）。
  Future<void> _warm(
    String url, {
    required String range,
    required int limit,
    required CancelToken outer,
  }) async {
    if (outer.isCancelled) return;
    final inner = CancelToken();
    unawaited(outer.whenCancel.then((_) {
      if (!inner.isCancelled) inner.cancel('outer-cancelled');
    }));
    try {
      final resp = await _dio.get<ResponseBody>(
        url,
        cancelToken: inner,
        options: Options(headers: {'Range': range}),
      );
      final stream = resp.data?.stream;
      if (stream == null) return;
      var received = 0;
      await for (final chunk in stream) {
        if (inner.isCancelled) break;
        received += chunk.length;
        if (received >= limit) break; // 达到目标主动停止，避免继续下载整片
      }
    } finally {
      if (!inner.isCancelled) inner.cancel('warm-done');
    }
  }
}
