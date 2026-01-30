import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../state/interaction_preferences.dart';
import '../shared/player_types.dart';

class PlayerGestureOverlay {
  const PlayerGestureOverlay({required this.icon, required this.text});

  final IconData icon;
  final String text;
}

typedef ControlsVisibilityCallback = void Function({required bool scheduleHide});

typedef SeekClamp = Duration Function(Duration target, Duration duration);

class PlayerGestureController extends ChangeNotifier {
  PlayerGestureController({
    double initialBrightness = 1.0,
    double initialVolume = 1.0,
  })  : _brightness = initialBrightness.clamp(0.2, 1.0).toDouble(),
        _volume = initialVolume.clamp(0.0, 1.0).toDouble();

  static const Duration overlayAutoHideDelay = Duration(milliseconds: 800);

  double _brightness = 1.0;
  double _volume = 1.0;
  PlayerGestureOverlay? _overlay;
  Timer? _overlayTimer;
  Offset? _doubleTapDownPosition;

  // Gesture runtime state.
  GestureMode _mode = GestureMode.none;
  Offset? _gestureStartPos;
  Duration _seekGestureStartPosition = Duration.zero;
  Duration? _seekGesturePreviewPosition;
  double _gestureStartBrightness = 1.0;
  double _gestureStartVolume = 1.0;
  double? _longPressBaseRate;
  Offset? _longPressStartPos;

  double get brightness => _brightness;
  double get volume => _volume;
  PlayerGestureOverlay? get overlay => _overlay;
  Duration? get seekPreviewPosition => _seekGesturePreviewPosition;

  GestureMode get mode => _mode;

  void recordDoubleTapDown(Offset localPosition) {
    _doubleTapDownPosition = localPosition;
  }

  Offset? consumeDoubleTapDownPosition() {
    final pos = _doubleTapDownPosition;
    _doubleTapDownPosition = null;
    return pos;
  }

  void setBrightness(double value) {
    final v = value.clamp(0.2, 1.0).toDouble();
    if (v == _brightness) return;
    _brightness = v;
    notifyListeners();
  }

  void setVolume(double value) {
    final v = value.clamp(0.0, 1.0).toDouble();
    if (v == _volume) return;
    _volume = v;
    notifyListeners();
  }

  void showOverlay({
    required IconData icon,
    required String text,
    Duration delay = overlayAutoHideDelay,
  }) {
    _overlay = PlayerGestureOverlay(icon: icon, text: text);
    notifyListeners();
    _scheduleHideOverlay(delay);
  }

  void hideOverlay([Duration delay = overlayAutoHideDelay]) {
    _scheduleHideOverlay(delay);
  }

  void _scheduleHideOverlay(Duration delay) {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(delay, () {
      _overlay = null;
      notifyListeners();
    });
  }

  void resetGestureState() {
    _mode = GestureMode.none;
    _gestureStartPos = null;
    _seekGesturePreviewPosition = null;
    _longPressBaseRate = null;
    _longPressStartPos = null;
  }

  void startSeekDrag(Offset localPosition, Duration position) {
    _mode = GestureMode.seek;
    _gestureStartPos = localPosition;
    _seekGestureStartPosition = position;
    _seekGesturePreviewPosition = position;
  }

  Duration? updateSeekDrag({
    required Offset localPosition,
    required double width,
    required Duration duration,
    required SeekClamp clamp,
  }) {
    if (_mode != GestureMode.seek) return null;
    final startPos = _gestureStartPos;
    if (startPos == null) return null;
    if (width <= 0) return null;
    if (duration <= Duration.zero) return null;

    final dx = localPosition.dx - startPos.dx;
    final maxSeekSeconds = math.min(duration.inSeconds.toDouble(), 300.0);
    if (maxSeekSeconds <= 0) return null;

    final deltaSeconds = (dx / width) * maxSeekSeconds;
    final delta = Duration(seconds: deltaSeconds.round());
    final target = clamp(_seekGestureStartPosition + delta, duration);
    _seekGesturePreviewPosition = target;
    return delta;
  }

