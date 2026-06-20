import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../core/app_identity.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/update_providers.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/font_service.dart';
import '../../../ui/widgets/common/app_update_gate.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/translation/subtitle_document.dart';
import '../../../core/providers/proxy_providers.dart';
import '../../../core/network/proxy_settings.dart';
import '../../services/mihomo_service.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_toast.dart';
import 'tv_sync_settings.dart';
import 'zashboard_screen.dart';

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
    _SettingCategory(Icons.vpn_key, '网络'),
    _SettingCategory(Icons.translate, '翻译'),
    _SettingCategory(Icons.sync, '同步'),
    _SettingCategory(Icons.info_outline, '关于'),
  ];

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Row(
        children: [
          Container(
            width: m.sidebarWidth,
            color: TvDesignTokens.surface,
            child: ListView.builder(
              padding: EdgeInsets.all(m.spacingLg),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final category = _categories[index];
                final selected = _selectedCategory == index;
                return TvFocusable(
                  autofocus: index == 0,
                  padding: const EdgeInsets.all(4),
                  onSelect: () => setState(() => _selectedCategory = index),
                  child: Container(
                    padding: EdgeInsets.all(m.spacingMd),
                    margin: EdgeInsets.only(bottom: m.spacingSm),
                    decoration: BoxDecoration(
                      color: selected
                          ? TvDesignTokens.brand.withValues(alpha: 0.15)
                          : null,
                      borderRadius: BorderRadius.circular(m.posterRadius),
                    ),
                    child: Row(
                      children: [
                        Icon(category.icon,
                            color: selected
                                ? TvDesignTokens.brand
                                : TvDesignTokens.textSecondary,
                            size: m.s(28)),
                        SizedBox(width: m.spacingMd),
                        Text(category.name,
                            style: TextStyle(
                                fontSize: m.fontSizeMd,
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
          Expanded(child: _buildContent(m)),
        ],
      ),
    );
  }

  Widget _buildContent(TvMetrics m) {
    switch (_selectedCategory) {
      case 0:
        return _buildPlaybackSettings(m);
      case 1:
        return _buildGeneralSettings(m);
      case 2:
        return _buildNetworkSettings(m);
      case 3:
        return _buildTranslationSettings(m);
      case 4:
        return const TvSyncSettings();
      case 5:
        return _buildAboutSettings(m);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPlaybackSettings(TvMetrics m) {
    final core = ref.watch(playerCoreProvider);
    final speed = ref.watch(defaultPlaybackSpeedProvider);
    final threshold = ref.watch(watchedThresholdProvider);
    final skip = ref.watch(skipForwardStepProvider);
    final autoNext = ref.watch(autoPlayNextProvider);
    final autoSkipSegments = ref.watch(autoSkipSegmentsProvider);
    final exoLibass = ref.watch(exoLibassProvider);
    final gpuNext = ref.watch(gpuNextEnabledProvider);
    final dolbyAuto = ref.watch(dolbyAutoGpuNextSwProvider);
    final versionRegex = ref.watch(preferredVersionRegexProvider);
    final subtitleRegex = ref.watch(preferredSubtitleRegexProvider);
    final audioRegex = ref.watch(preferredAudioRegexProvider);

    return _settingsList(m, '播放设置', [
      _choiceItem<String>(
        m,
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
        m,
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
        m,
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
        m,
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
        m,
        title: '自动播放下一集',
        value: autoNext,
        onToggle: () =>
            ref.read(autoPlayNextProvider.notifier).state = !autoNext,
      ),
      _toggleItem(
        m,
        title: '自动跳过片头/片尾',
        subtitle: '联网识别剧集片头片尾，进入时显示跳过按钮',
        value: autoSkipSegments,
        onToggle: () => ref.read(autoSkipSegmentsProvider.notifier).state =
            !autoSkipSegments,
      ),
      _toggleItem(
        m,
        title: 'ExoPlayer ASS 字幕（libass）',
        subtitle: '开启后 ExoPlayer 内核可渲染内封特效 ASS 字幕（经 libass 转位图叠加）',
        value: exoLibass,
        onToggle: () =>
            ref.read(exoLibassProvider.notifier).state = !exoLibass,
      ),
      _toggleItem(
        m,
        title: 'MPV gpu-next 渲染',
        subtitle: '原生 MPV 使用 SurfaceView + gpu-next（HDR/着色器更佳，部分设备需关闭）',
        value: gpuNext,
        onToggle: () =>
            ref.read(gpuNextEnabledProvider.notifier).state = !gpuNext,
      ),
      _toggleItem(
        m,
        title: '杜比视界自动切换软解',
        subtitle: '播放杜比视界时自动启用 gpu-next 渲染 + 软件解码，修正硬解偏色',
        value: dolbyAuto,
        onToggle: () =>
            ref.read(dolbyAutoGpuNextSwProvider.notifier).state = !dolbyAuto,
      ),
      _textItem(
        m,
        title: '版本筛选（正则）',
        value: versionRegex,
        onSubmit: (v) => _saveRegexPref(preferredVersionRegexProvider, v),
      ),
      _textItem(
        m,
        title: '字幕筛选（正则，如 中文|简|繁|chi）',
        value: subtitleRegex,
        onSubmit: (v) => _saveRegexPref(preferredSubtitleRegexProvider, v),
      ),
      _textItem(
        m,
        title: '音频筛选（正则，如 jpn|日|flac）',
        value: audioRegex,
        onSubmit: (v) => _saveRegexPref(preferredAudioRegexProvider, v),
      ),
    ]);
  }

  /// 保存正则筛选偏好：校验合法性，非法则提示且不保存。
  void _saveRegexPref(
      StateNotifierProvider<PreferenceNotifier<String>, String> provider,
      String raw) {
    final value = raw.trim();
    if (value.isNotEmpty) {
      try {
        RegExp(value);
      } catch (_) {
        if (mounted) TvToast.show(context, '正则表达式格式不正确，未保存');
        return;
      }
    }
    ref.read(provider.notifier).state = value;
  }

  Widget _buildGeneralSettings(TvMetrics m) {
    final hwDecode = ref.watch(hardwareDecodingProvider);
    final bgPlay = ref.watch(backgroundPlaybackProvider);
    return _settingsList(m, '通用设置', [
      _toggleItem(
        m,
        title: '硬件解码',
        subtitle: '关闭后使用软件解码（更耗电、更兼容）',
        value: hwDecode,
        onToggle: () =>
            ref.read(hardwareDecodingProvider.notifier).state = !hwDecode,
      ),
      _toggleItem(
        m,
        title: '后台播放',
        value: bgPlay,
        onToggle: () =>
            ref.read(backgroundPlaybackProvider.notifier).state = !bgPlay,
      ),
      _rowCard(
        m,
        title: '手机扫码遥控',
        subtitle: '生成局域网二维码，用手机编辑设置/服务器并遥控播放',
        trailing: Icon(Icons.qr_code_2,
            color: TvDesignTokens.brand, size: m.s(28)),
        onSelect: () => context.push('/tv/lan-control'),
      ),
      _fontItem(
        m,
        title: '应用字体',
        path: ref.watch(customAppFontPathProvider),
        defaultHint: '默认字体 · 选择字体文件 (ttf/otf)，切换后重启生效',
        isApp: true,
      ),
      _fontItem(
        m,
        title: '弹幕字体',
        path: ref.watch(customDanmakuFontPathProvider),
        defaultHint: '默认字体 · 选择字体文件 (ttf/otf)',
        isApp: false,
      ),
    ]);
  }

  Widget _buildNetworkSettings(TvMetrics m) {
    final cfg = ref.watch(proxyConfigProvider);
    final notifier = ref.read(proxyConfigProvider.notifier);

    final items = <Widget>[
      _choiceItem<ProxyType>(
        m,
        title: '代理协议',
        current: cfg.type,
        labelOf: (v) => v.label,
        options: [for (final t in ProxyType.values) MapEntry(t.label, t)],
        onPick: (v) => notifier.save(cfg.copyWith(type: v)),
      ),
    ];

    if (cfg.type != ProxyType.none) {
      items.addAll([
        _textItem(
          m,
          title: '主机 (Host)',
          value: cfg.host,
          onSubmit: (v) => notifier.save(cfg.copyWith(host: v.trim())),
        ),
        _textItem(
          m,
          title: '端口 (Port)',
          value: cfg.port > 0 ? '${cfg.port}' : '',
          onSubmit: (v) =>
              notifier.save(cfg.copyWith(port: int.tryParse(v.trim()) ?? 0)),
        ),
        _textItem(
          m,
          title: '用户名（可选）',
          value: cfg.username,
          onSubmit: (v) => notifier.save(cfg.copyWith(username: v)),
        ),
        _textItem(
          m,
          title: '密码（可选）',
          value: cfg.password,
          obscure: true,
          onSubmit: (v) => notifier.save(cfg.copyWith(password: v)),
        ),
        _toggleItem(
          m,
          title: '代理媒体流播放',
          subtitle: cfg.type.isSocks
              ? 'libmpv 不支持 SOCKS，此项仅对 HTTP 代理生效'
              : '关闭则播放直连、仅代理 API/图片等请求',
          value: cfg.proxyMedia,
          onToggle: () => notifier.save(cfg.copyWith(proxyMedia: !cfg.proxyMedia)),
        ),
      ]);
    }

    // 订阅代理(mihomo) —— 仅 Android TV 内置内核。
    if (Platform.isAndroid) {
      items
        ..add(SizedBox(height: m.spacingLg))
        ..addAll(_mihomoItems(m));
    }

    return _settingsList(m, '代理设置', items);
  }

  List<Widget> _mihomoItems(TvMetrics m) {
    final mihomo = ref.watch(mihomoControllerProvider);
    final ctrl = ref.read(mihomoControllerProvider.notifier);

    final items = <Widget>[
      Padding(
        padding: EdgeInsets.only(
            left: 4, bottom: m.spacingMd, top: m.spacingMd),
        child: Text('订阅代理 (mihomo)',
            style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold)),
      ),
    ];

    if (!mihomo.coreAvailable) {
      items.add(_staticItem(
        m,
        title: '内核未内置',
        subtitle: '仅 Android TV 构建包含 mihomo 内核（libmihomo.so）。'
            '运行 scripts/fetch_mihomo_tv.ps1 拉取后重新构建 tv flavor。',
      ));
      return items;
    }

    items.add(_toggleItem(
      m,
      title: '启用订阅代理',
      subtitle: mihomo.running
          ? '运行中 · 全局走 mihomo（含播放流），启用后会覆盖上方手动代理'
          : '启动 mihomo 并把全局代理指向本地端口 ${MihomoPorts.mixedPort}',
      value: mihomo.enabled,
      onToggle: () => mihomo.enabled ? ctrl.disable() : ctrl.enable(),
    ));

    for (final s in mihomo.subscriptions) {
      items.add(_rowCard(
        m,
        title: s.name,
        subtitle: s.url,
        trailing: Icon(Icons.delete_outline,
            color: TvDesignTokens.textSecondary, size: m.s(24)),
        onSelect: () => ctrl.removeSubscription(s.id),
      ));
    }

    items.add(_actionItem(
      m,
      title: '添加订阅',
      subtitle: '输入机场订阅链接',
      onTap: _showAddSubscription,
    ));
    if (mihomo.subscriptions.isNotEmpty) {
      items.add(_actionItem(
        m,
        title: '更新订阅',
        subtitle: '重新拉取并重载配置',
        onTap: () {
          ctrl.refresh();
          TvToast.show(context, '正在重载订阅…');
        },
      ));
    }
    if (mihomo.running) {
      items.add(_actionItem(
        m,
        title: '打开 zashboard 面板',
        subtitle: '选择节点 / 查看连接 / 测速',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ZashboardScreen()),
        ),
      ));
    }
    return items;
  }

  void _showAddSubscription() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        title: const Text('添加订阅',
            style: TextStyle(color: TvDesignTokens.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              style: const TextStyle(color: TvDesignTokens.textPrimary),
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              style: const TextStyle(color: TvDesignTokens.textPrimary),
              decoration: const InputDecoration(
                labelText: '订阅链接 (URL)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final url = urlController.text.trim();
              if (url.isEmpty) {
                Navigator.pop(dialogContext);
                return;
              }
              ref
                  .read(mihomoControllerProvider.notifier)
                  .addSubscription(nameController.text, url);
              Navigator.pop(dialogContext);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Widget _buildTranslationSettings(TvMetrics m) {
    final kind = ref.watch(translationEngineKindProvider);
    final target = ref.watch(translationTargetLangProvider);
    final layout = ref.watch(bilingualLayoutProvider);

    final items = <Widget>[
      _choiceItem<TranslationEngineKind>(
        m,
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
        m,
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
        m,
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
      ..._engineConfigItems(m, kind),
    ];
    return _settingsList(m, '字幕翻译', items);
  }

  List<Widget> _engineConfigItems(TvMetrics m, TranslationEngineKind kind) {
    switch (kind) {
      case TranslationEngineKind.openai:
      case TranslationEngineKind.anthropic:
        final provider = kind == TranslationEngineKind.openai
            ? openAiConfigProvider
            : anthropicConfigProvider;
        final cfg = ref.watch(provider);
        return [
          _textItem(
            m,
            title: 'API 地址',
            value: cfg.baseUrl,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(baseUrl: v.trim()),
          ),
          _textItem(
            m,
            title: 'API Key',
            value: cfg.apiKey,
            obscure: true,
            onSubmit: (v) => ref.read(provider.notifier).state =
                cfg.copyWith(apiKey: v.trim()),
          ),
          _textItem(
            m,
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
            m,
            title: 'APP ID',
            value: cfg.appId,
            onSubmit: (v) => ref.read(baiduGeneralConfigProvider.notifier).state =
                cfg.copyWith(appId: v.trim()),
          ),
          _textItem(
            m,
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
            m,
            title: 'APP ID',
            value: cfg.appId,
            onSubmit: (v) => ref.read(baiduLlmConfigProvider.notifier).state =
                cfg.copyWith(appId: v.trim()),
          ),
          _textItem(
            m,
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
            m,
            title: 'SecretId',
            value: cfg.secretId,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(secretId: v.trim()),
          ),
          _textItem(
            m,
            title: 'SecretKey',
            value: cfg.secretKey,
            obscure: true,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(secretKey: v.trim()),
          ),
          _textItem(
            m,
            title: '地域 Region',
            value: cfg.region,
            onSubmit: (v) => ref.read(tencentConfigProvider.notifier).state =
                cfg.copyWith(region: v.trim().isEmpty ? 'ap-beijing' : v.trim()),
          ),
        ];
    }
  }

  Widget _textItem(
    TvMetrics m, {
    required String title,
    required String value,
    required ValueChanged<String> onSubmit,
    bool obscure = false,
  }) {
    final display = value.isEmpty
        ? '未设置'
        : (obscure ? '••••••${value.length > 4 ? value.substring(value.length - 4) : ''}' : value);
    return _rowCard(
      m,
      title: title,
      subtitle: display,
      trailing: Icon(Icons.edit,
          color: TvDesignTokens.textSecondary, size: m.s(24)),
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

  Widget _buildAboutSettings(TvMetrics m) {
    return _settingsList(m, '关于', [
      _staticItem(m, title: '应用', subtitle: 'LinPlayer for TV'),
      _staticItem(m, title: '版本', subtitle: kAppVersion),
      _choiceItem<UpdateChannel>(
        m,
        title: '更新渠道',
        current: ref.watch(updateChannelProvider),
        labelOf: updateChannelLabel,
        options: const [
          MapEntry('稳定版（latest）', UpdateChannel.stable),
          MapEntry('预览版（pre-release）', UpdateChannel.prerelease),
        ],
        onPick: (v) => ref.read(updateChannelProvider.notifier).state = v,
      ),
      _actionItem(
        m,
        title: '检查更新',
        subtitle: '当前 $kAppVersion · 启动与每 24 小时自动检查',
        onTap: _checkUpdateTv,
      ),
      _actionItem(
        m,
        title: '导出日志',
        subtitle: '导出到文件并复制路径（排查问题用）',
        onTap: _exportLogs,
      ),
      _actionItem(
        m,
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

  Future<void> _checkUpdateTv() async {
    TvToast.show(context, '正在检查更新…');
    final channel = ref.read(updateChannelProvider);
    final info = await ref.read(appUpdateServiceProvider).checkForUpdate(
          includePrerelease: channel == UpdateChannel.prerelease,
        );
    if (!mounted) return;
    if (info == null) {
      TvToast.show(context, '已是最新版本（$kAppVersion）');
      return;
    }
    ref.read(availableUpdateProvider.notifier).state = info;
    await showUpdateDialog(context, info);
  }

  // ============ 复用控件 ============

  Widget _settingsList(TvMetrics m, String title, List<Widget> items) {
    return ListView(
      padding: EdgeInsets.all(m.spacingXl),
      children: [
        Text(title,
            style: TextStyle(
                fontSize: m.fontSizeXxl,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold)),
        SizedBox(height: m.spacingLg),
        ...items,
      ],
    );
  }

  Widget _rowCard(
    TvMetrics m, {
    required String title,
    String? subtitle,
    required Widget trailing,
    required VoidCallback onSelect,
  }) {
    return TvFocusable(
      padding: const EdgeInsets.all(4),
      onSelect: onSelect,
      child: Container(
        padding: EdgeInsets.all(m.spacingLg),
        margin: EdgeInsets.only(bottom: m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: m.fontSizeMd,
                          color: TvDesignTokens.textPrimary)),
                  if (subtitle != null) ...[
                    SizedBox(height: m.s(2)),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: m.fontSizeXs,
                            color: TvDesignTokens.textSecondary)),
                  ],
                ],
              ),
            ),
            SizedBox(width: m.spacingMd),
            trailing,
          ],
        ),
      ),
    );
  }

  Widget _choiceItem<T>(
    TvMetrics m, {
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
      m,
      title: title,
      subtitle: subtitle ?? currentLabel,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(currentLabel,
              style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.brand)),
          SizedBox(width: m.spacingXs),
          Icon(Icons.chevron_right,
              color: TvDesignTokens.textSecondary, size: m.s(28)),
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

  Widget _toggleItem(
    TvMetrics m, {
    required String title,
    String? subtitle,
    required bool value,
    required VoidCallback onToggle,
  }) {
    return _rowCard(
      m,
      title: title,
      subtitle: subtitle,
      onSelect: onToggle,
      trailing: AnimatedContainer(
        duration: TvDesignTokens.focusAnimationDuration,
        width: m.s(56),
        height: m.s(30),
        decoration: BoxDecoration(
          color: value
              ? TvDesignTokens.brand
              : TvDesignTokens.surfaceElevated,
          borderRadius: BorderRadius.circular(999),
        ),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        padding: EdgeInsets.all(m.s(3)),
        child: Container(
          width: m.s(24),
          height: m.s(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _staticItem(TvMetrics m,
      {required String title, required String subtitle}) {
    return _rowCard(
      m,
      title: title,
      subtitle: subtitle,
      onSelect: () {},
      trailing: const SizedBox.shrink(),
    );
  }

  /// 字体导入行：显示当前字体名 + 点击选择字体文件；已设置时长按清除恢复默认。
  Widget _fontItem(
    TvMetrics m, {
    required String title,
    required String path,
    required String defaultHint,
    required bool isApp,
  }) {
    final isSet = path.isNotEmpty;
    return _rowCard(
      m,
      title: title,
      subtitle: isSet ? p.basename(path) : defaultHint,
      trailing: Icon(isSet ? Icons.clear : Icons.folder_open,
          color: TvDesignTokens.textSecondary, size: m.s(28)),
      onSelect: () {
        if (isSet) {
          _clearFont(isApp: isApp);
        } else {
          _importFont(isApp: isApp);
        }
      },
    );
  }

  Future<void> _importFont({required bool isApp}) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: isApp ? '选择 App 字体文件' : '选择弹幕字体文件',
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf', 'ttc'],
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    final ok = isApp
        ? await FontService.setAppFont(path)
        : await FontService.setDanmakuFont(path);
    if (!mounted) return;
    if (ok) {
      ref
          .read((isApp
                  ? customAppFontPathProvider
                  : customDanmakuFontPathProvider)
              .notifier)
          .state = path;
      TvToast.show(context, '字体已应用：${p.basename(path)}');
    } else {
      TvToast.show(context, '字体加载失败，请确认为有效的 ttf/otf 字体');
    }
  }

  Future<void> _clearFont({required bool isApp}) async {
    if (isApp) {
      await FontService.clearAppFont();
      ref.read(customAppFontPathProvider.notifier).state = '';
    } else {
      await FontService.clearDanmakuFont();
      ref.read(customDanmakuFontPathProvider.notifier).state = '';
    }
    if (mounted) TvToast.show(context, '已恢复默认字体');
  }

  Widget _actionItem(
    TvMetrics m, {
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return _rowCard(
      m,
      title: title,
      subtitle: subtitle,
      onSelect: onTap,
      trailing: Icon(Icons.chevron_right,
          color: TvDesignTokens.textSecondary, size: m.s(28)),
    );
  }
}

class _SettingCategory {
  final IconData icon;
  final String name;
  const _SettingCategory(this.icon, this.name);
}
