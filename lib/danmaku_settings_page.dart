import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'src/ui/frosted_card.dart';
import 'src/ui/glass_background.dart';
import 'state/app_state.dart';
import 'state/danmaku_preferences.dart';

class DanmakuSettingsPage extends StatefulWidget {
  const DanmakuSettingsPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  static const _openPlatformUrl = 'https://doc.dandanplay.com/open/';

  final TextEditingController _apiUrlCtrl = TextEditingController();
  final TextEditingController _appIdCtrl = TextEditingController();
  final TextEditingController _appSecretCtrl = TextEditingController();
  Timer? _credDebounce;

  double? _opacityDraft;
  double? _scaleDraft;
  double? _speedDraft;
  double? _maxLinesDraft;
  bool _showSecret = false;

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).orientation == Orientation.landscape &&
      MediaQuery.of(context).size.shortestSide >= 720;

  @override
  void initState() {
    super.initState();
    _appIdCtrl.text = widget.appState.danmakuAppId;
    _appSecretCtrl.text = widget.appState.danmakuAppSecret;
  }

  @override
  void dispose() {
    _credDebounce?.cancel();
    _apiUrlCtrl.dispose();
    _appIdCtrl.dispose();
    _appSecretCtrl.dispose();
    super.dispose();
  }

  void _scheduleSaveCreds() {
    _credDebounce?.cancel();
    _credDebounce = Timer(const Duration(milliseconds: 500), () {
      widget.appState.setDanmakuAppId(_appIdCtrl.text);
      widget.appState.setDanmakuAppSecret(_appSecretCtrl.text);
    });
  }

  Future<void> _addApiUrl() async {
    final v = _apiUrlCtrl.text.trim();
    if (v.isEmpty) return;
    await widget.appState.addDanmakuApiUrl(v);
    if (!mounted) return;
    setState(() => _apiUrlCtrl.clear());
  }

  @override
  Widget build(BuildContext context) {
    final isTv = _isTv(context);
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final appState = widget.appState;
        final blurAllowed = !isTv;
        final enableBlur = blurAllowed && appState.enableBlurEffects;

        final opacity = _opacityDraft ?? appState.danmakuOpacity;
        final scale = _scaleDraft ?? appState.danmakuScale;
        final speed = _speedDraft ?? appState.danmakuSpeed;
        final maxLines = (_maxLinesDraft ?? appState.danmakuMaxLines.toDouble())
            .round()
            .clamp(1, 40);

        return Scaffold(
          appBar: AppBar(
            title: const Text('弹幕'),
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
                title: '弹幕',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    SwitchListTile(
                      value: appState.danmakuEnabled,
                      onChanged: (v) => appState.setDanmakuEnabled(v),
                      title: const Text('启用弹幕'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.source_outlined),
                      title: const Text('弹幕来源'),
                      subtitle: const Text('本地：手动加载 XML；在线：从 API 匹配下载'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<DanmakuLoadMode>(
                          value: appState.danmakuLoadMode,
                          items: DanmakuLoadMode.values
                              .map(
                                (m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(m.label),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            appState.setDanmakuLoadMode(v);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: '在线弹幕',
                subtitle: '默认弹幕源：https://api.dandanplay.net（可添加多个，长按拖动调整优先级）',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _apiUrlCtrl,
                            decoration: const InputDecoration(
                              labelText: '添加弹幕 API URL',
                              hintText: 'https://api.dandanplay.net',
                            ),
                            onSubmitted: (_) => _addApiUrl(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _addApiUrl,
                          child: const Text('添加'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (appState.danmakuApiUrls.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '尚未添加在线弹幕源',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                    else
                      ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        itemCount: appState.danmakuApiUrls.length,
                        onReorder: appState.reorderDanmakuApiUrls,
                        itemBuilder: (context, index) {
                          final url = appState.danmakuApiUrls[index];
                          return ListTile(
                            key: ValueKey(url),
                            contentPadding: EdgeInsets.zero,
                            leading: ReorderableDragStartListener(
                              index: index,
                              child: const Icon(Icons.drag_handle),
                            ),
                            title: Text(url),
                            trailing: IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () =>
                                  appState.removeDanmakuApiUrlAt(index),
                            ),
                          );
                        },
                      ),
                    const Divider(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.vpn_key_outlined),
                      title: const Text('弹弹play 开放平台凭证（可选）'),
                      subtitle: const Text('使用官方源时通常需要配置 AppId/AppSecret'),
                      trailing: TextButton(
                        onPressed: () async {
                          final ok = await launchUrlString(_openPlatformUrl);
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('无法打开链接')),
                            );
                          }
                        },
                        child: const Text('说明'),
                      ),
                    ),
                    TextField(
                      controller: _appIdCtrl,
                      decoration: const InputDecoration(
                        labelText: 'AppId',
                      ),
                      onChanged: (_) => _scheduleSaveCreds(),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _appSecretCtrl,
                      decoration: InputDecoration(
                        labelText: 'AppSecret',
                        suffixIcon: IconButton(
                          tooltip: _showSecret ? '隐藏' : '显示',
                          icon: Icon(
                            _showSecret
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          onPressed: () =>
                              setState(() => _showSecret = !_showSecret),
                        ),
                      ),
                      obscureText: !_showSecret,
                      onChanged: (_) => _scheduleSaveCreds(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: '弹幕样式',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.format_size),
                      title: const Text('弹幕缩放'),
                      subtitle: Slider(
                        value: scale.clamp(0.5, 1.6),
                        min: 0.5,
                        max: 1.6,
                        onChanged: (v) => setState(() => _scaleDraft = v),
                        onChangeEnd: (v) {
                          setState(() => _scaleDraft = null);
                          // ignore: unawaited_futures
                          appState.setDanmakuScale(v);
                        },
                      ),
                      trailing: Text('${scale.toStringAsFixed(2)}x'),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.opacity_outlined),
                      title: const Text('弹幕透明度'),
                      subtitle: Slider(
                        value: opacity.clamp(0.2, 1.0),
                        min: 0.2,
                        max: 1.0,
                        onChanged: (v) => setState(() => _opacityDraft = v),
                        onChangeEnd: (v) {
                          setState(() => _opacityDraft = null);
                          // ignore: unawaited_futures
                          appState.setDanmakuOpacity(v);
                        },
                      ),
                      trailing: Text('${(opacity * 100).round()}%'),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.speed_outlined),
                      title: const Text('弹幕滚动速度'),
                      subtitle: Slider(
                        value: speed.clamp(0.4, 2.5),
                        min: 0.4,
                        max: 2.5,
                        onChanged: (v) => setState(() => _speedDraft = v),
                        onChangeEnd: (v) {
                          setState(() => _speedDraft = null);
                          // ignore: unawaited_futures
                          appState.setDanmakuSpeed(v);
                        },
                      ),
                      trailing: Text('${speed.toStringAsFixed(2)}x'),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.view_headline_outlined),
                      title: const Text('滚动弹幕最大行数'),
                      subtitle: Slider(
                        value: maxLines.toDouble(),
                        min: 1,
                        max: 40,
                        divisions: 39,
                        label: '$maxLines',
                        onChanged: (v) => setState(() => _maxLinesDraft = v),
                        onChangeEnd: (v) {
                          setState(() => _maxLinesDraft = null);
                          // ignore: unawaited_futures
                          appState.setDanmakuMaxLines(v.round());
                        },
                      ),
                      trailing: Text('$maxLines'),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.danmakuBold,
                      onChanged: (v) => appState.setDanmakuBold(v),
                      title: const Text('粗体'),
                      contentPadding: EdgeInsets.zero,
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