  Duration? endSeekDrag() {
    if (_mode != GestureMode.seek) return null;
    final target = _seekGesturePreviewPosition;
    resetGestureState();
    return target;
  }

  void startSideDrag({
    required Offset localPosition,
    required double width,
    required bool brightnessEnabled,
    required bool volumeEnabled,
  }) {
    _gestureStartPos = localPosition;
    final isLeft = width <= 0 ? true : localPosition.dx < width / 2;
    if (isLeft && brightnessEnabled) {
      _mode = GestureMode.brightness;
      _gestureStartBrightness = _brightness;
      return;
    }
    if (!isLeft && volumeEnabled) {
      _mode = GestureMode.volume;
      _gestureStartVolume = _volume;
      return;
    }
    _mode = GestureMode.none;
  }

  double? updateSideDrag({
    required Offset localPosition,
    required double height,
  }) {
    if (_mode != GestureMode.brightness && _mode != GestureMode.volume) {
      return null;
    }
    final startPos = _gestureStartPos;
    if (startPos == null) return null;
    if (height <= 0) return null;

    final dy = localPosition.dy - startPos.dy;
    final delta = (-dy / height).clamp(-1.0, 1.0);

    switch (_mode) {
      case GestureMode.brightness:
        return (_gestureStartBrightness + delta).clamp(0.2, 1.0).toDouble();
      case GestureMode.volume:
        return (_gestureStartVolume + delta).clamp(0.0, 1.0).toDouble();
      case GestureMode.none:
      case GestureMode.seek:
      case GestureMode.speed:
        return null;
    }
  }

  void endSideDrag() {
    if (_mode == GestureMode.brightness || _mode == GestureMode.volume) {
      hideOverlay();
    }
    resetGestureState();
  }

  void startLongPressSpeed({
    required Offset localPosition,
    required double baseRate,
  }) {
    _mode = GestureMode.speed;
    _longPressStartPos = localPosition;
    _longPressBaseRate = baseRate;
  }

  double? updateLongPressSpeedMultiplier({
    required Offset localPosition,
    required double height,
    required double baseMultiplier,
  }) {
    if (_mode != GestureMode.speed) return null;
    final baseRate = _longPressBaseRate;
    final startPos = _longPressStartPos;
    if (baseRate == null || startPos == null) return null;
    if (height <= 0) return null;

    final dy = localPosition.dy - startPos.dy;
    final delta = (-dy / height) * 2.0;
    return (baseMultiplier + delta).clamp(1.0, 4.0).toDouble();
  }

  double? endLongPressSpeed() {
    if (_mode != GestureMode.speed) return null;
    final base = _longPressBaseRate;
    resetGestureState();
    hideOverlay();
    return base;
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    super.dispose();
  }
}

