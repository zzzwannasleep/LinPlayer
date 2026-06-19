import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../network/proxy_http_client.dart';
import 'download_models.dart';

/// 多线程（分段）下载管理器。
///
/// 设计要点：
/// - 同一时刻只下载 **一个文件**，单文件内部用 1–4 个分段（线程）并发，
///   用 HTTP Range 请求分块，以此把对服务器的压力限制在可控范围内。
/// - 每个分段写入独立的 `${file}.partN` 临时文件，全部完成后再按序拼接为最终文件，
///   天然支持断点续传（重启后按 part 文件实际大小恢复进度）。
/// - 下载源使用 Emby 原生 `/Items/{id}/Download` 接口，由服务端按下载权限放行。
class DownloadManager extends ChangeNotifier {
  DownloadManager();

  final Map<String, DownloadItem> _items = {};
  late final Dio _dio = _createDio();
  Directory? _dir;
  File? _indexFile;
  bool _initialized = false;

  // 当前活跃下载
  String? _activeId;
  List<CancelToken> _activeTokens = [];
  final Set<String> _pendingRemoval = {};

  // 进度通知节流
  final Stopwatch _emitClock = Stopwatch()..start();
  int _lastEmitMs = 0;

  /// 分段（线程）数，1–4，可由设置调整。
  int _threads = 2;
  int get threads => _threads;
  set threads(int v) => _threads = v.clamp(1, 4).toInt();

  bool get isInitialized => _initialized;

  List<DownloadItem> get items {
    final list = _items.values.toList();
    list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return List.unmodifiable(list);
  }

