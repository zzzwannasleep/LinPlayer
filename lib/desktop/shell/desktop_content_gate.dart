import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_providers.dart';

/// 内容页守卫：未添加服务器时，把需要服务器的内容页(媒体库/收藏/下载)换成
/// 「请先添加服务器」提示，而不是强制把用户锁在服务器页。
///
/// 分支索引：0 首页 · 1 媒体库 · 2 收藏 · 3 下载 · 4 服务器 · 5 设置。
/// 首页(0)自带空状态引导、设置(5)与服务器(4)本就该随时可看，故只兜 1–3。
class DesktopContentGate extends ConsumerWidget {
  final int index;
  final Widget child;

  const DesktopContentGate({
    super.key,
    required this.index,
    required this.child,
  });

  static const _needsServerBranches = {1, 2, 3};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);
    if (servers.isEmpty && _needsServerBranches.contains(index)) {
      return const _NoServerPlaceholder();
    }
    return child;
  }
}

class _NoServerPlaceholder extends StatelessWidget {
  const _NoServerPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined, size: 56, color: theme.hintColor),
          const SizedBox(height: 16),
          Text('请先添加服务器', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '添加 Emby 服务器后即可浏览此页面',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => context.go('/servers'),
            icon: const Icon(Icons.add),
            label: const Text('前往服务器管理'),
          ),
        ],
      ),
    );
  }
}
