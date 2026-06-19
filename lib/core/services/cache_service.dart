import 'dart:io';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import '../utils/platform_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 缓存管理服务。
///
/// 三类磁盘数据，互不混淆：
/// 1. 图片缓存 `persistent_image_cache`：海报等，持久化。**6GB 上限 + 14 天过期**。
/// 2. 视频播放缓存 `video_stream_cache`：播放时 mpv 的 on-disk demuxer 缓存，
///    临时数据，仅用于把播放缓冲从内存移到磁盘以防 OOM。大小由用户设置
///    （300MB–8GB）控制，启动时清空残留。
/// 3. 下载 `downloads`：用户主动下载的影片 —— **不属于缓存，绝不自动删除**。
class CacheService {
  static const _imageCacheExpiryDaysKey = 'linplayer_image_cache_expiry_days';
  static const _videoCacheMaxSizeMBKey = 'linplayer_video_cache_max_size_mb';
  static const _pgsBlendModeKey = 'linplayer_pgs_blend_mode';

  /// 图片磁盘缓存硬上限：6GB。
  static const int imageCacheMaxBytes = 6 * 1024 * 1024 * 1024;

  /// 视频播放缓存大小范围（MB）。
  static const int videoCacheMinMB = 300;
  static const int videoCacheMaxMB = 8192;
  static const int videoCacheDefaultMB = 1024;

  static const int imageCacheDefaultExpiryDays = 14;

  static String? _cacheRootCache;

  /// 所有缓存的根目录：一个统一的 `temp` 文件夹，自包含、不污染系统目录。
  ///
  /// - Windows/Linux（便携版/压缩包）：放在**程序所在目录**下的 `temp/`，
  ///   随软件目录走，删除软件即删除全部缓存，干净。
  /// - macOS(.app 只读) / 移动端：回退到系统应用缓存目录下的 `temp/`。
  /// - 若程序目录不可写（如装到无写权限的位置）：回退到系统应用缓存目录。
  static Future<String> get cacheRootDirPath async {
    if (_cacheRootCache != null) return _cacheRootCache!;

    String? root;
    if (Platform.isWindows || Platform.isLinux) {
      try {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidate = path.join(exeDir, 'temp');
        final dir = Directory(candidate);
        if (!await dir.exists()) await dir.create(recursive: true);
        root = candidate; // 创建成功即视为可写
      } catch (_) {
        root = null; // 落到下面的回退
      }
    }

    root ??= path.join((await getApplicationCacheDirectory()).path, 'temp');
    final rootDir = Directory(root);
    if (!await rootDir.exists()) {
      await rootDir.create(recursive: true);
    }
    _cacheRootCache = root;
    return root;
  }

  /// 图片缓存目录（与 PersistentNetworkImageProvider 共用同一路径）。
  static Future<String> get imageCacheDirPath async {
    final dir = path.join(await cacheRootDirPath, 'image_cache');
    final directory = Directory(dir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return dir;
  }

  static Future<String> get _imageCacheDirPath => imageCacheDirPath;

  /// 视频播放缓存目录（mpv on-disk 缓存写到这里）。临时数据，启动时清空残留。
  static Future<String> get videoStreamCacheDirPath async {
    final dir = path.join(await cacheRootDirPath, 'video_cache');
    final directory = Directory(dir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return dir;
  }

  // ---- 设置项 ----

  static Future<int> getImageCacheExpiryDays() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_imageCacheExpiryDaysKey) ?? imageCacheDefaultExpiryDays;
  }