  static Dio _createDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 30),
      headers: const {
        'User-Agent': 'Linplayer/1.0.0',
      },
    ));
    // 复用全局代理 + 自签名证书放行。
    applyProxyToDio(dio);
    return dio;
  }

  Future<void>? _initFuture;
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    _dir = await _resolveDownloadDir();
    _indexFile = File(p.join(_dir!.path, 'index.json'));
    await _load();
    _initialized = true;
    notifyListeners();
    // 启动时尝试继续此前未完成（被中断）的任务。
    _processQueue();
  }

  /// 下载目录：桌面便携场景放在可执行文件同级 `downloads/`，其余平台用应用支持目录。
  Future<Directory> _resolveDownloadDir() async {
    try {
      if (Platform.isWindows || Platform.isLinux) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final dir = Directory(p.join(exeDir, 'downloads'));
        await dir.create(recursive: true);
        return dir;
      }
    } catch (_) {}
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'downloads'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _load() async {
    try {
      if (!await _indexFile!.exists()) return;
      final raw = await _indexFile!.readAsString();
      if (raw.trim().isEmpty) return;
      final list = DownloadItem.decodeList(raw);
      for (final item in list) {
        // 被中断的“下载中”改为暂停，并按 part 文件实际大小恢复分段进度。
        if (item.status == DownloadStatus.downloading) {
          item.status = DownloadStatus.paused;
        }
        await _syncSegmentsFromDisk(item);
        _items[item.id] = item;
      }
    } catch (e) {
      debugPrint('[Download] 读取下载索引失败: $e');
    }
  }

  Future<void> _syncSegmentsFromDisk(DownloadItem item) async {
    for (var i = 0; i < item.segments.length; i++) {
      final part = File(item.partPath(i));
      if (!await part.exists()) continue;
      final seg = item.segments[i];
      var len = await part.length();
      // 分段文件意外超出区间长度（如僵尸写入）：物理截断，避免拼接后文件错位。
      if (seg.end >= 0 && len > seg.length) {
        try {
          final raf = await part.open(mode: FileMode.append);
          await raf.truncate(seg.length);
          await raf.close();
          len = seg.length;
        } catch (_) {}
      }
      seg.downloaded = seg.end >= 0 ? len.clamp(0, seg.length).toInt() : len;
    }
  }

  Timer? _persistTimer;
  void _persist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _indexFile?.writeAsString(
            DownloadItem.encodeList(_items.values.toList()));
      } catch (e) {
        debugPrint('[Download] 写入下载索引失败: $e');
      }
    });
  }

  void _emit({bool force = false}) {
    final now = _emitClock.elapsedMilliseconds;
    if (!force && now - _lastEmitMs < 350) return;
    _lastEmitMs = now;
    notifyListeners();
  }

  // ==================== 对外操作 ====================

  DownloadItem? byItemId(String itemId) {
    for (final i in _items.values) {
      if (i.itemId == itemId) return i;
    }
    return null;
  }

  /// 已下载完成的本地文件路径（不存在/未完成返回 null）。
  String? completedFilePath(String itemId) {
    final i = byItemId(itemId);
    if (i != null && i.status == DownloadStatus.completed) return i.filePath;
    return null;
  }

  /// 新增一个下载任务。已存在则直接返回原任务。
  Future<DownloadItem?> enqueue({
    required String itemId,
    String? mediaSourceId,
    required String type,
    required String title,
    String? seriesId,
    String? seriesName,
    int? seasonNumber,
    int? episodeNumber,
    String? posterUrl,
    required String container,
    required String url,
  }) async {
    if (!_initialized) await initialize();

    // 以 itemId 作为唯一键：同一条目只保留一条下载记录（无论从单集还是整剧入队）。
    final id = itemId;
    final existing = _items[id];
    if (existing != null) {
      // 失败/取消的任务重新入队。
      if (existing.status == DownloadStatus.failed ||
          existing.status == DownloadStatus.canceled) {
        existing.status = DownloadStatus.queued;
        existing.error = null;
        _persist();
        _emit(force: true);
        _processQueue();
      }
      return existing;
    }

    final safeContainer =
        container.trim().isEmpty ? 'mkv' : container.trim().toLowerCase();
    final fileName = '${_safeName(title)}_$itemId.$safeContainer';
    final filePath = p.join(_dir!.path, fileName);

    final item = DownloadItem(
      id: id,
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      type: type,
      title: title,
      seriesId: seriesId,
      seriesName: seriesName,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      posterUrl: posterUrl,
      container: safeContainer,
      url: url,
      filePath: filePath,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _items[id] = item;
    _persist();
    _emit(force: true);
    _processQueue();
    return item;
  }

  Future<void> pause(String id) async {
    final item = _items[id];
    if (item == null) return;
    item.status = DownloadStatus.paused;
    if (_activeId == id) {
      for (final t in _activeTokens) {
        if (!t.isCancelled) t.cancel('paused');
      }
    }
    _persist();
    _emit(force: true);
  }

  Future<void> resume(String id) async {
    final item = _items[id];
    if (item == null) return;
    if (item.status == DownloadStatus.completed) return;
    item.status = DownloadStatus.queued;
    item.error = null;
    _persist();
    _emit(force: true);
    _processQueue();
  }

  /// 重试失败任务。
  Future<void> retry(String id) => resume(id);

  /// 删除任务并清理文件。
  Future<void> remove(String id) async {
    final item = _items[id];
    if (item == null) return;

    if (_activeId == id) {
      item.status = DownloadStatus.canceled;
      _pendingRemoval.add(id);
      for (final t in _activeTokens) {
        if (!t.isCancelled) t.cancel('removed');
      }
      // 文件清理交由活跃任务收尾时处理，避免与下载流写入竞争。
      _emit(force: true);
      return;
    }

    _items.remove(id);
    await _deleteFiles(item);
    _persist();
    _emit(force: true);
  }

  Future<void> _deleteFiles(DownloadItem item) async {
    try {
      final f = File(item.filePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    for (var i = 0; i < item.segments.length; i++) {
      try {
        final part = File(item.partPath(i));
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  // ==================== 下载核心 ====================

  void _processQueue() {
    if (!_initialized) return;
    if (_activeId != null) return; // 同一时刻仅一个文件
    DownloadItem? next;
    for (final i in _items.values) {
      if (i.status == DownloadStatus.queued) {
        if (next == null || i.addedAt < next.addedAt) next = i;
      }
    }
    if (next == null) return;
    unawaited(_startDownload(next));
  }

  Future<void> _startDownload(DownloadItem item) async {
    _activeId = item.id;
    item.status = DownloadStatus.downloading;
    item.error = null;
    _emit(force: true);

    try {
      if (item.totalBytes <= 0 && item.segments.isEmpty) {
        await _probe(item);
      }
      if (item.segments.isEmpty) {
        _buildSegments(item);
      } else {
        await _syncSegmentsFromDisk(item);
      }

      final tokens =
          List.generate(item.segments.length, (_) => CancelToken());
      _activeTokens = tokens;

      await Future.wait([
        for (var i = 0; i < item.segments.length; i++)
          _runSegment(item, i, tokens[i]),
      ]);

      // 全部分段完成 → 拼接为最终文件。
      await _assemble(item);
      if (item.totalBytes <= 0) item.totalBytes = item.receivedBytes;
      item.status = DownloadStatus.completed;
      _persist();
      _emit(force: true);
    } catch (e) {
      // 任一分段出错/被取消：立即取消其余分段，避免脱离管理的“僵尸”下载继续写入。
      for (final t in _activeTokens) {
        if (!t.isCancelled) t.cancel('aborted');
      }
      // pause / cancel 会预先把状态置为 paused/canceled；其余视为失败。
      if (item.status == DownloadStatus.downloading) {
        item.status = DownloadStatus.failed;
        item.error = _friendlyError(e);
        debugPrint('[Download] 失败 ${item.title}: $e');
      }
      _persist();
      _emit(force: true);
    } finally {
      _activeId = null;
      _activeTokens = [];
      // 若该任务在下载中被请求删除，此处统一清理。
      if (_pendingRemoval.remove(item.id)) {
        _items.remove(item.id);
        await _deleteFiles(item);
        _persist();
        _emit(force: true);
      }
      _processQueue();
    }
  }

  /// 探测文件大小与 Range 支持。
  Future<void> _probe(DownloadItem item) async {
    try {
      final resp = await _dio.get<ResponseBody>(
        item.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0'},
          followRedirects: true,
          validateStatus: (s) => s != null && s < 400,
        ),
      );
      final status = resp.statusCode ?? 0;
      final headers = resp.headers;
      int total = 0;
      bool supportsRange = false;

      final contentRange = headers.value('content-range');
      if (status == 206 && contentRange != null && contentRange.contains('/')) {
        total = int.tryParse(contentRange.split('/').last.trim()) ?? 0;
        supportsRange = true;
      } else {
        total = int.tryParse(headers.value('content-length') ?? '') ?? 0;
        final ar = headers.value('accept-ranges');
        supportsRange = ar != null && ar.toLowerCase().contains('bytes');
      }
      // 丢弃探测响应体。
      await resp.data?.stream.drain<void>().catchError((_) {});

      if (total > 0) item.totalBytes = total;
      item.supportsRange = supportsRange;
    } catch (e) {
      // 探测失败不致命：退回单线程、未知大小。
      item.supportsRange = false;
      debugPrint('[Download] 探测失败，退回单线程: $e');
    }
  }

  void _buildSegments(DownloadItem item) {
    final total = item.totalBytes;
    if (total <= 0 || !item.supportsRange) {
      // 未知大小或不支持 Range：单段、整流下载。
      item.segments = [DownloadSegment(start: 0, end: -1)];
      return;
    }
    // 小文件不分段。
    final n = total < 2 * 1024 * 1024 ? 1 : _threads.clamp(1, 4).toInt();
    final chunk = (total / n).ceil();
    final segs = <DownloadSegment>[];
    for (var i = 0; i < n; i++) {
      final start = i * chunk;
      if (start >= total) break;
      final end = i == n - 1 ? total - 1 : (start + chunk - 1);
      segs.add(DownloadSegment(
        start: start,
        end: end > total - 1 ? total - 1 : end,
      ));
    }
    item.segments = segs;
  }

  Future<void> _runSegment(
      DownloadItem item, int index, CancelToken token) async {
    final seg = item.segments[index];
    final partFile = File(item.partPath(index));

    int existing = 0;
    if (await partFile.exists()) {
      existing = await partFile.length();
      if (seg.end >= 0 && existing > seg.length) existing = seg.length;
    }
    seg.downloaded = existing;
    if (seg.end >= 0 && seg.isComplete) return;

    final headers = <String, dynamic>{};
    if (item.supportsRange) {
      if (seg.end >= 0) {
        headers['Range'] = 'bytes=${seg.start + existing}-${seg.end}';
      } else if (existing > 0) {
        headers['Range'] = 'bytes=$existing-';
      }
    }

    final resp = await _dio.get<ResponseBody>(
      item.url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        followRedirects: true,
        validateStatus: (s) => s != null && s < 400,
      ),
    );

    final raf = await partFile.open(mode: FileMode.writeOnlyAppend);
    try {
      await for (final chunk in resp.data!.stream) {
        if (token.isCancelled) break;
        await raf.writeFrom(chunk);
        seg.downloaded += chunk.length;
        _emit();
      }
    } finally {
      await raf.close();
    }

    if (token.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: item.url),
        reason: 'paused',
      );
    }
  }

  Future<void> _assemble(DownloadItem item) async {
    final out = File(item.filePath);
    if (await out.exists()) await out.delete();
    final sink = out.openWrite();
    try {
      for (var i = 0; i < item.segments.length; i++) {
        final part = File(item.partPath(i));
        if (await part.exists()) {
          await sink.addStream(part.openRead());
        }
      }
    } finally {
      await sink.close();
    }
    for (var i = 0; i < item.segments.length; i++) {
      try {
        final part = File(item.partPath(i));
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  String _friendlyError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '连接超时';
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode;
          if (code == 401 || code == 403) return '无下载权限';
          return '服务器错误($code)';
        case DioExceptionType.connectionError:
          return '网络连接失败';
        default:
          return '下载出错';
      }
    }
    return '下载出错';
  }

  String _safeName(String name) {
    var s = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (s.length > 60) s = s.substring(0, 60);
    return s.isEmpty ? 'video' : s;
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    for (final t in _activeTokens) {
      if (!t.isCancelled) t.cancel('dispose');
    }
    _dio.close(force: true);
    super.dispose();
  }
}
