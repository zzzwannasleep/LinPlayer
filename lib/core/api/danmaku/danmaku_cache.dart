import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../api_interfaces.dart';
import '../../services/cache_service.dart';

/// 弹幕缓存：内存 LRU + 磁盘 JSON。
///
/// key = `{sourceId}:{episodeId}`。命中即秒载，配合并行多源避免重复网络请求。
/// 磁盘目录走项目统一缓存根 [CacheService.cacheRootDirPath]（便携自包含，非系统文档目录）。
class DanmakuCache {
  DanmakuCache._();
  static final DanmakuCache instance = DanmakuCache._();

  static const int _memCapacity = 40;
  static const Duration _ttl = Duration(days: 7);

  /// 访问顺序即 LRU 顺序（尾部最新）。
  final Map<String, List<DanmakuItem>> _mem = <String, List<DanmakuItem>>{};

  String? _dirCache;

  String _keyOf(String sourceId, String episodeId) => '$sourceId:$episodeId';

  String _fileNameOf(String key) {
    final hash = md5.convert(utf8.encode(key)).toString();
    return '$hash.json';
  }

  Future<String> _dirPath() async {
    if (_dirCache != null) return _dirCache!;
    final root = await CacheService.cacheRootDirPath;
    final dir = p.join(root, 'danmaku_cache');
    final d = Directory(dir);
    if (!await d.exists()) await d.create(recursive: true);
    _dirCache = dir;
    return dir;
  }

  void _touchMem(String key, List<DanmakuItem> items) {
    _mem.remove(key);
    _mem[key] = items;
    while (_mem.length > _memCapacity) {
      _mem.remove(_mem.keys.first);
    }
  }

  /// 读取缓存。未命中 / 过期返回 null。
  Future<List<DanmakuItem>?> get(String sourceId, String episodeId) async {
    if (sourceId.isEmpty || episodeId.isEmpty) return null;
    final key = _keyOf(sourceId, episodeId);

    final cached = _mem[key];
    if (cached != null) {
      _touchMem(key, cached); // 提升为最近使用
      return cached;
    }

    try {
      final file = File(p.join(await _dirPath(), _fileNameOf(key)));
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final ts = (raw['ts'] as num?)?.toInt() ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > _ttl.inMilliseconds) {
        unawaited(file.delete().catchError((_) => file));
        return null;
      }
      final items = (raw['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(DanmakuItem.fromJson)
          .toList();
      if (items.isEmpty) return null;
      _touchMem(key, items);
      return items;
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存（内存 + 磁盘）。空列表不写。
  Future<void> put(
    String sourceId,
    String episodeId,
    List<DanmakuItem> items,
  ) async {
    if (sourceId.isEmpty || episodeId.isEmpty || items.isEmpty) return;
    final key = _keyOf(sourceId, episodeId);
    _touchMem(key, items);
    try {
      final file = File(p.join(await _dirPath(), _fileNameOf(key)));
      final data = {
        'ts': DateTime.now().millisecondsSinceEpoch,
        'sourceId': sourceId,
        'episodeId': episodeId,
        'items': items.map((e) => e.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // 磁盘写失败不影响内存缓存与本次播放。
    }
  }

  /// 清空全部弹幕缓存（内存 + 磁盘）。返回删除的文件数。
  Future<int> clear() async {
    _mem.clear();
    try {
      final dir = Directory(await _dirPath());
      if (!await dir.exists()) return 0;
      var count = 0;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          await entity.delete();
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 当前磁盘缓存占用字节数。
  Future<int> diskSizeBytes() async {
    try {
      final dir = Directory(await _dirPath());
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
