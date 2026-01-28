import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'src/device/device_type.dart';
import 'src/ui/app_components.dart';
import 'src/ui/glass_blur.dart';
import 'state/app_state.dart';
import 'state/interaction_preferences.dart';

class InteractionSettingsPage extends StatefulWidget {
  const InteractionSettingsPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<InteractionSettingsPage> createState() =>
      _InteractionSettingsPageState();
}

class _InteractionSettingsPageState extends State<InteractionSettingsPage> {
  bool get _isTv => DeviceType.isTv;

  double? _longPressMultiplierDraft;
  double? _bufferSpeedRefreshSecondsDraft;
  double? _seekBackwardDraft;
  double? _seekForwardDraft;

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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final appState = widget.appState;
        final blurAllowed = !_isTv;
        final enableBlur = blurAllowed && appState.enableBlurEffects;

        final longPressMultiplier =
            _longPressMultiplierDraft ?? appState.longPressSpeedMultiplier;
        final seekBackward =
            (_seekBackwardDraft ?? appState.seekBackwardSeconds.toDouble())
                .round()
                .clamp(1, 120);
        final seekForward =
            (_seekForwardDraft ?? appState.seekForwardSeconds.toDouble())
                .round()
                .clamp(1, 120);
        final bufferSpeedRefreshSeconds =
            (_bufferSpeedRefreshSecondsDraft ??
                    appState.bufferSpeedRefreshSeconds)
                .clamp(0.1, 3.0)
                .toDouble();

