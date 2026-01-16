import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'danmaku_settings_page.dart';
import 'src/ui/app_icon_service.dart';
import 'src/ui/frosted_card.dart';
import 'src/ui/glass_background.dart';
import 'state/app_state.dart';
import 'state/danmaku_preferences.dart';
import 'state/preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _donateUrl = 'https://afdian.com/a/zzzwannasleep';
  static const _customSentinel = '__custom__';
  static const _subtitleOff = 'off';
  double? _mpvCacheDraftMb;
  double? _uiScaleDraft;

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).orientation == Orientation.landscape &&
      MediaQuery.of(context).size.shortestSide >= 720;

  List<DropdownMenuItem<String>> _audioLangItems(String current) {
    final base = <MapEntry<String, String>>[
      const MapEntry('', '默认'),
      const MapEntry('chi', '中文'),
      const MapEntry('jpn', '日语'),
      const MapEntry('eng', '英语'),
      const MapEntry(_customSentinel, '自定义…'),
    ];

    final isKnown = base.any((e) => e.key == current);
    final items = <DropdownMenuItem<String>>[
      if (current.trim().isNotEmpty && !isKnown)
        DropdownMenuItem(
          value: current,
          child: Text('自定义：$current'),
        ),
      ...base.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
    ];
    return items;
  }

  List<DropdownMenuItem<String>> _subtitleLangItems(String current) {
    final base = <MapEntry<String, String>>[
      const MapEntry('', '默认'),
      const MapEntry(_subtitleOff, '关闭'),
      const MapEntry('chi', '中文'),
      const MapEntry('jpn', '日语'),
      const MapEntry('eng', '英语'),
      const MapEntry(_customSentinel, '自定义…'),
    ];

    final isKnown = base.any((e) => e.key == current);
    final items = <DropdownMenuItem<String>>[
      if (current.trim().isNotEmpty && !isKnown)
        DropdownMenuItem(
          value: current,
          child: Text('自定义：$current'),
        ),
      ...base.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
    ];
    return items;
  }

  Future<String?> _askCustomLang(BuildContext context,
      {required String title, String? initial}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: '例如：chi / zho / jpn / eng / zh / en / ja',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTv = _isTv(context);
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final appState = widget.appState;
        final blurAllowed = !isTv;
        final enableBlur = blurAllowed && appState.enableBlurEffects;

        return Scaffold(
          appBar: AppBar(
            title: const Text('设置'),
            centerTitle: true,
          ),
          body: Stack(
            children: [
              Positioned.fill(
                child: GlassBackground(
                  intensity: blurAllowed ? (enableBlur ? 1 : 0.55) : 0,
                ),
              ),
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _Section(
                    title: '外观',
                    subtitle: blurAllowed
                        ? (enableBlur ? '手机/桌面启用毛玻璃等特效' : '已关闭毛玻璃特效（更流畅）')
                        : 'TV 端自动关闭高开销特效',
                    enableBlur: enableBlur,
                    child: Column(
                      children: [
                        SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment(
                                value: ThemeMode.system, label: Text('系统')),
                            ButtonSegment(
                                value: ThemeMode.light, label: Text('浅色')),
                            ButtonSegment(
                                value: ThemeMode.dark, label: Text('深色')),
                          ],
                          selected: {appState.themeMode},
                          onSelectionChanged: (s) =>
                              appState.setThemeMode(s.first),
                        ),
                        const SizedBox(height: 10),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.zoom_out_map),
                          title: const Text('UI 缩放'),
                          subtitle: Builder(
                            builder: (context) {
                              final value =
                                  (_uiScaleDraft ?? appState.uiScaleFactor)
                                      .clamp(0.5, 2.0)
                                      .toDouble();
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '当前：${value.toStringAsFixed(2)}x（0.5-2.0）',
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: appState.uiScaleFactor == 1.0
                                            ? null
                                            : () {
                                                // ignore: unawaited_futures
                                                appState.setUiScaleFactor(1.0);
                                              },
                                        child: const Text('重置'),
                                      ),
                                    ],
                                  ),
                                  Slider(
                                    value: value,
                                    min: 0.5,
                                    max: 2.0,
                                    divisions: 15,
                                    label: '${value.toStringAsFixed(2)}x',
                                    onChanged: (v) =>
                                        setState(() => _uiScaleDraft = v),
                                    onChangeEnd: (v) {
                                      setState(() => _uiScaleDraft = null);
                                      // ignore: unawaited_futures
                                      appState.setUiScaleFactor(v);
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: appState.enableBlurEffects,
                          onChanged: blurAllowed
                              ? (v) => appState.setEnableBlurEffects(v)
                              : null,
                          title: const Text('毛玻璃特效'),
                          subtitle: Text(
                            blurAllowed
                                ? '关闭可提升滚动/动画流畅度（尤其是高刷屏）'
                                : 'TV 端强制关闭以提升流畅度',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: appState.useDynamicColor,
                          onChanged: (v) => appState.setUseDynamicColor(v),
                          title: const Text('莫奈取色（Material You）'),
                          subtitle: const Text('Android 12+ 生效，其它平台自动回退到预设主题'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.palette_outlined),
                          title: const Text('预设主题'),
                          subtitle: const Text('用于非动态取色或不支持的平台'),
                          trailing: DropdownButtonHideUnderline(
                            child: DropdownButton<ThemeTemplate>(
                              value: appState.themeTemplate,
                              items: ThemeTemplate.values
                                  .map(
                                    (t) => DropdownMenuItem(
                                      value: t,
                                      child: Text(t.label),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v == null) return;
                                appState.setThemeTemplate(v);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Section(
                    title: '播放',
                    enableBlur: enableBlur,
                    child: Column(
                      children: [
                        SwitchListTile(
                          value: appState.preferHardwareDecode,
                          onChanged: (v) => appState.setPreferHardwareDecode(v),
                          title: const Text('优先硬解'),
                          subtitle: const Text('TV/低端设备建议关闭以提升兼容性'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.storage_outlined),
                          title: const Text('MPV 缓存大小'),
                          subtitle: Builder(
                            builder: (context) {
                              final cacheMb = (_mpvCacheDraftMb ??
                                      appState.mpvCacheSizeMb.toDouble())
                                  .round()
                                  .clamp(200, 2048);
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('当前：${cacheMb}MB（200-2048MB，默认500MB）'),
                                  Slider(
                                    value: cacheMb.toDouble(),
                                    min: 200,
                                    max: 2048,
                                    divisions: 2048 - 200,
                                    label: '${cacheMb}MB',
                                    onChanged: (v) =>
                                        setState(() => _mpvCacheDraftMb = v),
                                    onChangeEnd: (v) {
                                      final mb = v.round().clamp(200, 2048);
                                      setState(() => _mpvCacheDraftMb = null);
                                      // ignore: unawaited_futures
                                      appState.setMpvCacheSizeMb(mb);
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        if (isDesktop) ...[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.open_in_new),
                            title: const Text('外部 MPV（PC）'),
                            subtitle: Text(
                              appState.externalMpvPath.trim().isEmpty
                                  ? '未设置：将尝试调用系统 mpv（PATH 或同目录）'
                                  : appState.externalMpvPath,
                            ),
                            trailing: const Icon(Icons.folder_open),
                            onTap: () async {
                              final result =
                                  await FilePicker.platform.pickFiles(
                                dialogTitle: '选择 mpv 可执行文件',
                                allowMultiple: false,
                                withData: false,
                                type: FileType.any,
                              );
                              final path = result?.files.single.path;
                              if (path == null || path.trim().isEmpty) return;
                              // ignore: unawaited_futures
                              appState.setExternalMpvPath(path);
                            },
                          ),
                          if (appState.externalMpvPath.trim().isNotEmpty) ...[
                            const Divider(height: 1),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.delete_outline),
                              title: const Text('清除外部 MPV 路径'),
                              onTap: () {
                                // ignore: unawaited_futures
                                appState.setExternalMpvPath('');
                              },
                            ),
                          ],
                          const Divider(height: 1),
                        ],
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.audiotrack),
                          title: const Text('优先音轨'),
                          trailing: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: appState.preferredAudioLang,
                              items:
                                  _audioLangItems(appState.preferredAudioLang),
                              onChanged: (v) async {
                                if (v == null) return;
                                if (v == _customSentinel) {
                                  final code = await _askCustomLang(
                                    context,
                                    title: '自定义音轨语言',
                                    initial: appState.preferredAudioLang,
                                  );
                                  if (code == null) return;
                                  await appState.setPreferredAudioLang(code);
                                  return;
                                }
                                await appState.setPreferredAudioLang(v);
                              },
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.subtitles_outlined),
                          title: const Text('优先字幕'),
                          trailing: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: appState.preferredSubtitleLang,
                              items: _subtitleLangItems(
                                  appState.preferredSubtitleLang),
                              onChanged: (v) async {
                                if (v == null) return;
                                if (v == _customSentinel) {
                                  final code = await _askCustomLang(
                                    context,
                                    title: '自定义字幕语言',
                                    initial: appState.preferredSubtitleLang,
                                  );
                                  if (code == null) return;
                                  await appState.setPreferredSubtitleLang(code);
                                  return;
                                }
                                await appState.setPreferredSubtitleLang(v);
                              },
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.comment_outlined),
                          title: const Text('弹幕'),
                          subtitle: Text(
                            appState.danmakuLoadMode == DanmakuLoadMode.online
                                ? '在线：${appState.danmakuApiUrls.isEmpty ? '未配置弹幕源' : appState.danmakuApiUrls.first}'
                                : '本地弹幕',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => DanmakuSettingsPage(
                                    appState: widget.appState),
                              ),
                            );
                          },
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.video_file_outlined),
                          title: const Text('优先视频版本'),
                          trailing: DropdownButtonHideUnderline(
                            child: DropdownButton<VideoVersionPreference>(
                              value: appState.preferredVideoVersion,
                              items: VideoVersionPreference.values
                                  .map(
                                    (p) => DropdownMenuItem(
                                      value: p,
                                      child: Text(p.label),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v == null) return;
                                appState.setPreferredVideoVersion(v);
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _Section(
                    title: '应用',
                    enableBlur: enableBlur,
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.apps_outlined),
                          title: const Text('应用图标'),
                          subtitle: Text(AppIconService.isSupported
                              ? '切换后可能需要等待桌面刷新'
                              : '仅 Android 支持'),
                          trailing: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: appState.appIconId,
                              items: const [
                                DropdownMenuItem(
                                    value: 'default', child: Text('默认')),
                                DropdownMenuItem(
                                    value: 'pink', child: Text('粉色')),
                                DropdownMenuItem(
                                    value: 'purple', child: Text('紫色')),
                                DropdownMenuItem(
                                    value: 'miku', child: Text('初音未来')),
                              ],
                              onChanged: !AppIconService.isSupported
                                  ? null
                                  : (v) async {
                                      if (v == null) return;
                                      final ok =
                                          await AppIconService.setIconId(v);
                                      if (!ok && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                              content:
                                                  Text('切换失败（可能不支持当前系统/桌面）')),
                                        );
                                        return;
                                      }
                                      await appState.setAppIconId(v);
                                    },
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading:
                              const Icon(Icons.volunteer_activism_outlined),
                          title: const Text('捐赠'),
                          subtitle: const Text('支持作者继续开发（爱发电）'),
                          trailing: const Icon(Icons.open_in_new),
                          onTap: () async {
                            final ok = await launchUrlString(_donateUrl);
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('无法打开链接，请检查系统浏览器/网络设置')),
                              );
                            }
                          },
                        ),
                        const Divider(height: 1),
                        const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.info_outline),
                          title: Text('关于'),
                          subtitle: Text('LinPlayer'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    this.subtitle,
    required this.child,
    required this.enableBlur,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    return FrostedCard(
      enableBlur: enableBlur,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if ((subtitle ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!.trim(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
