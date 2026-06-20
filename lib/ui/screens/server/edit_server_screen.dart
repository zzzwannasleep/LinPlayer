import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';

/// 编辑服务器页面
class EditServerScreen extends ConsumerStatefulWidget {
  final String serverId;
  
  const EditServerScreen({super.key, required this.serverId});
  
  @override
  ConsumerState<EditServerScreen> createState() => _EditServerScreenState();
}

class _EditServerScreenState extends ConsumerState<EditServerScreen> {
  final _nameController = TextEditingController();
  bool _allowInsecureTls = false;

  @override
  void initState() {
    super.initState();
    final servers = ref.read(serverListProvider);
    final server = servers.firstWhere((s) => s.id == widget.serverId);
    _nameController.text = server.name;
    _allowInsecureTls = server.allowInsecureTls;
  }
  
  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }
  
  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('服务器名称不能为空')),
      );
      return;
    }
    
    final servers = ref.read(serverListProvider);
    final server = servers.firstWhere((s) => s.id == widget.serverId);

    if (name == server.name && _allowInsecureTls == server.allowInsecureTls) {
      context.pop();
      return;
    }

    final updated = server.copyWith(
      name: name,
      allowInsecureTls: _allowInsecureTls,
    );
    ref.read(serverListProvider.notifier).updateServer(updated);

    // 如果当前选中的就是这个服务器，也更新当前服务器
    final currentServer = ref.read(currentServerProvider);
    if (currentServer?.id == widget.serverId) {
      ref.read(currentServerProvider.notifier).state = updated;
    }

    context.pop();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('服务器已更新')),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑服务器'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '服务器名称',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                hintText: '输入服务器名称',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 24),
            const Text(
              '安全',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).dividerColor,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SwitchListTile(
                value: _allowInsecureTls,
                onChanged: (v) => setState(() => _allowInsecureTls = v),
                title: const Text('信任自签名证书（不安全）'),
                subtitle: Text(
                  _allowInsecureTls
                      ? '已关闭对本服务器的 TLS 证书校验，连接可能被中间人窃听/篡改。仅在你信任的本地网络且使用自签名证书时开启。'
                      : '默认严格校验 HTTPS 证书。若你的服务器使用自签名证书导致无法连接，可在此放行（仅影响本服务器）。',
                  style: const TextStyle(fontSize: 12),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}