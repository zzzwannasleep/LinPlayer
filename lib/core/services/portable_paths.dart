import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 便携化路径:让 Windows/Linux 压缩包版把**所有**应用数据写在「程序目录」内,
/// 实现「解压即用、各副本互不影响、覆盖更新不丢配置、不污染系统目录」。
///
/// 原理:Windows 上 SharedPreferences(设置/服务器列表)、flutter_secure_storage
/// 的 DPAPI 密文(密码/Token)、观看记录、字体、mpv.conf、whisper 模型、日志,
/// 几乎全部经由 `path_provider` 的 `getApplicationSupportDirectory` /
/// `getApplicationDocumentsDirectory` / `getTemporaryDirectory` 落盘。只要在启动
/// 最早期把 [PathProviderPlatform.instance] 整体重定向到程序目录下的 `userdata/`,
/// 这些数据就**一处全收**地搬进压缩包文件夹,且密码在 Windows 上仍是 DPAPI 真加密
/// (无安全降级)。
///
/// 触发条件:仅 Windows/Linux 且程序目录可写时启用(与缓存/插件/下载现有便携策略
/// 一致)。装到只读位置(如 `Program Files`)时探针失败 → 保持系统默认目录,自动回退。
///
/// 目录名用 `userdata/` 而非 `data/`:后者是 Flutter Windows 自带资源目录
/// (flutter_assets/icudtl.dat),覆盖更新需要被替换;`userdata/` 与之分离,
/// 覆盖更新只动程序文件、不动 `userdata/`,用户配置得以保留。
///
/// Linux 注意:`flutter_secure_storage_linux` 走系统 libsecret 钥匙串(不经
/// path_provider),故 Linux 上密码/Token 仍在系统钥匙串;其余数据照样便携。
class PortablePathProvider extends PathProviderPlatform {
  PortablePathProvider._(this._root, this._delegate);

  final String _root;
  final PathProviderPlatform _delegate;

  static String? _activeRoot;

  /// 已启用便携模式时返回 `userdata/` 根目录;未启用返回 null。
  static String? get activeRoot => _activeRoot;

  /// 在 [runApp] 与任何 path_provider 调用之前调用一次。
  ///
  /// 可行则把全局 PathProvider 重定向进程序目录,并对老用户做一次性
  /// `%APPDATA%`(旧应用支持目录)→ `userdata/app_support` 的配置迁移。
  static Future<void> ensureInstalled() async {
    if (!(Platform.isWindows || Platform.isLinux)) return;
    if (_activeRoot != null) return;

    final delegate = PathProviderPlatform.instance;
    String root;
    bool freshlyCreated;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      root = p.join(exeDir, 'userdata');
      final dir = Directory(root);
      freshlyCreated = !dir.existsSync();
      if (freshlyCreated) dir.createSync(recursive: true);
      // 写探针确认可写;装到只读位置则放弃便携,回退系统目录。
      final probe = File(p.join(root, '.write_test'));
      probe.writeAsStringSync('ok');
      probe.deleteSync();
    } catch (_) {
      return; // 不可写 → 保持系统默认目录。
    }

    final provider = PortablePathProvider._(root, delegate);

    // 老用户迁移:首次创建 userdata 时,把旧应用支持目录的配置整体搬进来,
    // 避免升级到便携版后「设置全没了」。仅迁一次,失败不阻断启动。
    if (freshlyCreated) {
      await _migrateLegacySupport(delegate, provider._sub('app_support'));
    }

    _activeRoot = root;
    PathProviderPlatform.instance = provider;
  }

  /// 把旧的系统应用支持目录(含 SharedPreferences、安全存储密文、观看记录、
  /// 字体、mpv.conf 等)递归复制进便携目录。仅在目标为空时复制,绝不覆盖。
  static Future<void> _migrateLegacySupport(
      PathProviderPlatform delegate, Directory dest) async {
    try {
      final oldPath = await delegate.getApplicationSupportPath();
      if (oldPath == null) return;
      final oldDir = Directory(oldPath);
      if (!oldDir.existsSync()) return;
      if (p.equals(oldDir.path, dest.path)) return;
      // 目标已有内容则视为已迁移/用户已用过,跳过。
      if (dest.existsSync() && dest.listSync().isNotEmpty) return;
      if (!dest.existsSync()) dest.createSync(recursive: true);
      await _copyDirInto(oldDir, dest);
    } catch (_) {
      // 迁移失败就当全新开始,不影响使用。
    }
  }

  static Future<void> _copyDirInto(Directory src, Directory dest) async {
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        final sub = Directory(p.join(dest.path, name));
        if (!sub.existsSync()) sub.createSync(recursive: true);
        await _copyDirInto(entity, sub);
      } else if (entity is File) {
        try {
          await entity.copy(p.join(dest.path, name));
        } catch (_) {
          // 单个文件(如被占用)复制失败就跳过。
        }
      }
    }
  }

  Directory _sub(String name) {
    final d = Directory(p.join(_root, name));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  // ---- 重定向进程序目录的四类应用数据 ----
  @override
  Future<String?> getApplicationSupportPath() async => _sub('app_support').path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _sub('documents').path;

  @override
  Future<String?> getApplicationCachePath() async => _sub('cache').path;

  @override
  Future<String?> getTemporaryPath() async => _sub('temp').path;

  // ---- 其余交回原实现 ----
  @override
  Future<String?> getLibraryPath() => _delegate.getLibraryPath();

  @override
  Future<String?> getDownloadsPath() => _delegate.getDownloadsPath();

  @override
  Future<String?> getExternalStoragePath() => _delegate.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() =>
      _delegate.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _delegate.getExternalStoragePaths(type: type);
}