class PlayerGestureDetectorLayer extends StatelessWidget {
  const PlayerGestureDetectorLayer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.position,
    required this.duration,
    required this.onToggleControls,
    required this.onTogglePlayPause,
    required this.onSeekRelative,
    required this.onSeekTo,
    required this.doubleTapLeft,
    required this.doubleTapCenter,
    required this.doubleTapRight,
    required this.seekBackwardSeconds,
    required this.seekForwardSeconds,
    required this.gestureSeekEnabled,
    required this.gestureBrightnessEnabled,
    required this.gestureVolumeEnabled,
    required this.gestureLongPressEnabled,
    required this.longPressSlideEnabled,
    required this.longPressSpeedMultiplier,
    required this.getPlaybackRate,
    required this.onSetPlaybackRate,
    required this.onSetVolume,
    required this.clampSeekTarget,
    this.onShowControls,
    this.onScheduleControlsHide,
    this.child = const SizedBox.expand(),
  });

  final PlayerGestureController controller;
  final bool enabled;
  final Duration position;
  final Duration duration;

  final VoidCallback onToggleControls;
  final FutureOr<void> Function() onTogglePlayPause;
  final FutureOr<void> Function(Duration delta) onSeekRelative;
  final FutureOr<void> Function(Duration target) onSeekTo;

  final DoubleTapAction doubleTapLeft;
  final DoubleTapAction doubleTapCenter;
  final DoubleTapAction doubleTapRight;
  final int seekBackwardSeconds;
  final int seekForwardSeconds;

  final bool gestureSeekEnabled;
  final bool gestureBrightnessEnabled;
  final bool gestureVolumeEnabled;
  final bool gestureLongPressEnabled;
  final bool longPressSlideEnabled;
  final double longPressSpeedMultiplier;

  final double Function()? getPlaybackRate;
  final FutureOr<void> Function(double rate)? onSetPlaybackRate;
  final FutureOr<void> Function(double volume)? onSetVolume;

  final SeekClamp clampSeekTarget;

  final ControlsVisibilityCallback? onShowControls;
  final VoidCallback? onScheduleControlsHide;

  final Widget child;

  Future<void> _handleDoubleTap(Offset localPos, double width) async {
    if (!enabled) return;

    final region = width <= 0
        ? 1
        : (localPos.dx < width / 3)
            ? 0
            : (localPos.dx < width * 2 / 3)
                ? 1
                : 2;

    final action = switch (region) {
      0 => doubleTapLeft,
      1 => doubleTapCenter,
      _ => doubleTapRight,
    };

    switch (action) {
      case DoubleTapAction.none:
        return;
      case DoubleTapAction.playPause:
        await onTogglePlayPause();
        return;
      case DoubleTapAction.seekBackward:
        await onSeekRelative(Duration(seconds: -seekBackwardSeconds));
        return;
      case DoubleTapAction.seekForward:
        await onSeekRelative(Duration(seconds: seekForwardSeconds));
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        final sideDragEnabled = gestureBrightnessEnabled || gestureVolumeEnabled;
        final canSeek = enabled && gestureSeekEnabled;
        final canSideDrag = enabled && sideDragEnabled;
        final canLongPress = enabled && gestureLongPressEnabled;

        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onToggleControls,
              onDoubleTapDown: enabled
                  ? (d) => controller.recordDoubleTapDown(d.localPosition)
                  : null,
              onDoubleTap: enabled
                  ? () async {
                      final pos =
                          controller.consumeDoubleTapDownPosition() ??
                              Offset(w / 2, 0);
                      await _handleDoubleTap(pos, w);
                    }
                  : null,
              onHorizontalDragStart: canSeek
                  ? (d) {
                      controller.startSeekDrag(d.localPosition, position);
                      onShowControls?.call(scheduleHide: false);
                      controller.showOverlay(
                        icon: Icons.swap_horiz,
                        text: formatClock(position),
                      );
                    }
                  : null,
              onHorizontalDragUpdate: canSeek
                  ? (d) {
                      final delta = controller.updateSeekDrag(
                        localPosition: d.localPosition,
                        width: w,
                        duration: duration,
                        clamp: clampSeekTarget,
                      );
                      if (delta == null) return;
                      final target = clampSeekTarget(
                        controller.seekPreviewPosition ?? position,
                        duration,
                      );
                      controller.showOverlay(
                        icon: delta.isNegative
                            ? Icons.fast_rewind
                            : Icons.fast_forward,
                        text:
                            '${formatClock(target)}（${delta.isNegative ? '-' : '+'}${delta.inSeconds.abs()}s）',
                      );
                    }
                  : null,
              onHorizontalDragEnd: canSeek
                  ? (_) async {
                      final target = controller.endSeekDrag();
                      if (target != null && enabled) {
                        await onSeekTo(target);
                      }
                      controller.hideOverlay();
                      onScheduleControlsHide?.call();
                    }
                  : null,
              onVerticalDragStart: canSideDrag
                  ? (d) {
                      controller.startSideDrag(
                        localPosition: d.localPosition,
                        width: w,
                        brightnessEnabled: gestureBrightnessEnabled,
                        volumeEnabled: gestureVolumeEnabled,
                      );
                      switch (controller.mode) {
                        case GestureMode.brightness:
                          controller.showOverlay(
                            icon: Icons.brightness_6_outlined,
                            text:
                                '亮度 ${(100 * controller.brightness).round()}%',
                          );
                          break;
                        case GestureMode.volume:
                          controller.showOverlay(
                            icon: Icons.volume_up,
                            text:
                                '音量 ${(100 * controller.volume).round()}%',
                          );
                          break;
                        case GestureMode.none:
                        case GestureMode.seek:
                        case GestureMode.speed:
                          break;
                      }
                    }
                  : null,
              onVerticalDragUpdate: canSideDrag
                  ? (d) async {
                      final value = controller.updateSideDrag(
                        localPosition: d.localPosition,
                        height: h,
                      );
                      if (value == null) return;
                      switch (controller.mode) {
                        case GestureMode.brightness:
                          controller.setBrightness(value);
                          controller.showOverlay(
                            icon: Icons.brightness_6_outlined,
                            text:
                                '亮度 ${(100 * controller.brightness).round()}%',
                          );
                          break;
                        case GestureMode.volume:
                          controller.setVolume(value);
                          final v = controller.volume;
                          await onSetVolume?.call(v);
                          controller.showOverlay(
                            icon: v == 0 ? Icons.volume_off : Icons.volume_up,
                            text: '音量 ${(100 * v).round()}%',
                          );
                          break;
                        case GestureMode.none:
                        case GestureMode.seek:
                        case GestureMode.speed:
                          break;
                      }
                    }
                  : null,
              onVerticalDragEnd: canSideDrag ? (_) => controller.endSideDrag() : null,
              onLongPressStart: canLongPress
                  ? (d) async {
                      final base = getPlaybackRate?.call();
                      if (base == null) return;
                      controller.startLongPressSpeed(
                        localPosition: d.localPosition,
                        baseRate: base,
                      );
                      final targetMultiplier =
                          longPressSpeedMultiplier.clamp(1.0, 4.0).toDouble();
                      final targetRate =
                          (base * targetMultiplier).clamp(0.1, 4.0).toDouble();
                      await onSetPlaybackRate?.call(targetRate);
                      controller.showOverlay(
                        icon: Icons.speed,
                        text:
                            '倍速 ×${(targetRate / base).toStringAsFixed(2)}',
                      );
                    }
                  : null,
              onLongPressMoveUpdate: (canLongPress && longPressSlideEnabled)
                  ? (d) async {
                      final baseRate = getPlaybackRate?.call();
                      if (baseRate == null) return;
                      final multiplier =
                          controller.updateLongPressSpeedMultiplier(
                        localPosition: d.localPosition,
                        height: h,
                        baseMultiplier: longPressSpeedMultiplier,
                      );
                      if (multiplier == null) return;
                      final targetRate =
                          (baseRate * multiplier).clamp(0.1, 4.0).toDouble();
                      await onSetPlaybackRate?.call(targetRate);
                      controller.showOverlay(
                        icon: Icons.speed,
                        text: '倍速 ×${multiplier.toStringAsFixed(2)}',
                      );
                    }
                  : null,
              onLongPressEnd: canLongPress
                  ? (_) async {
                      final base = controller.endLongPressSpeed();
                      if (base != null) {
                        await onSetPlaybackRate?.call(base);
                      }
                    }
                  : null,
              child: child,
            ),
            AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final overlay = controller.overlay;
                if (overlay == null) return const SizedBox.shrink();
                return Center(
                  child: IgnorePointer(
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(overlay.icon, color: Colors.white),
                            const SizedBox(width: 10),
                            Text(
                              overlay.text,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
