import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../core/services/app_logger.dart';
import '../models/plugin_info.dart';
import '../models/plugin_manifest.dart';

/// 安装/卸载错误。
class PluginInstallError implements Exception {
  final String message;
  PluginInstallError(this.message);
  @override
  String toString() => 'PluginInstallError: $message';
}

/// 负责 .ipk 包的解压、清单校验与落盘。
///
/// .ipk = 一个 zip，至少包含 manifest.json 与 main.js，可附带 assets。
/// 允许包内带一层根目录（会自动剥离）。兼容旧的 .lpk（同为 zip）。
class PluginInstaller {
  static final AppLogger _log = AppLogger();

  /// 所有插件的根目录（各平台文档目录下的 plugins/）。
  final String pluginsRootDir;

  PluginInstaller(this.pluginsRootDir);

  /// 从 .ipk 文件安装，返回安装后的插件信息（默认禁用状态）。兼容旧 .lpk。
  Future<PluginInfo> installFromLpkFile(String lpkPath) async {
    final file = File(lpkPath);
    if (!await file.exists()) {
      throw PluginInstallError('文件不存在: $lpkPath');
    }
    final bytes = await file.readAsBytes();
    return installFromBytes(bytes);
  }

  Future<PluginInfo> installFromBytes(List<int> bytes) async {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw PluginInstallError('无法解析 .ipk（zip）文件: $e');
    }

    // 找到 manifest.json，计算需要剥离的根目录前缀。
    final manifestEntry = _findEntry(archive, 'manifest.json');
    if (manifestEntry == null) {
      throw PluginInstallError('包内缺少 manifest.json');
    }
    final prefix = _rootPrefixOf(manifestEntry.name);

    // 解析并校验清单。
    final manifestJson = _decodeJson(manifestEntry.content as List<int>);
    final manifest = PluginManifest.fromJson(manifestJson);

    // 目标目录：pluginsRoot/<id>。重装/升级会覆盖。
    final targetDir = Directory(p.join(pluginsRootDir, manifest.id));
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    // 落盘所有文件（剥离根前缀，防目录穿越）。
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final rel = _stripPrefix(entry.name, prefix);
      if (rel.isEmpty) continue;
      final safe = _safeJoin(targetDir.path, rel);
      if (safe == null) {
        _log.w('PluginInstaller', '跳过越界路径: ${entry.name}');
        continue;
      }
      final outFile = File(safe);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>);
    }

    final entryPath = p.join(targetDir.path, manifest.main);
    if (!await File(entryPath).exists()) {
      await targetDir.delete(recursive: true);
      throw PluginInstallError('包内缺少入口文件: ${manifest.main}');
    }

    _log.i('PluginInstaller', '已安装插件 ${manifest.id} v${manifest.version}');
    return PluginInfo(
      manifest: manifest,
      directory: targetDir.path,
      entryPath: entryPath,
      status: PluginStatus.disabled,
    );
  }

  /// 从已存在的插件目录加载清单（扫描时使用）。
  Future<PluginInfo> loadFromDirectory(String dir) async {
    final manifestFile = File(p.join(dir, 'manifest.json'));
    if (!await manifestFile.exists()) {
      throw PluginInstallError('目录缺少 manifest.json: $dir');
    }
    final manifest =
        PluginManifest.fromJson(_decodeJson(await manifestFile.readAsBytes()));
    final entryPath = p.join(dir, manifest.main);
    if (!await File(entryPath).exists()) {
      throw PluginInstallError('目录缺少入口文件 ${manifest.main}: $dir');
    }
    return PluginInfo(
      manifest: manifest,
      directory: dir,
      entryPath: entryPath,
      status: PluginStatus.disabled,
    );
  }

  /// 卸载：删除插件目录。
  Future<void> uninstall(String directory) async {
    final dir = Directory(directory);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  // ---- 辅助 ----

  Map<String, dynamic> _decodeJson(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw PluginInstallError('manifest.json 顶层必须是对象');
    }
    return decoded;
  }

  ArchiveFile? _findEntry(Archive archive, String fileName) {
    for (final e in archive) {
      if (!e.isFile) continue;
      if (p.basename(e.name) == fileName) return e;
    }
    return null;
  }

  /// manifest 所在目录前缀（含尾部 /），用于剥离单层根目录。
  String _rootPrefixOf(String manifestPath) {
    final dir = p.url.dirname(manifestPath.replaceAll('\\', '/'));
    if (dir == '.' || dir.isEmpty) return '';
    return '$dir/';
  }

  String _stripPrefix(String name, String prefix) {
    final normalized = name.replaceAll('\\', '/');
    if (prefix.isNotEmpty && normalized.startsWith(prefix)) {
      return normalized.substring(prefix.length);
    }
    return normalized;
  }

  /// 安全 join：拒绝逃出 base 的路径（防 ../ 穿越）。
  String? _safeJoin(String base, String rel) {
    final target = p.normalize(p.join(base, rel));
    final normalizedBase = p.normalize(base);
    if (!p.isWithin(normalizedBase, target)) return null;
    return target;
  }
}
