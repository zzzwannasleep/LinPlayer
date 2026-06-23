import 'package:flutter/foundation.dart';

import '../providers/server_providers.dart';
import 'media_source_backend.dart';
import 'source_registry.dart';

/// 面包屑里的一层目录。
class BrowseFrame {
  final String? dirId; // null = 根目录
  final String name;
  const BrowseFrame(this.dirId, this.name);
}

/// 文件浏览型源的浏览状态机（UI 框架无关，三端视图共用）。
///
/// 管理目录栈（面包屑）、加载/错误态、源内搜索。视图只需 [addListener] 后
/// 渲染 [entries]/[loading]/[error]，并调用 [enterDir]/[goUp]/[search] 等。
class SourceBrowseController extends ChangeNotifier {
  final ServerConfig server;
  final MediaSourceBackend backend;

  SourceBrowseController(this.server)
      : backend = mediaSourceBackendFor(server.sourceKind);

  final List<BrowseFrame> _stack = [];
  List<SourceEntry> entries = const [];
  bool loading = false;
  String? error;

  String _searchQuery = '';
  bool _searching = false;

  String get searchQuery => _searchQuery;
  bool get isSearching => _searching;
  bool get supportsSearch {
    // 探测：尝试调用一次 search 的能力靠 try/catch，先乐观为 true，
    // 真正 search 抛 UnsupportedError 时降级本地过滤。
    return true;
  }

  List<BrowseFrame> get breadcrumb => List.unmodifiable(_stack);
  bool get canGoUp => _stack.length > 1;
  BrowseFrame get current =>
      _stack.isNotEmpty ? _stack.last : BrowseFrame(null, server.name);

  /// 进入根目录（初始化时调用）。
  Future<void> openRoot() async {
    _stack
      ..clear()
      ..add(BrowseFrame(null, server.name));
    await _load();
  }

  Future<void> enterDir(SourceEntry entry) async {
    if (!entry.isDir) return;
    _stack.add(BrowseFrame(entry.id, entry.name));
    await _load();
  }

  Future<void> goUp() async {
    if (!canGoUp) return;
    _stack.removeLast();
    await _load();
  }

  /// 跳到面包屑第 [index] 层。
  Future<void> goToCrumb(int index) async {
    if (index < 0 || index >= _stack.length) return;
    _stack.removeRange(index + 1, _stack.length);
    await _load();
  }

  Future<void> refresh() => _searching ? _runSearch(_searchQuery) : _load();

  Future<void> _load() async {
    _searching = false;
    _searchQuery = '';
    loading = true;
    error = null;
    notifyListeners();
    try {
      entries = await backend.listDir(server, dirId: current.dirId);
    } on SourceException catch (e) {
      error = e.message;
    } catch (e) {
      error = '加载失败: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 源内搜索。源不支持时降级为当前目录本地名称过滤。
  Future<void> search(String query) async {
    final q = query.trim();
    _searchQuery = query;
    if (q.isEmpty) {
      await _load();
      return;
    }
    await _runSearch(query);
  }

  Future<void> _runSearch(String query) async {
    final q = query.trim();
    _searching = true;
    loading = true;
    error = null;
    notifyListeners();
    try {
      entries = await backend.search(server, q);
    } on UnsupportedError {
      // 源端不支持搜索：退回「当前目录本地过滤」。
      try {
        final all = await backend.listDir(server, dirId: current.dirId);
        final lower = q.toLowerCase();
        entries = all.where((e) => e.name.toLowerCase().contains(lower)).toList();
      } catch (e) {
        error = '搜索失败: $e';
      }
    } on SourceException catch (e) {
      error = e.message;
    } catch (e) {
      error = '搜索失败: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void clearSearch() {
    if (!_searching && _searchQuery.isEmpty) return;
    _load();
  }
}
