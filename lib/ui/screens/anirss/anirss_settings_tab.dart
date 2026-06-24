import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/anirss_token.dart';
import '../../../core/sources/anirss/models/ani_config.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../widgets/anirss/config_form.dart';

/// 设置页：镜像 ani-rss 服务端 Config + 服务器管理 + 关于。
class AniRssSettingsTab extends ConsumerStatefulWidget {
  const AniRssSettingsTab({super.key});

  @override
  ConsumerState<AniRssSettingsTab> createState() => _AniRssSettingsTabState();
}

class _AniRssSettingsTabState extends ConsumerState<AniRssSettingsTab> {
  bool _seeded = false;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final asyncConfig = ref.watch(aniConfigProvider);

    // 配置加载完成后播种草稿一次。
    ref.listen(aniConfigProvider, (_, next) {
      next.whenData((cfg) {
        if (!_seeded) {
          _seeded = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(configDraftProvider.notifier).seed(cfg.raw);
          });
        }
      });
    });

    return asyncConfig.when(
      loading: () => const Center(child: AppLoadingIndicator()),
      error: (e, _) => _buildBody(context, configError: '$e'),
      data: (_) => _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context, {String? configError}) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        const _ServerManagementCard(),
        const _AboutCard(),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Text('Ani-rss 服务端设置',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        if (configError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('读取配置失败：$configError',
                style: const TextStyle(color: Colors.red)),
          )
        else ...[
          const AniRssConfigForm(),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: Text(_saving ? '保存中…' : '保存设置'),
          ),
        ],
      ],
    );
  }

  Future<void> _save() async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    setState(() => _saving = true);
    try {
      final draft = ref.read(configDraftProvider);
      await api.setConfig(ConfigModel(Map<String, dynamic>.from(draft)));
      ref.invalidate(aniConfigProvider);
      _seeded = false;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('设置已保存')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _ServerManagementCard extends ConsumerWidget {
  const _ServerManagementCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(currentServerProvider);
    if (server == null) return const SizedBox.shrink();
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.dns_rounded),
            title: Text(server.name),
            subtitle: Text(server.activeLineUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (server.lines.length > 1)
            ListTile(
              leading: const Icon(Icons.alt_route_rounded),
              title: const Text('切换线路'),
              subtitle: Text(server.lines[server.activeLineIndex.clamp(0, server.lines.length - 1)].name),
              onTap: () => _switchLine(context, ref, server),
            ),
          ListTile(
            leading: const Icon(Icons.login_rounded),
            title: const Text('重新登录'),
            subtitle: const Text('凭据失效时刷新令牌'),
            onTap: () => _reLogin(context, ref, server),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('移除此服务器', style: TextStyle(color: Colors.red)),
            onTap: () => _remove(context, ref, server),
          ),
        ],
      ),
    );
  }

  Future<void> _switchLine(
      BuildContext context, WidgetRef ref, ServerConfig server) async {
    final idx = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => ListView(
        shrinkWrap: true,
        children: [
          for (var i = 0; i < server.lines.length; i++)
            ListTile(
              leading: Icon(i == server.activeLineIndex
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: Text(server.lines[i].name),
              subtitle: Text(server.lines[i].url,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(context, i),
            ),
        ],
      ),
    );
    if (idx == null) return;
    ref.read(serverListProvider.notifier).setActiveLine(server.id, idx);
    AniRssAuth.instance.clearToken(server.id);
    final updated = ref
        .read(serverListProvider)
        .firstWhere((s) => s.id == server.id, orElse: () => server);
    ref.read(currentServerProvider.notifier).state = updated;
    _invalidateAll(ref);
  }

  Future<void> _reLogin(
      BuildContext context, WidgetRef ref, ServerConfig server) async {
    final u = server.username ?? '';
    final p = server.password ?? '';
    if (u.isEmpty || p.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未保存账密，无法自动重登')));
      return;
    }
    try {
      final token = await AniRssAuth.login(server.activeLineUrl, u, p);
      AniRssAuth.instance.cacheToken(server.id, token);
      final updated = server.copyWith(authToken: token);
      ref.read(serverListProvider.notifier).updateServer(updated);
      ref.read(currentServerProvider.notifier).state = updated;
      _invalidateAll(ref);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已重新登录')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重新登录失败：$e')));
      }
    }
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, ServerConfig server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移除「${server.name}」？'),
        content: const Text('仅从本应用移除该服务器，不影响 Ani-rss 服务端。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    AniRssAuth.instance.clearToken(server.id);
    ref.read(serverListProvider.notifier).removeServer(server.id);
    ref.read(currentServerProvider.notifier).state = null;
    ref.read(authStateProvider.notifier).state = AuthState.unauthenticated;
    if (context.mounted) context.go('/');
  }

  void _invalidateAll(WidgetRef ref) {
    ref.invalidate(aniListProvider);
    ref.invalidate(aniConfigProvider);
    ref.invalidate(aniAboutProvider);
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncAbout = ref.watch(aniAboutProvider);
    return Card(
      child: asyncAbout.when(
        loading: () => const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('关于'),
          subtitle: Text('加载中…'),
        ),
        error: (e, _) => const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('关于'),
          subtitle: Text('版本信息不可用'),
        ),
        data: (about) => ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text('Ani-rss ${about.version ?? ''}'),
          subtitle: Text(about.update
              ? '有新版本：${about.latest ?? ''}'
              : '已是最新版本'),
        ),
      ),
    );
  }
}
