part of 'settings_screen.dart';

/// 播放器「交互设置」子页：手势交互区（左/右半屏竖向滑动调亮度还是音量）、
/// 横向滑动调进度、双击两侧快进快退，以及快进步长 / 长按快进倍速。
///
/// 竖向手势采用「轴锁定」：一次手势在越过阈值后按主导方向锁死，避免调亮度/音量
/// 时手指轻微横移误触发进度跳变（见 VideoPlayerService.onDragUpdate）。
class InteractionSettingsScreen extends ConsumerWidget {
  const InteractionSettingsScreen({super.key});

  static const _verticalLabels = <String, String>{
    kGestureActionBrightness: '调节亮度',
    kGestureActionVolume: '调节音量',
    kGestureActionNone: '关闭',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leftAction = ref.watch(leftVerticalGestureProvider);
    final rightAction = ref.watch(rightVerticalGestureProvider);
    final horizontalSeek = ref.watch(horizontalSeekGestureProvider);
    final doubleTapSeek = ref.watch(doubleTapSeekGestureProvider);
    final skipStep = ref.watch(skipForwardStepProvider);
    final longPressSpeed = ref.watch(longPressSpeedProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('交互设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          _sectionHeader('手势交互区'),
          ListTile(
            leading: const Icon(Icons.swipe_vertical),
            title: const Text('左半屏竖向滑动'),
            subtitle: Text(_verticalLabels[leftAction] ?? '调节亮度'),
            onTap: () => _showVerticalActionSelector(
              context,
              ref,
              title: '左半屏竖向滑动',
              provider: leftVerticalGestureProvider,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.swipe_vertical),
            title: const Text('右半屏竖向滑动'),
            subtitle: Text(_verticalLabels[rightAction] ?? '调节音量'),
            onTap: () => _showVerticalActionSelector(
              context,
              ref,
              title: '右半屏竖向滑动',
              provider: rightVerticalGestureProvider,
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.swipe),
            title: const Text('横向滑动调节进度'),
            subtitle: const Text('左右滑动快进/快退；关闭后横滑不再改变进度'),
            value: horizontalSeek,
            onChanged: (v) =>
                ref.read(horizontalSeekGestureProvider.notifier).state = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.touch_app),
            title: const Text('双击两侧快进/快退'),
            subtitle: const Text('双击屏幕左/右两侧快退/快进；中间区域始终播放/暂停'),
            value: doubleTapSeek,
            onChanged: (v) =>
                ref.read(doubleTapSeekGestureProvider.notifier).state = v,
          ),
          const Divider(),
          _sectionHeader('快进与倍速'),
          ListTile(
            leading: const Icon(Icons.fast_forward),
            title: const Text('快进步长'),
            subtitle: Text('$skipStep秒'),
            onTap: () => _showSkipStepSelector(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('长按快进倍速'),
            subtitle: Text('${longPressSpeed}x'),
            onTap: () => _showLongPressSpeedSelector(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey,
          ),
        ),
      );

  void _showVerticalActionSelector(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required StateNotifierProvider<PreferenceNotifier<String>, String> provider,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: RadioGroup<String>(
          groupValue: ref.read(provider),
          onChanged: (value) {
            if (value != null) {
              ref.read(provider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _verticalLabels.entries
                .map((e) => RadioListTile<String>(
                      title: Text(e.value),
                      value: e.key,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showSkipStepSelector(BuildContext context, WidgetRef ref) {
    final steps = [5, 10, 15, 30, 60];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('快进步长'),
        content: RadioGroup<int>(
          groupValue: ref.read(skipForwardStepProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(skipForwardStepProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: steps
                .map((step) => RadioListTile<int>(
                      title: Text('$step秒'),
                      value: step,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showLongPressSpeedSelector(BuildContext context, WidgetRef ref) {
    final speeds = [1.5, 2.0, 2.5, 3.0];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('长按快进倍速'),
        content: RadioGroup<double>(
          groupValue: ref.read(longPressSpeedProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(longPressSpeedProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: speeds
                .map((speed) => RadioListTile<double>(
                      title: Text('${speed}x'),
                      value: speed,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }
}
