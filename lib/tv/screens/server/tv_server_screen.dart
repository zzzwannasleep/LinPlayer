import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_toast.dart';

/// TV 服务器页 —— 真实服务器列表，支持切换当前服务器、删除、跳转添加。
class TvServerScreen extends ConsumerWidget {
  const TvServerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final servers = ref.watch(serverListProvider);
    final current = ref.watch(currentServerProvider);

    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Padding(
        padding: EdgeInsets.all(m.spacingXl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '服务器',
              style: TextStyle(
                fontSize: m.fontSizeXxl,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: m.spacingLg),
            Expanded(
              child: servers.isEmpty
                  ? _buildEmpty(context, m)
                  : ListView(
                      children: [
                        for (final entry in servers.asMap().entries)
                          _buildServerCard(
                            context,
                            ref,
                            entry.value,
                            m,
                            isCurrent: entry.value.id == current?.id,
                          ).animate().fadeIn(
                                delay: Duration(milliseconds: 40 * entry.key),
                                duration: TvDesignTokens.contentFadeDuration,
                              ),
                        SizedBox(height: m.spacingMd),
                        TvButton(
                          text: '添加服务器',
                          icon: Icons.add,
                          onPressed: () => context.go('/tv/add-server'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context, TvMetrics m) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined,
              color: TvDesignTokens.textSecondary, size: m.s(80)),
          SizedBox(height: m.spacingLg),
          Text('还没有服务器',
              style: TextStyle(
                  fontSize: m.fontSizeXl,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold)),
          SizedBox(height: m.spacingXl),
          TvButton(
            text: '添加服务器',
            icon: Icons.add,
            autofocus: true,
            onPressed: () => context.go('/tv/add-server'),
          ),
        ],
      ),
    );
  }

  Widget _buildServerCard(
    BuildContext context,
    WidgetRef ref,
    ServerConfig server,
    TvMetrics m, {
    required bool isCurrent,
  }) {
    final online = serverHasUsableAuth(server);
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingMd),
      child: TvFocusable(
        padding: EdgeInsets.all(m.s(6)),
        onSelect: () => _selectServer(context, ref, server),
        // 长按（Pad）/ 遥控器菜单键 → 进入编辑模式。
        onLongPress: () => context.push('/tv/edit-server/${server.id}'),
        child: Container(
          padding: EdgeInsets.all(m.spacingLg),
          decoration: BoxDecoration(
            color: isCurrent
                ? TvDesignTokens.brand.withValues(alpha: 0.15)
                : TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
            border: isCurrent
                ? Border.all(color: TvDesignTokens.brand, width: 2)
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: m.s(64),
                height: m.s(64),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: (online ? TvDesignTokens.success : TvDesignTokens.error)
                      .withValues(alpha: 0.2),
                  borderRadius:
                      BorderRadius.circular(m.posterRadius),
                ),
                // 有自定义图标（本地图片/网络图标）就显示图标，否则退回机房图标。
                child: (server.iconUrl != null && server.iconUrl!.isNotEmpty)
                    ? MediaImage(
                        imageUrl: server.iconUrl,
                        fit: BoxFit.cover,
                        useDefaultUserAgent: true,
                        errorWidget: Icon(Icons.storage,
                            color: online
                                ? TvDesignTokens.success
                                : TvDesignTokens.error,
                            size: m.s(32)),
                      )
                    : Icon(Icons.storage,
                        color: online
                            ? TvDesignTokens.success
                            : TvDesignTokens.error,
                        size: m.s(32)),
              ),
              SizedBox(width: m.spacingLg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            server.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: m.fontSizeLg,
                              color: isCurrent
                                  ? TvDesignTokens.brand
                                  : TvDesignTokens.textPrimary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (isCurrent) ...[
                          SizedBox(width: m.spacingSm),
                          Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: m.s(8), vertical: m.s(2)),
                            decoration: BoxDecoration(
                              color: TvDesignTokens.brand,
                              borderRadius: BorderRadius.circular(m.s(4)),
                            ),
                            child: Text('当前',
                                style: TextStyle(
                                    fontSize: m.fs(12),
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: m.spacingXs),
                    Text(server.baseUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: m.fontSizeSm,
                            color: TvDesignTokens.textSecondary)),
                    SizedBox(height: m.spacingXs),
                    Row(
                      children: [
                        Container(
                          width: m.s(8),
                          height: m.s(8),
                          decoration: BoxDecoration(
                            color: online
                                ? TvDesignTokens.success
                                : TvDesignTokens.error,
                            shape: BoxShape.circle,
                          ),
                        ),
                        SizedBox(width: m.spacingXs),
                        Text(online ? '已登录' : '未登录',
                            style: TextStyle(
                                fontSize: m.fontSizeXs,
                                color: online
                                    ? TvDesignTokens.success
                                    : TvDesignTokens.error)),
                      ],
                    ),
                  ],
                ),
              ),
              TvFocusable(
                padding: EdgeInsets.all(m.spacingXs),
                onSelect: () => context.push('/tv/edit-server/${server.id}'),
                child: Icon(Icons.edit_outlined,
                    color: TvDesignTokens.textSecondary, size: m.s(28)),
              ),
              SizedBox(width: m.spacingXs),
              TvFocusable(
                padding: EdgeInsets.all(m.spacingXs),
                onSelect: () => _confirmDelete(context, ref, server),
                child: Icon(Icons.delete_outline,
                    color: TvDesignTokens.error, size: m.s(28)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectServer(BuildContext context, WidgetRef ref, ServerConfig server) {
    ref.read(currentServerProvider.notifier).state = server;
    ref.read(authStateProvider.notifier).state = serverHasUsableAuth(server)
        ? AuthState.authenticated
        : AuthState.unauthenticated;
    ref.invalidate(librariesProvider);
    ref.invalidate(resumeItemsProvider);
    ref.invalidate(randomRecommendationsProvider);
    TvToast.show(context, '已切换到 ${server.name}');
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, ServerConfig server) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final m = dialogContext.tv;
        return TvPanel(
          title: '删除服务器',
          onClose: () => Navigator.pop(dialogContext),
          children: [
            Text('确定要删除 “${server.name}” 吗？',
                style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: TvDesignTokens.textPrimary)),
            SizedBox(height: m.spacingLg),
            Row(
              children: [
                Expanded(
                  child: TvFocusable(
                    autofocus: true,
                    onSelect: () => Navigator.pop(dialogContext),
                    child: _dialogButton('取消', TvDesignTokens.surface,
                        TvDesignTokens.textPrimary, m),
                  ),
                ),
                SizedBox(width: m.spacingMd),
                Expanded(
                  child: TvFocusable(
                    onSelect: () {
                      ref
                          .read(serverListProvider.notifier)
                          .removeServer(server.id);
                      if (ref.read(currentServerProvider)?.id == server.id) {
                        ref.read(currentServerProvider.notifier).clear();
                      }
                      Navigator.pop(dialogContext);
                      TvToast.show(context, '服务器已删除');
                    },
                    child: _dialogButton(
                        '删除', TvDesignTokens.error, Colors.white, m),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _dialogButton(String text, Color bg, Color fg, TvMetrics m) {
    return Container(
      padding: EdgeInsets.all(m.spacingMd),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Center(
        child: Text(text,
            style: TextStyle(
                fontSize: m.fontSizeMd,
                color: fg,
                fontWeight: FontWeight.bold)),
      ),
    );
  }
}
