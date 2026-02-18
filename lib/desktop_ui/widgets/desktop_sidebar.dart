import 'package:flutter/material.dart';
import 'package:lin_player_core/state/media_server_type.dart';

import '../theme/desktop_theme_extension.dart';
import 'desktop_sidebar_item.dart';

@immutable
class DesktopSidebarServer {
  const DesktopSidebarServer({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.serverType,
    this.iconUrl,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String subtitle;
  final MediaServerType serverType;
  final String? iconUrl;
  final bool enabled;
}

class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.servers,
    required this.selectedServerId,
    required this.onSelected,
    this.onServerAction,
    this.collapsed = false,
  });

  final List<DesktopSidebarServer> servers;
  final String? selectedServerId;
  final ValueChanged<String> onSelected;
  final void Function(String serverId, DesktopSidebarServerAction action)?
      onServerAction;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            theme.sidebarColor,
            theme.sidebarColor.withValues(alpha: 0.94),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.border),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          collapsed ? 10 : 12,
          14,
          collapsed ? 10 : 12,
          12,
        ),
        child: Column(
          crossAxisAlignment:
              collapsed ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            if (!collapsed)
              Text(
                '服务器',
                style: TextStyle(
                  color: theme.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            if (!collapsed) const SizedBox(height: 8),
            Expanded(
              child: servers.isEmpty
                  ? Center(
                      child: Text(
                        '暂无服务器',
                        style: TextStyle(
                          color: theme.textMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: servers.length,
                      itemBuilder: (context, index) {
                        final item = servers[index];
                        return Opacity(
                          opacity: item.enabled ? 1 : 0.45,
                          child: IgnorePointer(
                            ignoring: !item.enabled,
                            child: DesktopSidebarItem(
                              serverName: item.name,
                              subtitle: item.subtitle,
                              serverType: item.serverType,
                              iconUrl: item.iconUrl,
                              selected: selectedServerId == item.id,
                              collapsed: collapsed,
                              onTap: () => onSelected(item.id),
                              onActionSelected:
                                  collapsed || onServerAction == null
                                      ? null
                                      : (action) =>
                                          onServerAction!(item.id, action),
                            ),
                          ),
                        );
                      },
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