        return Scaffold(
          appBar: GlassAppBar(
            enableBlur: enableBlur,
            child: AppBar(
              title: const Text('交互设置'),
              centerTitle: true,
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _Section(
                title: '播放手势',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    SwitchListTile(
                      value: appState.gestureBrightness,
                      onChanged: (v) => appState.setGestureBrightness(v),
                      title: const Text('左侧屏幕上下拖动'),
                      subtitle: const Text('以调整屏幕亮度'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.gestureVolume,
                      onChanged: (v) => appState.setGestureVolume(v),
                      title: const Text('右侧屏幕上下拖动'),
                      subtitle: const Text('以调整音量'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.gestureSeek,
                      onChanged: (v) => appState.setGestureSeek(v),
                      title: const Text('横向滑动'),
                      subtitle: const Text('调整视频进度'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.gestureLongPressSpeed,
                      onChanged: (v) => appState.setGestureLongPressSpeed(v),
                      title: const Text('长按加速'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.speed_outlined),
                      title: const Text('长按时的速度倍率'),
                      subtitle: const Text('会基于当前播放速率调整倍率'),
                      value: longPressMultiplier,
                      min: 1.0,
                      max: 4.0,
                      divisions: 12,
                      trailing: Text(longPressMultiplier.toStringAsFixed(2)),
                      sliderTheme: _sliderTheme(context),
                      onChanged: (v) =>
                          setState(() => _longPressMultiplierDraft = v),
                      onChangeEnd: (v) async {
                        setState(() => _longPressMultiplierDraft = null);
                        await appState.setLongPressSpeedMultiplier(v);
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.longPressSlideSpeed,
                      onChanged: (v) => appState.setLongPressSlideSpeed(v),
                      title: const Text('长按时滑动调整倍速'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: '播放时双击',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    _doubleTapTile(
                      context,
                      title: '屏幕左侧',
                      value: appState.doubleTapLeft,
                      onChanged: (v) => appState.setDoubleTapLeft(v),
                    ),
                    const Divider(height: 1),
                    _doubleTapTile(
                      context,
                      title: '屏幕中间',
                      value: appState.doubleTapCenter,
                      onChanged: (v) => appState.setDoubleTapCenter(v),
                    ),
                    const Divider(height: 1),
                    _doubleTapTile(
                      context,
                      title: '屏幕右侧',
                      value: appState.doubleTapRight,
                      onChanged: (v) => appState.setDoubleTapRight(v),
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
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.home_outlined),
                      title: const Text('播放中返回桌面行为'),
                      subtitle: Text(appState.returnHomeBehavior.label),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<ReturnHomeBehavior>(
                          value: appState.returnHomeBehavior,
                          items: ReturnHomeBehavior.values
                              .map(
                                (m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(m.label),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            appState.setReturnHomeBehavior(v);
                          },
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.showSystemTimeInControls,
                      onChanged: (v) => appState.setShowSystemTimeInControls(v),
                      title: const Text('在控制栏上显示系统时间'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.showBufferSpeed,
                      onChanged: (v) => appState.setShowBufferSpeed(v),
                      title: const Text('显示缓冲速度'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('缓冲速度刷新间隔 (秒)'),
                      subtitle: const Text('0.1 - 3.0，默认 0.5'),
                      value: bufferSpeedRefreshSeconds,
                      min: 0.1,
                      max: 3.0,
                      divisions: 29,
                      trailing:
                          Text('${bufferSpeedRefreshSeconds.toStringAsFixed(1)}s'),
                      sliderTheme: _sliderTheme(context),
                      onChanged: (v) =>
                          setState(() => _bufferSpeedRefreshSecondsDraft = v),
                      onChangeEnd: (v) async {
                        final seconds = (v * 10).round() / 10.0;
                        setState(() => _bufferSpeedRefreshSecondsDraft = null);
                        await appState.setBufferSpeedRefreshSeconds(seconds);
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.showBatteryInControls,
                      onChanged: (v) => appState.setShowBatteryInControls(v),
                      title: const Text('在控制栏上显示剩余电量'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.replay),
                      title: const Text('快退时间 (秒)'),
                      value: seekBackward.toDouble(),
                      min: 1,
                      max: 120,
                      divisions: 119,
                      trailing: Text('$seekBackward'),
                      sliderTheme: _sliderTheme(context),
                      onChanged: (v) => setState(() => _seekBackwardDraft = v),
                      onChangeEnd: (v) async {
                        final seconds = v.round().clamp(1, 120);
                        setState(() => _seekBackwardDraft = null);
                        await appState.setSeekBackwardSeconds(seconds);
                      },
                    ),
                    const Divider(height: 1),
                    _SliderTile(
                      leading: const Icon(Icons.forward),
                      title: const Text('快进时间 (秒)'),
                      value: seekForward.toDouble(),
                      min: 1,
                      max: 120,
                      divisions: 119,
                      trailing: Text('$seekForward'),
                      sliderTheme: _sliderTheme(context),
                      onChanged: (v) => setState(() => _seekForwardDraft = v),
                      onChangeEnd: (v) async {
                        final seconds = v.round().clamp(1, 120);
                        setState(() => _seekForwardDraft = null);
                        await appState.setSeekForwardSeconds(seconds);
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.forceRemoteControlKeys,
                      onChanged: (v) => appState.setForceRemoteControlKeys(v),
                      title: const Text('强制启用遥控器按键支持'),
                      subtitle: const Text('如果不是 TV 设备，不要启用该选项!!!'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '提示：部分手势会影响拖动/双击的手感，可按需关闭。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _doubleTapTile(
    BuildContext context, {
    required String title,
    required DoubleTapAction value,
    required ValueChanged<DoubleTapAction> onChanged,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.touch_app_outlined),
      title: Text(title),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<DoubleTapAction>(
          value: value,
          items: DoubleTapAction.values
              .map(
                (a) => DropdownMenuItem(
                  value: a,
                  child: Text(a.label),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            onChanged(v);
          },
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.trailing,
    required this.sliderTheme,
    this.onChanged,
    this.onChangeEnd,
  });

  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final Widget trailing;
  final SliderThemeData sliderTheme;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: title,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle != null) subtitle!,
          SliderTheme(
            data: sliderTheme,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: math.max(1, divisions),
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
      trailing: trailing,
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    required this.enableBlur,
  });

  final String title;
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