  static Future<void> setImageCacheExpiryDays(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_imageCacheExpiryDaysKey, days);
  }

  static Future<int> getVideoCacheMaxSizeMB() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_videoCacheMaxSizeMBKey) ?? videoCacheDefaultMB;
    return value.clamp(videoCacheMinMB, videoCacheMaxMB);
  }

  static Future<void> setVideoCacheMaxSizeMB(int mb) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _videoCacheMaxSizeMBKey,
      mb.clamp(videoCacheMinMB, videoCacheMaxMB),
    );
  }

  /// PGS/SUP 图形字幕的混合渲染模式（mpv `blend-subtitles`）：
  /// 'no'（OSD 覆盖层，默认）/ 'video'（混合到视频分辨率）/ 'yes'（混合到输出帧）。
  /// 实验性开关——用于排查图形字幕在 UI 重绘（开面板/滑动）时的画面闪现。
  static Future<String> getPgsBlendMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_pgsBlendModeKey);
    return (v == 'yes' || v == 'video') ? v! : 'no';
  }

  /// mpv 解复用缓冲（前向/后向）的 RAM 安全预算，单位字节。
  ///
  /// 关键修复：`demuxer-max-bytes` 控制的是**常驻内存**的解复用包队列。即便开启
  /// `cache-on-disk`，其索引/工作集仍在 RAM，且部分 libmpv 构建未必真把负载落盘
  /// （曾观测播放时 RAM 飙到 2GB+、"没落盘"）。因此把它与用户的磁盘缓存档位
  /// （300MB–8GB）**解耦**，按平台硬限上限——桌面 384/128MiB，移动/TV 192/64MiB，
  /// 杜绝 GB 级 RAM 占用导致的卡顿/OOM。磁盘缓存仍由 cache-on-disk 在此预算内承接。
  static Future<({int forward, int back})> getDemuxerRamBudgetBytes() async {
    final mb = await getVideoCacheMaxSizeMB();
    final total = mb * 1024 * 1024;
    final forwardCeil =
        (isDesktopPlatform ? 384 : 192) * 1024 * 1024;
    final backCeil = (isDesktopPlatform ? 128 : 64) * 1024 * 1024;
    final forward = (total * 3) ~/ 4;
    final back = total ~/ 4;
    return (
      forward: forward > forwardCeil ? forwardCeil : forward,
      back: back > backCeil ? backCeil : back,
    );
  }

  // ---- 体积统计 ----

  static Future<int> getImageCacheSize() async {
    return _calculateDirectorySize(await _imageCacheDirPath);
  }

  static Future<int> getVideoCacheSize() async {
    return _calculateDirectorySize(await videoStreamCacheDirPath);
  }

  static Future<int> getTotalCacheSize() async {
    return await getImageCacheSize() + await getVideoCacheSize();
  }

  static Future<int> _calculateDirectorySize(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;

    int totalSize = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          totalSize += await entity.length();
        } catch (_) {}
      }
    }
    return totalSize;
  }

  // ---- 图片缓存清理 ----

  /// 删除超过过期天数的图片缓存文件。
  static Future<void> clearExpiredImageCache() async {
    final days = await getImageCacheExpiryDays();
    final dirPath = await _imageCacheDirPath;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    final cutoff = DateTime.now().subtract(Duration(days: days));
    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          final lastMod = await entity.lastModified();
          if (lastMod.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {}
      }
    }
  }

  /// 把图片缓存总体积限制在 [imageCacheMaxBytes]（6GB）内，超出时按最早访问优先删除。
  static Future<void> enforceImageCacheLimit() async {
    final dirPath = await _imageCacheDirPath;
    await _enforceDirSizeLimit(dirPath, imageCacheMaxBytes);
  }

  static Future<void> clearAllImageCache() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    final dirPath = await _imageCacheDirPath;
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  // ---- 视频播放缓存清理 ----

  /// 清空视频播放缓存目录（临时数据，可随时清）。
  static Future<void> clearVideoCache() async {
    final dirPath = await videoStreamCacheDirPath;
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
  }

  /// 把视频播放缓存限制在用户设置的上限内（兜底，正常由 mpv 自行管理）。
  static Future<void> enforceVideoCacheLimit() async {
    final maxMB = await getVideoCacheMaxSizeMB();
    final dirPath = await videoStreamCacheDirPath;
    await _enforceDirSizeLimit(dirPath, maxMB * 1024 * 1024);
  }

  static Future<void> clearAllCache() async {
    await clearAllImageCache();
    await clearVideoCache();
  }

  /// 通用：把目录体积压到 [maxBytes] 以内，按最早修改时间优先删除。
  static Future<void> _enforceDirSizeLimit(String dirPath, int maxBytes) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    final files = <(File, DateTime, int)>[];
    int currentSize = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          files.add((entity, stat.modified, stat.size));
          currentSize += stat.size;
        } catch (_) {}
      }
    }

    if (currentSize <= maxBytes) return;

    files.sort((a, b) => a.$2.compareTo(b.$2)); // 最早的先删

    int freed = 0;
    final target = currentSize - maxBytes;
    for (final entry in files) {
      if (freed >= target) break;
      try {
        await entry.$1.delete();
        freed += entry.$3;
      } catch (_) {}
    }
  }

  /// 启动时的后台清理：图片过期 + 图片 6GB 上限 + 清空残留的视频播放缓存。
  /// 应以非阻塞方式调用（不要在 runApp 之前 await）。
  static Future<void> runStartupCleanup() async {
    try {
      await clearExpiredImageCache();
      await enforceImageCacheLimit();
      // 视频播放缓存是临时数据，启动时上次残留可直接清空。
      await clearVideoCache();
    } catch (_) {
      // 清理失败不影响启动。
    }
  }

  /// 配置内存图片缓存上限（按平台分级，对低内存机器友好）。
  /// 解码位图只在内存保留少量，磁盘持久化由 PersistentNetworkImageProvider 负责。
  ///
  /// 桌面内存充足，给较大的解码缓存换取滚动流畅；移动/TV 内存吃紧（TV 盒子
  /// 常见仅 1–2GB），收紧到 ~48MB / 240 张，避免解码位图堆积触发 OOM 闪退。
  /// 单张解码已被 MediaImage 钳制在 1280 长边（≈3.7MB），按张数与字节双限。
  static void configureMemoryCache() {
    final cache = PaintingBinding.instance.imageCache;
    if (isDesktopPlatform) {
      cache.maximumSize = 600;
      cache.maximumSizeBytes = 96 * 1024 * 1024;
    } else {
      cache.maximumSize = 240;
      cache.maximumSizeBytes = 48 * 1024 * 1024;
    }
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = bytes.toDouble();
    int unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  static String formatSizeMB(int mb) {
    if (mb >= 1024) {
      final gb = mb / 1024;
      return '${gb.toStringAsFixed(gb.truncateToDouble() == gb ? 0 : 1)} GB';
    }
    return '$mb MB';
  }
}
