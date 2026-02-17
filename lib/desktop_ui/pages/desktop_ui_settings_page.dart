import 'package:flutter/material.dart';

import '../models/desktop_ui_language.dart';
import '../theme/desktop_theme_extension.dart';

class DesktopUiSettingsPage extends StatefulWidget {
  const DesktopUiSettingsPage({
    super.key,
    required this.initialLanguage,
    required this.onOpenSystemSettings,
  });

  final DesktopUiLanguage initialLanguage;
  final Future<void> Function() onOpenSystemSettings;

  @override
  State<DesktopUiSettingsPage> createState() => _DesktopUiSettingsPageState();
}

class _DesktopUiSettingsPageState extends State<DesktopUiSettingsPage> {
  late DesktopUiLanguage _language = widget.initialLanguage;

  String _t({
    required String zh,
    required String en,
  }) {
    return _language.pick(zh: zh, en: en);
  }

  void _selectLanguage(DesktopUiLanguage value) {
    setState(() => _language = value);
  }

  void _applyAndClose() {
    Navigator.of(context).pop(_language);
  }

  Future<void> _openSystemSettings() async {
    await widget.onOpenSystemSettings();
  }

  @override
  Widget build(BuildContext context) {
    final desktopTheme = DesktopThemeExtension.of(context);

    return Scaffold(
      backgroundColor: desktopTheme.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: desktopTheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: desktopTheme.border),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.tune_rounded,
                            color: desktopTheme.textPrimary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _t(zh: '界面设置', en: 'UI Settings'),
                            style: TextStyle(
                              color: desktopTheme.textPrimary,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: _t(zh: '关闭', en: 'Close'),
                            onPressed: _applyAndClose,
                            icon: Icon(
                              Icons.close_rounded,
                              color: desktopTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _t(
                          zh: '仅调整桌面 UI 外观，不涉及播放或数据逻辑。',
                          en: 'Desktop UI only. No playback or data logic.',
                        ),
                        style: TextStyle(
                          color: desktopTheme.textMuted,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _t(zh: '语言', en: 'Language'),
                        style: TextStyle(
                          color: desktopTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('中文'),
                            selected: _language == DesktopUiLanguage.zhCn,
                            onSelected: (_) =>
                                _selectLanguage(DesktopUiLanguage.zhCn),
                          ),
                          ChoiceChip(
                            label: const Text('English'),
                            selected: _language == DesktopUiLanguage.enUs,
                            onSelected: (_) =>
                                _selectLanguage(DesktopUiLanguage.enUs),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(
                          Icons.settings_outlined,
                          color: desktopTheme.textMuted,
                          size: 18,
                        ),
                        title: Text(
                          _t(zh: '打开完整设置', en: 'Open Full Settings'),
                          style: TextStyle(
                            color: desktopTheme.textPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          _t(
                            zh: '进入系统设置页（网络、播放、账户等）',
                            en: 'Open system settings for network/player/account.',
                          ),
                          style: TextStyle(
                            color: desktopTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        trailing: Icon(
                          Icons.open_in_new_rounded,
                          color: desktopTheme.textMuted,
                          size: 18,
                        ),
                        onTap: _openSystemSettings,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _applyAndClose,
                            child: Text(_t(zh: '完成', en: 'Done')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
