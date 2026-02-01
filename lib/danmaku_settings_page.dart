import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lin_player_prefs/lin_player_prefs.dart';
import 'package:lin_player_state/lin_player_state.dart';
import 'package:lin_player_ui/lin_player_ui.dart';
import 'package:url_launcher/url_launcher_string.dart';

class DanmakuSettingsPage extends StatefulWidget {
  const DanmakuSettingsPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  static const _openPlatformUrl = 'https://doc.dandanplay.com/open/';
  static const double _baseDanmakuFontSize = 18.0;
  static const int _fontSizeMin = 9;
  static const int _fontSizeMax = 29;
  static const int _speedUiMin = 1;
  static const int _speedUiMax = 20;
  static const double _speedMin = 0.4;
  static const double _speedMax = 2.5;

  static int _speedUiFromMultiplier(double speed) {
    final s = speed.clamp(_speedMin, _speedMax).toDouble();
    final t = (_speedMax - s) / (_speedMax - _speedMin); // 0..1
    return (_speedUiMin + t * (_speedUiMax - _speedUiMin))
        .round()
        .clamp(_speedUiMin, _speedUiMax);
  }

  static double _speedMultiplierFromUi(double value) {
    final ui = value.clamp(_speedUiMin.toDouble(), _speedUiMax.toDouble());
    final t = (ui - _speedUiMin) / (_speedUiMax - _speedUiMin); // 0..1
    return (_speedMax - t * (_speedMax - _speedMin)).toDouble();
  }

  final TextEditingController _apiUrlCtrl = TextEditingController();
  final TextEditingController _appIdCtrl = TextEditingController();
  final TextEditingController _appSecretCtrl = TextEditingController();
  final TextEditingController _blockWordsCtrl = TextEditingController();

  Timer? _credDebounce;
  bool _showSecret = false;

  double? _opacityDraft;
  double? _scaleDraft;
  double? _speedDraft;
  double? _scrollMaxLinesDraft;
  double? _topMaxLinesDraft;
  double? _bottomMaxLinesDraft;

