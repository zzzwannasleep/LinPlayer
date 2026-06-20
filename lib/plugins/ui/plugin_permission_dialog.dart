import 'package:flutter/material.dart';

import '../models/plugin_manifest.dart';

/// 弹出权限同意弹窗。返回 true 表示用户同意启用。
///
/// 启用插件前必须经过此确认（权限声明制）。
Future<bool> showPluginPermissionConsent(
  BuildContext context,
  PluginManifest manifest,
) async {
  final perms = manifest.resolvedPermissions;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text('启用「${manifest.name}」'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '作者：${manifest.author}　版本：${manifest.version}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (manifest.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(manifest.description),
              ],
              const SizedBox(height: 16),
              const Text(
                '该插件申请以下权限：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (perms.isEmpty)
                const Text('（未申请额外权限）')
              else
                ...perms.map((perm) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            perm.dangerous
                                ? Icons.warning_amber_rounded
                                : Icons.check_circle_outline,
                            size: 20,
                            color: perm.dangerous
                                ? Colors.orange
                                : Colors.green,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(perm.title,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                Text(
                                  perm.description,
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )),
              if (manifest.permissions.contains('http')) ...[
                const SizedBox(height: 12),
                Builder(builder: (context) {
                  final raw = manifest.raw['httpAllowedHosts'];
                  final hosts = (raw is List)
                      ? raw
                          .map((e) => '$e')
                          .where((e) => e.isNotEmpty)
                          .toList()
                      : const <String>[];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hosts.isEmpty
                            ? '可访问的网络域名：无（未声明白名单，将无法联网）'
                            : '仅可访问以下网络域名：',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      ...hosts.map((h) => Text('· $h',
                          style: Theme.of(context).textTheme.bodySmall)),
                    ],
                  );
                }),
              ],
              if (manifest.extensions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '将挂载扩展点：${manifest.extensions.map((e) => e.type.id).toSet().join('、')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('同意并启用'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
