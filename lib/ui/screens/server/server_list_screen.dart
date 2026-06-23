import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../widgets/common/media_widgets.dart';

/// 服务器列表页面
class ServerListScreen extends ConsumerStatefulWidget {
  const ServerListScreen({super.key});
  
  @override
  ConsumerState<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends ConsumerState<ServerListScreen> {
  String _searchQuery = '';
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    // 延迟恢复当前服务器（等待serverListProvider加载完成）
    Future.microtask(() async {
      final servers = ref.read(serverListProvider);
      if (servers.isNotEmpty) {
        await ref.read(currentServerProvider.notifier).loadFromSaved(servers);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final allServers = ref.watch(serverListProvider);
    final servers = _searchQuery.isEmpty
        ? allServers
        : allServers.where((s) =>
            s.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            s.remark?.toLowerCase().contains(_searchQuery.toLowerCase()) == true ||
            s.activeLineUrl.toLowerCase().contains(_searchQuery.toLowerCase())
          ).toList();
    
    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '搜索服务器...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
                ),
                style: TextStyle(color: Theme.of(context).textTheme.bodyLarge?.color),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : const Text('服务器'),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) _searchQuery = '';
              });
            },
          ),
          if (!_isSearching) ...[
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: () {
                context.push('/downloads');
              },
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () {
                context.push('/add');
              },
            ),
          ],
        ],
      ),
      body: servers.isEmpty 
          ? _buildEmptyState(context)
          : _buildServerList(context, servers),
    );
  }
  
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无服务器',
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              context.push('/add');
            },
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ],
      ),
    );
  }
  
  Widget _buildServerList(BuildContext context, List<ServerConfig> servers) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: servers.length,
      // ignore: deprecated_member_use
      onReorder: (oldIndex, newIndex) {
        ref.read(serverListProvider.notifier).reorderServers(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final server = servers[index];
        return _ServerCard(
          key: ValueKey(server.id),
          server: server,
          onTap: () {
            ref.read(currentServerProvider.notifier).state = server;
            if (server.authToken != null) {
              ref.read(authStateProvider.notifier).state = AuthState.authenticated;
            }
            // 网盘/聚合源 → 文件浏览页；Emby → 原首页。
            context.go(server.isFileBrowse ? '/browse' : '/home');
          },
          onMoreTap: () => _showServerMenu(context, ref, server),
        );
      },
    );
  }
  
  void _showServerMenu(BuildContext context, WidgetRef ref, ServerConfig server) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑信息'),
              onTap: () {
                Navigator.pop(context);
                context.push('/edit/${server.id}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('重新登录'),
              onTap: () {
                Navigator.pop(context);
                _showReloginDialog(context, ref, server);
              },
            ),
            ListTile(
              leading: const Icon(Icons.route),
              title: const Text('服务器线路'),
              onTap: () {
                Navigator.pop(context);
                context.push('/lines/${server.id}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('修改图标'),
              onTap: () {
                Navigator.pop(context);
                context.push('/icons/${server.id}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.notes),
              title: const Text('修改备注'),
              onTap: () {
                Navigator.pop(context);
                _showEditRemarkDialog(context, ref, server);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _showDeleteConfirm(context, ref, server);
              },
            ),
          ],
        ),
      ),
    );
  }
  
  void _showEditRemarkDialog(BuildContext context, WidgetRef ref, ServerConfig server) {
    final controller = TextEditingController(text: server.remark);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改备注'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入备注...',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(serverListProvider.notifier).updateServer(
                server.copyWith(remark: controller.text),
              );
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
  
  void _showDeleteConfirm(BuildContext context, WidgetRef ref, ServerConfig server) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除服务器 "${server.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(serverListProvider.notifier).removeServer(server.id);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
  
  void _showReloginDialog(BuildContext context, WidgetRef ref, ServerConfig server) {
    final usernameCtrl = TextEditingController(text: server.username ?? '');
    final passwordCtrl = TextEditingController();
    var loading = false;
    var error = <String?>[];
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('重新登录'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: usernameCtrl,
                decoration: const InputDecoration(labelText: '用户名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordCtrl,
                decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
                obscureText: true,
              ),
              if (error.isNotEmpty && error.first != null) ...[
                const SizedBox(height: 8),
                Text(error.first!, style: TextStyle(color: Theme.of(ctx).colorScheme.error, fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: loading ? null : () async {
                setDialogState(() { loading = true; error = []; });
                try {
                  final client = EmbyApiClient(baseUrl: server.activeLineUrl);
                  final authResult = await client.auth.login(
                    username: usernameCtrl.text.trim(),
                    password: passwordCtrl.text,
                  );
                  final updated = server.copyWith(
                    authToken: authResult.accessToken,
                    userId: authResult.userId,
                    username: usernameCtrl.text.trim(),
                  );
                  ref.read(serverListProvider.notifier).updateServer(updated);
                  ref.read(currentServerProvider.notifier).state = updated;
                  ref.read(authStateProvider.notifier).state = AuthState.authenticated;
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  setDialogState(() { loading = false; error = [e.toString().replaceAll('Exception: ', '')]; });
                }
              },
              child: loading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  final ServerConfig server;
  final VoidCallback onTap;
  final VoidCallback onMoreTap;
  
  const _ServerCard({
    super.key,
    required this.server,
    required this.onTap,
    required this.onMoreTap,
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.borderRadiusLarge),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF5B8DEF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: server.iconUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: MediaImage(imageUrl: server.iconUrl, width: 48, height: 48, fit: BoxFit.cover, useDefaultUserAgent: true),
                      )
                    : const Icon(Icons.dns, color: Color(0xFF5B8DEF)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (server.remark != null && server.remark!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        server.remark!,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: onMoreTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
