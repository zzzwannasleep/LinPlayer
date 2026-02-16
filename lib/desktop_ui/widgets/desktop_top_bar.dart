import 'package:flutter/material.dart';

import '../theme/desktop_theme_extension.dart';

class DesktopTopBar extends StatelessWidget {
  const DesktopTopBar({
    super.key,
    required this.title,
    required this.searchController,
    required this.onSearchSubmitted,
    required this.onSearchChanged,
    this.showBack = false,
    this.onBack,
    this.onRefresh,
    this.onOpenSettings,
    this.searchHint = 'Search series or movies',
  });

  final String title;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchSubmitted;
  final ValueChanged<String> onSearchChanged;
  final bool showBack;
  final VoidCallback? onBack;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenSettings;
  final String searchHint;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: desktopTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: desktopTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            if (showBack)
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back',
              ),
            Text(
              title,
              style: TextStyle(
                color: desktopTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _SearchInput(
                controller: searchController,
                hintText: searchHint,
                onSubmitted: onSearchSubmitted,
                onChanged: onSearchChanged,
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: onRefresh,
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onOpenSettings,
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchInput extends StatelessWidget {
  const _SearchInput({
    required this.controller,
    required this.hintText,
    required this.onSubmitted,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);

    return TextField(
      controller: controller,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: hintText,
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: desktopTheme.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: desktopTheme.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: desktopTheme.focus,
            width: 1.6,
          ),
        ),
        fillColor: desktopTheme.surfaceElevated,
        filled: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}
