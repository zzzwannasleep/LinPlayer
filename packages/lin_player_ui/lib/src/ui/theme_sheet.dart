import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:lin_player_prefs/preferences.dart';

Future<void> showThemeSheet(
  BuildContext context, {
  required Listenable listenable,
  required ThemeMode Function() themeMode,
  required FutureOr<void> Function(ThemeMode mode) setThemeMode,
  required bool Function() useDynamicColor,
  required FutureOr<void> Function(bool value) setUseDynamicColor,
  required UiTemplate Function() uiTemplate,
  required FutureOr<void> Function(UiTemplate value) setUiTemplate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return AnimatedBuilder(
        animation: listenable,
        builder: (context, _) {
          final mode = themeMode();
          final dynamicColor = useDynamicColor();
          final template = uiTemplate();
          final isDesktopBinaryTheme = !kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.windows ||
                  defaultTargetPlatform == TargetPlatform.macOS);
          final modeSegments = isDesktopBinaryTheme
              ? const <ButtonSegment<ThemeMode>>[
                  ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                ]
              : const <ButtonSegment<ThemeMode>>[
                  ButtonSegment(value: ThemeMode.system, label: Text('系统')),
                  ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                ];
          final selectedMode = isDesktopBinaryTheme && mode == ThemeMode.system
              ? (Theme.of(context).brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light)
              : mode;

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('主题', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                SegmentedButton<ThemeMode>(
                  segments: modeSegments,
                  selected: {selectedMode},
                  onSelectionChanged: (s) => setThemeMode(s.first),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: dynamicColor,
                  onChanged: (v) => setUseDynamicColor(v),
                  title: const Text('动态取色（Material You）'),
                  subtitle: const Text(
                    'Android 12+ 生效，其他平台自动回退。',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: const Text('UI 模板'),
                  subtitle: const Text('切换整体风格与布局'),
                  trailing: SizedBox(
                    width: 240,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<UiTemplate>(
                        value: template,
                        isExpanded: true,
                        items: UiTemplate.values
                            .map(
                              (t) => DropdownMenuItem(
                                value: t,
                                child: Text(t.label),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setUiTemplate(v);
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
