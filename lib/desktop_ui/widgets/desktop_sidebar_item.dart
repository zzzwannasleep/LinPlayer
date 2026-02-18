import 'package:flutter/material.dart';
import 'package:lin_player_core/state/media_server_type.dart';

import '../theme/desktop_theme_extension.dart';
import 'hover_effect_wrapper.dart';

enum DesktopSidebarServerAction {
  editIcon,
  editRemark,
  editPassword,
  editRoute,
  deleteServer,
}

class DesktopSidebarItem extends StatelessWidget {
  const DesktopSidebarItem({
    super.key,
    required this.serverName,
    required this.subtitle,
    required this.serverType,
    required this.selected,
    this.iconUrl,
    this.collapsed = false,
    required this.onTap,
    this.onActionSelected,
  });

  final String serverName;
  final String subtitle;
  final MediaServerType serverType;
  final bool selected;
  final String? iconUrl;
  final bool collapsed;
  final VoidCallback onTap;
  final ValueChanged<DesktopSidebarServerAction>? onActionSelected;

  IconData _fallbackIconForType(MediaServerType type) {
    switch (type) {
      case MediaServerType.jellyfin:
        return Icons.sports_esports_rounded;
      case MediaServerType.plex:
        return Icons.play_circle_outline_rounded;
      case MediaServerType.webdav:
        return Icons.folder_shared_outlined;
      case MediaServerType.emby:
        return Icons.video_library_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final fgPrimary = selected ? theme.textPrimary : theme.textMuted;
    final fgSecondary = selected
        ? theme.textPrimary.withValues(alpha: 0.72)
        : theme.textMuted.withValues(alpha: 0.74);
    final rawIconUrl = (iconUrl ?? '').trim();
    final fallbackIcon = _fallbackIconForType(serverType);
    final fallbackInitial =
        serverName.trim().isEmpty ? '?' : serverName.trim()[0];

    Widget fallbackAvatar() {
      return Center(
        child: fallbackInitial == '?'
            ? Icon(
                fallbackIcon,
                size: 18,
                color: selected ? theme.accent : theme.textMuted,
              )
            : Text(
                fallbackInitial.toUpperCase(),
                style: TextStyle(
                  color: selected ? theme.accent : theme.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
      );
    }

    return HoverEffectWrapper(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      hoverScale: 1.01,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? theme.topTabActiveBackground
              : Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.accent.withValues(alpha: 0.42)
                : theme.border.withValues(alpha: 0.24),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: collapsed ? 10 : 12,
            vertical: 9,
          ),
          child: Row(
            mainAxisAlignment:
                collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: selected
                      ? theme.accent.withValues(alpha: 0.16)
                      : theme.surfaceElevated.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: selected
                        ? theme.accent.withValues(alpha: 0.5)
                        : theme.border.withValues(alpha: 0.38),
                  ),
                ),
                child: rawIconUrl.isEmpty
                    ? fallbackAvatar()
                    : Image.network(
                        rawIconUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => fallbackAvatar(),
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return fallbackAvatar();
                        },
                      ),
              ),
              if (!collapsed) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        serverName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fgPrimary,
                          fontSize: 15,
                          height: 1.1,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fgSecondary,
                          fontSize: 11.5,
                          height: 1.15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onActionSelected != null) ...[
                  const SizedBox(width: 6),
                  _SidebarServerMenuButton(
                    selected: selected,
                    onSelected: onActionSelected!,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarServerMenuButton extends StatelessWidget {
  const _SidebarServerMenuButton({
    required this.selected,
    required this.onSelected,
  });

  final bool selected;
  final ValueChanged<DesktopSidebarServerAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    final iconColor =
        selected ? theme.textPrimary : theme.textMuted.withValues(alpha: 0.86);

    PopupMenuItem<DesktopSidebarServerAction> item({
      required DesktopSidebarServerAction value,
      required IconData icon,
      required String label,
      bool danger = false,
    }) {
      final color = danger ? const Color(0xFFFF9A9A) : null;
      return PopupMenuItem<DesktopSidebarServerAction>(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(label, style: color == null ? null : TextStyle(color: color)),
          ],
        ),
      );
    }

    return Tooltip(
      message: '更多',
      child: PopupMenuButton<DesktopSidebarServerAction>(
        tooltip: '更多',
        onSelected: onSelected,
        itemBuilder: (context) => [
          item(
            value: DesktopSidebarServerAction.editIcon,
            icon: Icons.image_outlined,
            label: '修改图标',
          ),
          item(
            value: DesktopSidebarServerAction.editRemark,
            icon: Icons.edit_note_outlined,
            label: '修改备注',
          ),
          item(
            value: DesktopSidebarServerAction.editPassword,
            icon: Icons.lock_reset_outlined,
            label: '修改密码',
          ),
          item(
            value: DesktopSidebarServerAction.editRoute,
            icon: Icons.alt_route_rounded,
            label: '修改线路',
          ),
          const PopupMenuDivider(),
          item(
            value: DesktopSidebarServerAction.deleteServer,
            icon: Icons.delete_outline,
            label: '删除服务器',
            danger: true,
          ),
        ],
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: selected ? 0.14 : 0.05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.border.withValues(alpha: selected ? 0.72 : 0.44),
            ),
          ),
          child: Icon(
            Icons.more_horiz_rounded,
            size: 18,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}
