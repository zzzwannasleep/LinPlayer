import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/translation/subtitle_document.dart';
import '../../theme/tv_design_tokens.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_toast.dart';
import 'tv_sync_settings.dart';

/// TV 设置页 —— 左侧分类 + 右侧真实可持久化设置项。
class TvSettingsScreen extends ConsumerStatefulWidget {
  const TvSettingsScreen({super.key});

  @override
  ConsumerState<TvSettingsScreen> createState() => _TvSettingsScreenState();
}

class _TvSettingsScreenState extends ConsumerState<TvSettingsScreen> {
  int _selectedCategory = 0;

  static const List<_SettingCategory> _categories = [
    _SettingCategory(Icons.play_circle_outline, '播放'),
    _SettingCategory(Icons.settings, '通用'),
    _SettingCategory(Icons.translate, '翻译'),
    _SettingCategory(Icons.sync, '同步'),
    _SettingCategory(Icons.info_outline, '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Row(
        children: [
          Container(
            width: 240,
            color: TvDesignTokens.surface,
            child: ListView.builder(
              padding: const EdgeInsets.all(TvDesignTokens.spacingLg),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final category = _categories[index];
                final selected = _selectedCategory == index;
                return TvFocusable(
                  autofocus: index == 0,
                  padding: const EdgeInsets.all(4),
                  onSelect: () => setState(() => _selectedCategory = index),
                  child: Container(
                    padding: const EdgeInsets.all(TvDesignTokens.spacingMd),
                    margin:
                        const EdgeInsets.only(bottom: TvDesignTokens.spacingSm),
                    decoration: BoxDecoration(
                      color: selected
                          ? TvDesignTokens.brand.withValues(alpha: 0.15)
                          : null,
                      borderRadius:
                          BorderRadius.circular(TvDesignTokens.posterRadius),
                    ),
                    child: Row(
                      children: [
                        Icon(category.icon,
                            color: selected
                                ? TvDesignTokens.brand
                                : TvDesignTokens.textSecondary,
                            size: 28),
                        const SizedBox(width: TvDesignTokens.spacingMd),
                        Text(category.name,
                            style: TextStyle(
                                fontSize: TvDesignTokens.fontSizeMd,
                                color: selected
                                    ? TvDesignTokens.brand
                                    : TvDesignTokens.textPrimary,
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.normal)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_selectedCategory) {
      case 0:
        return _buildPlaybackSettings();
      case 1:
        return _buildGeneralSettings();
      case 2:
        return _buildTranslationSettings();
      case 3:
        return const TvSyncSettings();
      case 4:
        return _buildAboutSettings();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPlaybackSettings() {
    final core = ref.watch(playerCoreProvider);
    final speed = ref.watch(defaultPlaybackSpeedProvider);
    final threshold = ref.watch(watchedThresholdProvider);
    final skip = ref.watch(skipForwardStepProvider);
    final autoNext = ref.watch(autoPlayNextProvider);
    final exoLibass = ref.watch(exoLibassProvider);
    final gpuNext = ref.watch(gpuNextEnabledProvider);

    return _settingsList('播放设置', [
      _choiceItem<String>(
        title: '播放器内核',
        current: core,
        options: const [
          MapEntry('原生 MPV', 'nativeMpv'),
          MapEntry('MPV (media_kit)', 'mpv'),
          MapEntry('ExoPlayer', 'exoPlayer'),
        ],
        onPick: (v) =>
            ref.read(playerCoreProvider.notifier).state = v,
      ),
      _choiceItem<double>(
        title: '默认倍速',
        current: speed,
        labelOf: (v) => '${v}x',
        options: const [
          MapEntry('0.5x', 0.5),
          MapEntry('0.75x', 0.75),
          MapEntry('1.0x', 1.0),
          MapEntry('1.25x', 1.25),
          MapEntry('1.5x', 1.5),
          MapEntry('2.0x', 2.0),
        ],
        onPick: (v) =>
            ref.read(defaultPlaybackSpeedProvider.notifier).state = v,
      ),
      _choiceItem<int>(
        title: '观看阈值',
        subtitle: '播放进度达到该比例即标记“已看”，并触发同步上报',
        current: threshold,
        labelOf: (v) => '$v%',
        options: const [
          MapEntry('75%', 75),
          MapEntry('80%', 80),
          MapEntry('85%', 85),
          MapEntry('90%', 90),
          MapEntry('95%', 95),
        ],
        onPick: (v) =>
            ref.read(watchedThresholdProvider.notifier).state = v,
      ),
      _choiceItem<int>(
        title: '快进/快退步进',
        current: skip,
        labelOf: (v) => '$v 秒',
        options: const [
          MapEntry('5 秒', 5),
          MapEntry('10 秒', 10),
          MapEntry('15 秒', 15),
          MapEntry('30 秒', 30),
        ],
        onPick: (v) =>
            ref.read(skipForwardStepProvider.notifier).state = v,
      ),
      _toggleItem(
        title: '自动播放下一集',
        value: autoNext,
        onToggle: () =>
            ref.read(autoPlayNextProvider.notifier).state = !autoNext,
      ),
      _toggleItem(
        title: 'ExoPlayer ASS 字幕（libass）',
        subtitle: '开启后 ExoPlayer 内核可渲染内封特效 ASS 字幕（经 libass 转位图叠加）',
        value: exoLibass,
        onToggle: () =>
            ref.read(exoLibassProvider.notifier).state = !exoLibass,
      ),
      _toggleItem(
        title: 'MPV gpu-next 渲染',
        subtitle: '原生 MPV 使用 SurfaceView + gpu-next（HDR/着色器更佳，部分设备需关闭）',
        value: gpuNext,
        onToggle: () =>
            ref.read(gpuNextEnabledProvider.notifier).state = !gpuNext,
      ),
    ]);
  }

  Widget _buildGeneralSettings() {
    final hwDecode = ref.watch(hardwareDecodingProvider);
    final bgPlay = ref.watch(backgroundPlaybackProvider);
    return _settingsList('通用设置', [
      _toggleItem(
        title: '硬件解码',
        subtitle: '关闭后使用软件解码（更耗电、更兼容）',
        value: hwDecode,
        onToggle: () =>
            ref.read(hardwareDecodingProvider.notifier).state = !hwDecode,
      ),
      _toggleItem(
        title: '后台播放',
        value: bgPlay,
        onToggle: () =>
            ref.read(backgroundPlaybackProvider.notifier).state = !bgPlay,
      ),
    ]);
  }

  Widget _buildTranslationSettings() {
    final kind = ref.watch(translationEngineKindProvider);
    final target = ref.watch(translationTargetLangProvider);
    final layout = ref.watch(bilingualLayoutProvider);

    final items = <Widget>[
      _choiceItem<TranslationEngineKind>(
        title: '翻译引擎',
        current: kind,
        labelOf: (v) => v.label,
        options: [
          for (final e in TranslationEngineKind.values) MapEntry(e.label, e),
        ],
        onPick: (v) =>
            ref.read(translationEngineKindProvider.notifier).state = v,
      ),
      _choiceItem<String>(
        title: '目标语言',
        current: target == 'cht' ? 'cht' : 'zh',
        options: const [
          MapEntry('简体中文', 'zh'),
          MapEntry('繁体中文', 'cht'),
        ],
        onPick: (v) =>
            ref.read(translationTargetLangProvider.notifier).state = v,
      ),
      _choiceItem<BilingualLayout>(
        title: '双语排版',
        current: layout,
        labelOf: (v) => switch (v) {
          BilingualLayout.translatedOnly => '仅译文',
          BilingualLayout.translatedFirst => '译文+原文',
          BilingualLayout.originalFirst => '原文+译文',
        },
        options: const [
          MapEntry('仅译文', BilingualLayout.translatedOnly),
          MapEntry('译文+原文', BilingualLayout.translatedFirst),
          MapEntry('原文+译文', BilingualLayout.originalFirst),
        ],
        onPick: (v) => ref.read(bilingualLayoutProvider.notifier).state = v,
      ),
      ..._engineConfigItems(kind),
    ];
    return _settingsList('字幕翻译', items);
  }

  List<Widget> _engineConfigItems(TranslationEngineKind kind) {
    switch (kind) {
      case TranslationEngineKind.openai:
      case TranslationEngineKind.anthropic:
        final provider = kind == TranslationEngineKind.openai
            ? openAiConfigProvider
            : anthropicConfigProvider;
        final cfg = ref.watch(provider);
        return [
          _textItem(
            title: 'API 地址',
            value: cfg.baseUrl,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(baseUrl: v.trim()),
          ),
          _textItem(
            title: 'API Key',
            value: cfg.apiKey,
            obscure: true,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(apiKey: v.trim()),
          ),
          _textItem(
            title: '模型',
            value: cfg.model,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(model: v.trim()),
          ),
        ];
      case TranslationEngineKind.baiduGeneral:
        final cfg = ref.watch(baiduGeneralConfigProvider);
        return [
          _textItem(
            title: 'APP ID',
            value: cfg.appId,
            onSubmit: (v) => ref.read(baiduGeneralConfigProvider.notifier).state =
                cfg.copyWith(appId: v.trim()),
          ),
          _textItem(
            title: '密钥',
            value: cfg.secretKey,
            obscure: true,
            onSubmit: (v) => ref.read(baiduGeneralConfigProvider.notifier).state =
                cfg.copyWith(secretKey: v.trim()),
          ),
        ];
      case TranslationEngineKind.baiduLlm:
        final cfg = ref.watch(baiduLlmConfigProvider);
        return [
          _textItem(
            title: 'APP ID',
            value: cfg.appId,
            onSubmit: (v) => ref.read(baiduLlmConfigProvider.notifier).state =
                cfg.copyWith(appId: v.trim()),
          ),
          _textItem(
            title: 'API Key',
            value: cfg.apiKey,
            obscure: true,
            onSubmit: (v) => ref.read(baiduLlmConfigProvider.notifier).state =
                cfg.copyWith(apiKey: v.trim()),
          ),
        ];
      case TranslationEngineKind.tencent:
        final cfg = ref.watch(tencentConfigProvider);
        return [
          _textItem(
            title: 'SecretId',
            value: cfg.secretId,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(secretId: v.trim()),
          ),
          _textItem(
            title: 'SecretKey',
            value: cfg.secretKey,
            obscure: true,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(secretKey: v.trim()),
          ),
          _textItem(
            title: '地域 Region',
            value: cfg.region,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(region: v.trim().isEmpty ? 'ap-beijing' : v.trim()),
          ),
        ];
    }
  }

  Widget _textItem({
    required String title,
    required String value,
    required ValueChanged<String> onSubmit,
    bool obscure = false,
  }) {
    final display = value.isEmpty
        ? '未设置'
        : (obscure ? '••••••${value.length > 4 ? value.substring(value.length - 4) : ''}' : value);
    return _rowCard(
      title: title,
      subtitle: display,
      trailing: const Icon(Icons.edit,
          color: TvDesignTokens.textSecondary, size: 24),
      onSelect: () => _showTextInput(title, value, obscure, onSubmit),
    );
  }

  void _showTextInput(
      String title, String value, bool obscure, ValueChanged<String> onSubmit) {
    final controller = TextEditingController(text: value);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        title: Text(title, style: const TextStyle(color: TvDesignTokens.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscure,
          style: const TextStyle(color: TvDesignTokens.textPrimary),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              onSubmit(controller.text);
              Navigator.pop(dialogContext);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSettings() {
    return _settingsList('关于', [
      _staticItem(title: '应用', subtitle: 'LinPlayer for TV'),
      _staticItem(title: '版本', subtitle: '1.0.0'),
      _actionItem(
        title: '导出日志',
        subtitle: '导出到文件并复制路径（排查问题用）',
        onTap: _exportLogs,
      ),
      _actionItem(
        title: '重新查看引导',
        subtitle: '打开 TV 引导页',
        onTap: () => context.go('/tv/onboarding'),
      ),
    ]);
  }

  Future<void> _exportLogs() async {
    try {
      final path = await AppLogger().exportToFile();
      await Clipboard.setData(ClipboardData(text: path));
      if (mounted) TvToast.show(context, '日志已导出并复制路径: $path');
    } catch (e) {
      if (mounted) TvToast.show(context, '导出日志失败: $e');
    }
  }

  // ============ 复用控件 ============

  Widget _settingsList(String title, List<Widget> items) {
    return ListView(
      padding: const EdgeInsets.all(TvDesignTokens.spacingXl),
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: TvDesignTokens.fontSizeXxl,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: TvDesignTokens.spacingLg),
        ...items,
      ],
    );
  }

  Widget _rowCard({
    required String title,
    String? subtitle,
    required Widget trailing,
    required VoidCallback onSelect,
  }) {
    return TvFocusable(
      padding: const EdgeInsets.all(4),
      onSelect: onSelect,
      child: Container(
        padding: const EdgeInsets.all(TvDesignTokens.spacingLg),
        margin: const EdgeInsets.only(bottom: TvDesignTokens.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(TvDesignTokens.posterRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: TvDesignTokens.fontSizeMd,
                          color: TvDesignTokens.textPrimary)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: TvDesignTokens.fontSizeXs,
                            color: TvDesignTokens.textSecondary)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: TvDesignTokens.spacingMd),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _choiceItem<T>({
    required String title,
    String? subtitle,
    required T current,
    required List<MapEntry<String, T>> options,
    required ValueChanged<T> onPick,
    String Function(T)? labelOf,
  }) {
    final currentLabel = options
            .firstWhere((e) => e.value == current,
                orElse: () => MapEntry(
                    labelOf?.call(current) ?? '$current', current))
            .key;
    return _rowCard(
      title: title,
      subtitle: subtitle ?? currentLabel,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(currentLabel,
              style: const TextStyle(
                  fontSize: TvDesignTokens.fontSizeSm,
                  color: TvDesignTokens.brand)),
          const SizedBox(width: TvDesignTokens.spacingXs),
          const Icon(Icons.chevron_right,
              color: TvDesignTokens.textSecondary, size: 28),
        ],
      ),
      onSelect: () => _showChoice<T>(title, current, options, onPick),
    );
  }

  void _showChoice<T>(String title, T current,
      List<MapEntry<String, T>> options, ValueChanged<T> onPick) {
    showDialog(
      context: context,
      builder: (dialogContext) => TvPanel(
        title: title,
        onClose: () => Navigator.pop(dialogContext),
        children: [
          for (final opt in options)
            TvPanelOption(
              title: opt.key,
              isSelected: opt.value == current,
              onTap: () {
                onPick(opt.value);
                Navigator.pop(dialogContext);
              },
            ),
        ],
      ),
    );
  }

  Widget _toggleItem({
    required String title,
    String? subtitle,
    required bool value,
    required VoidCallback onToggle,
  }) {
    return _rowCard(
      title: title,
      subtitle: subtitle,
      onSelect: onToggle,
      trailing: AnimatedContainer(
        duration: TvDesignTokens.focusAnimationDuration,
        width: 56,
        height: 30,
        decoration: BoxDecoration(
          color: value
              ? TvDesignTokens.brand
              : TvDesignTokens.surfaceElevated,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.all(3),
        child: Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _staticItem({required String title, required String subtitle}) {
    return _rowCard(
      title: title,
      subtitle: subtitle,
      onSelect: () {},
      trailing: const SizedBox.shrink(),
    );
  }

  Widget _actionItem({
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return _rowCard(
      title: title,
      subtitle: subtitle,
      onSelect: onTap,
      trailing: const Icon(Icons.chevron_right,
          color: TvDesignTokens.textSecondary, size: 28),
    );
  }
}

class _SettingCategory {
  final IconData icon;
  final String name;
  const _SettingCategory(this.icon, this.name);
}
