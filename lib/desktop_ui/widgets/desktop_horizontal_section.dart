import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';

class DesktopHorizontalSection extends StatelessWidget {
  const DesktopHorizontalSection({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.trailing,
    this.onTrailingTap,
    this.trailingLabel = 'View All',
    this.showDefaultTrailing = false,
    this.emptyLabel = 'No items yet',
    this.spacing = 16,
    this.viewportHeight = 320,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTrailingTap;
  final String trailingLabel;
  final bool showDefaultTrailing;
  final List<Widget> children;
  final String emptyLabel;
  final double spacing;
  final double viewportHeight;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if ((subtitle ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (showDefaultTrailing)
              _SectionLink(
                label: trailingLabel,
                onTap: onTrailingTap,
              ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: viewportHeight,
          child: children.isEmpty
              ? Center(
                  child: Text(
                    emptyLabel,
                    style: TextStyle(color: theme.textMuted),
                  ),
                )
              : ListView.separated(
                  clipBehavior: Clip.none,
                  scrollDirection: Axis.horizontal,
                  itemCount: children.length,
                  itemBuilder: (context, index) => children[index],
                  separatorBuilder: (_, __) => SizedBox(width: spacing),
                ),
        ),
      ],
    );
  }
}

class _SectionLink extends StatefulWidget {
  const _SectionLink({
    required this.label,
    this.onTap,
  });

  final String label;
  final VoidCallback? onTap;

  @override
  State<_SectionLink> createState() => _SectionLinkState();
}

class _SectionLinkState extends State<_SectionLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = DesktopThemeExtension.of(context);
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: TextStyle(
            color: _hovered ? theme.accent : theme.link,
            fontSize: 13,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