  bool _isTv(BuildContext context) => DeviceType.isTv;

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
    _blockWordsCtrl.dispose();
    super.dispose();
  }

  SliderThemeData _sliderTheme(BuildContext context, {bool showTicks = false}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return theme.sliderTheme.copyWith(
      trackHeight: 8,
      activeTrackColor: cs.primary.withValues(alpha: 0.55),
      inactiveTrackColor: cs.onSurface.withValues(alpha: 0.18),
      thumbColor: cs.primary.withValues(alpha: 0.9),
      overlayColor: cs.primary.withValues(alpha: 0.12),
      thumbShape: const _BarThumbShape(width: 4, height: 28),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      trackShape: const RoundedRectSliderTrackShape(),
      showValueIndicator: ShowValueIndicator.never,
      tickMarkShape: showTicks
          ? const RoundSliderTickMarkShape(tickMarkRadius: 2.4)
          : const RoundSliderTickMarkShape(tickMarkRadius: 0),
      activeTickMarkColor: cs.primary.withValues(alpha: 0.75),
      inactiveTickMarkColor: cs.onSurface.withValues(alpha: 0.25),
    );
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

  Future<void> _showBlockWordsSheet() async {
    _blockWordsCtrl.text = widget.appState.danmakuBlockWords;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '弹幕屏蔽词',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _blockWordsCtrl,
                maxLines: 10,
                minLines: 6,
                decoration: const InputDecoration(
                  hintText: '每行一个屏蔽词；正则请用 /.../ 包裹',
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '提示：多个规则请换行分隔；正则以“/”开头并以“/”结尾。',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() => _blockWordsCtrl.clear()),
                    child: const Text('清空'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      await widget.appState
                          .setDanmakuBlockWords(_blockWordsCtrl.text);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
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
        final scale =
            (_scaleDraft ?? appState.danmakuScale).clamp(0.5, 1.6).toDouble();
        final speed = (_speedDraft ?? appState.danmakuSpeed)
            .clamp(_speedMin, _speedMax)
            .toDouble();
        final fontSize = (scale * _baseDanmakuFontSize)
            .round()
            .clamp(_fontSizeMin, _fontSizeMax);
        final speedUi = _speedUiFromMultiplier(speed);

        final scrollLines =
            (_scrollMaxLinesDraft ?? appState.danmakuMaxLines.toDouble())
                .round()
                .clamp(1, 40);
        final topLines =
            (_topMaxLinesDraft ?? appState.danmakuTopMaxLines.toDouble())
                .round()
                .clamp(0, 40);
        final bottomLines =
            (_bottomMaxLinesDraft ?? appState.danmakuBottomMaxLines.toDouble())
                .round()
                .clamp(0, 40);

        return Scaffold(
          appBar: GlassAppBar(
            enableBlur: enableBlur,
            child: AppBar(
              title: const Text('弹幕'),
              centerTitle: true,
            ),
          ),
          body: ListView(
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
                      secondary: const Icon(Icons.comment_outlined),
                      title: const Text('弹幕'),
                      subtitle: Text(
                        appState.danmakuLoadMode == DanmakuLoadMode.online
                            ? '来自 DandanPlay API / 仅包含中文弹幕'
                            : '本地 XML 弹幕',
                      ),
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
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.danmakuShowHeatmap,
                      onChanged: (v) => appState.setDanmakuShowHeatmap(v),
                      secondary: const Icon(Icons.whatshot_outlined),
                      title: const Text('显示热力图'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.danmakuRememberSelectedSource,
                      onChanged: (v) =>
                          appState.setDanmakuRememberSelectedSource(v),
                      secondary: const Icon(Icons.history_outlined),
                      title: const Text('记忆手动匹配的弹幕'),
                      subtitle: const Text(
                        '匹配弹幕时，优先使用该剧集最近一次手动搜索时选择的匹配项',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.translate_outlined),
                      title: const Text('弹幕简繁转换'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<DanmakuChConvert>(
                          value: appState.danmakuChConvert,
                          items: DanmakuChConvert.values
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v,
                                  child: Text(v.label),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            appState.setDanmakuChConvert(v);
                          },
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.danmakuMergeRelated,
                      onChanged: (v) => appState.setDanmakuMergeRelated(v),
                      secondary: const Icon(Icons.call_merge),
                      title: const Text('合并关联弹幕'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: '弹幕数量',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    _SliderTile(
                      leading: const Icon(Icons.view_headline_outlined),
                      title: const Text('滚动弹幕最大行数'),
                      value: scrollLines.toDouble(),
                      min: 1,
                      max: 40,
                      divisions: 39,
                      trailing: Text('$scrollLines'),
                      sliderTheme: _sliderTheme(context, showTicks: true),
                      onChanged: (v) =>
                          setState(() => _scrollMaxLinesDraft = v),
                      onChangeEnd: (v) async {
                        setState(() => _scrollMaxLinesDraft = null);
                        await appState.setDanmakuMaxLines(v.round());
                      },
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.vertical_align_top_outlined),
                      title: const Text('顶部固定弹幕最大行数'),
                      value: topLines.toDouble(),
                      min: 0,
                      max: 40,
                      divisions: 40,
                      trailing: Text('$topLines'),
                      sliderTheme: _sliderTheme(context, showTicks: true),
                      onChanged: (v) => setState(() => _topMaxLinesDraft = v),
                      onChangeEnd: (v) async {
                        setState(() => _topMaxLinesDraft = null);
                        await appState.setDanmakuTopMaxLines(v.round());
                      },
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.vertical_align_bottom_outlined),
                      title: const Text('底部弹幕最大行数'),
                      value: bottomLines.toDouble(),
                      min: 0,
                      max: 40,
                      divisions: 40,
                      trailing: Text('$bottomLines'),
                      sliderTheme: _sliderTheme(context, showTicks: true),
                      onChanged: (v) =>
                          setState(() => _bottomMaxLinesDraft = v),
                      onChangeEnd: (v) async {
                        setState(() => _bottomMaxLinesDraft = null);
                        await appState.setDanmakuBottomMaxLines(v.round());
                      },
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
                    _SliderTile(
                      leading: const Icon(Icons.format_size),
                      title: const Text('弹幕字体大小'),
                      value: fontSize.toDouble(),
                      min: _fontSizeMin.toDouble(),
                      max: _fontSizeMax.toDouble(),
                      divisions: _fontSizeMax - _fontSizeMin,
                      trailing: Text('$fontSize'),
                      sliderTheme: _sliderTheme(context, showTicks: true),
                      onChanged: (v) =>
                          setState(() => _scaleDraft = v / _baseDanmakuFontSize),
                      onChangeEnd: (v) async {
                        setState(() => _scaleDraft = null);
                        await appState.setDanmakuScale(v / _baseDanmakuFontSize);
                      },
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.speed_outlined),
                      title: const Text('弹幕滚动速度(数值越小速度越快)'),
                      value: speedUi.toDouble(),
                      min: _speedUiMin.toDouble(),
                      max: _speedUiMax.toDouble(),
                      divisions: _speedUiMax - _speedUiMin,
                      trailing: Text('$speedUi'),
                      sliderTheme: _sliderTheme(context, showTicks: true),
                      onChanged: (v) => setState(
                        () => _speedDraft = _speedMultiplierFromUi(v),
                      ),
                      onChangeEnd: (v) async {
                        setState(() => _speedDraft = null);
                        await appState
                            .setDanmakuSpeed(_speedMultiplierFromUi(v));
                      },
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.opacity_outlined),
                      title: const Text('弹幕透明度'),
                      value: opacity.clamp(0.2, 1.0),
                      min: 0.2,
                      max: 1.0,
                      trailing: Text('${(opacity * 100).round()}%'),
                      sliderTheme: _sliderTheme(context),
                      onChanged: (v) => setState(() => _opacityDraft = v),
                      onChangeEnd: (v) async {
                        setState(() => _opacityDraft = null);
                        await appState.setDanmakuOpacity(v);
                      },
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
              const SizedBox(height: 12),
              _Section(
                title: '杂项',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    SwitchListTile(
                      value: appState.danmakuMergeDuplicates,
                      onChanged: (v) => appState.setDanmakuMergeDuplicates(v),
                      title: const Text('合并重复弹幕'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.danmakuPreventOverlap,
                      onChanged: (v) => appState.setDanmakuPreventOverlap(v),
                      title: const Text('防止弹幕重叠'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.rule_folder_outlined),
                      title: const Text('弹幕匹配模式'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<DanmakuMatchMode>(
                          value: appState.danmakuMatchMode,
                          items: DanmakuMatchMode.values
                              .map(
                                (m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(m.label),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            appState.setDanmakuMatchMode(v);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: 'Danmaku Blacklist Words',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.block_outlined),
                      title: const Text('弹幕屏蔽词'),
                      subtitle: const Text('添加屏蔽词；正则用 /.../ 包裹'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _showBlockWordsSheet,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: 'Danmaku API',
                subtitle: '添加和管理弹幕 API 列表，支持排序',
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
            ],
          ),
        );
      },
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.leading,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.trailing,
    required this.sliderTheme,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Widget leading;
  final Widget title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final Widget trailing;
  final SliderThemeData sliderTheme;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: title,
      subtitle: SliderTheme(
        data: sliderTheme,
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
      trailing: trailing,
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
    return AppPanel(
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

class _BarThumbShape extends SliderComponentShape {
  const _BarThumbShape({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size(width, height);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final paint = Paint()
      ..color = sliderTheme.thumbColor ?? sliderTheme.activeTrackColor!;
    final rect = Rect.fromCenter(center: center, width: width, height: height);
    final rrect =
        RRect.fromRectAndRadius(rect, Radius.circular(width.clamp(2, 20)));
    context.canvas.drawRRect(rrect, paint);
  }
}
