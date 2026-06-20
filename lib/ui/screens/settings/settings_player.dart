part of 'settings_screen.dart';

class PlayerSettingsScreen extends ConsumerWidget {
  const PlayerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerCore = normalizePlayerCore(ref.watch(playerCoreProvider));
    final playbackSpeed = ref.watch(defaultPlaybackSpeedProvider);
    final hardwareDecoding = ref.watch(hardwareDecodingProvider);
    final backgroundPlayback = ref.watch(backgroundPlaybackProvider);
    final autoPlayNext = ref.watch(autoPlayNextProvider);
    final autoSkipSegments = ref.watch(autoSkipSegmentsProvider);
    final watchedThreshold = ref.watch(watchedThresholdProvider);
    final preferredSubtitleLanguage =
        ref.watch(preferredSubtitleLanguageProvider);
    final preferredAudioLanguage = ref.watch(preferredAudioLanguageProvider);
    final preferredVersion = ref.watch(preferredVersionProvider);
    final versionRegex = ref.watch(preferredVersionRegexProvider);
    final subtitleRegex = ref.watch(preferredSubtitleRegexProvider);
    final audioRegex = ref.watch(preferredAudioRegexProvider);
    final rememberBrightness = ref.watch(rememberBrightnessProvider);
    final subtitleFont = ref.watch(subtitleFontProvider);
    final subtitleBackground = ref.watch(subtitleBackgroundProvider);
    final mpvDolbyVisionFix = ref.watch(mpvDolbyVisionFixProvider);
    final dolbyAutoGpuNextSw = ref.watch(dolbyAutoGpuNextSwProvider);
    final externalMpvPath = ref.watch(externalMpvPathProvider);
    final gpuNextEnabled = ref.watch(gpuNextEnabledProvider);
    final exoLibass = ref.watch(exoLibassProvider);
    final pgsBlendMode = ref.watch(pgsBlendModeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('播放器设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          ListTile(
            title: const Text('播放器内核'),
            subtitle: Text(switch (playerCore) {
              'mpv' => 'MPV (media_kit)',
              'nativeMpv' => 'MPV 原生',
              _ => 'ExoPlayer/AVPlayer',
            }),
            onTap: () => _showCoreSelector(context, ref),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.touch_app_outlined),
            title: const Text('交互设置'),
            subtitle: const Text('手势交互区、快进步长、双击与长按'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const InteractionSettingsScreen(),
              ),
            ),
          ),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '播放行为',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            title: const Text('默认播放速度'),
            subtitle: Text('${playbackSpeed}x'),
            onTap: () => _showSpeedSelector(context, ref),
          ),
          SwitchListTile(
            title: const Text('后台播放'),
            value: backgroundPlayback,
            onChanged: (value) =>
                ref.read(backgroundPlaybackProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('自动播放下一集'),
            value: autoPlayNext,
            onChanged: (value) =>
                ref.read(autoPlayNextProvider.notifier).state = value,
          ),
          SwitchListTile(
            title: const Text('自动跳过片头/片尾'),
            subtitle: const Text('联网识别剧集片头片尾，进入时显示跳过按钮'),
            value: autoSkipSegments,
            onChanged: (value) =>
                ref.read(autoSkipSegmentsProvider.notifier).state = value,
          ),
          /*
          ListTile(
            title: const Text('宸茬湅鍒ゅ畾闃堝€?),
            subtitle: Text('$watchedThreshold%'),
            onTap: () => _showWatchedThresholdSelector(context, ref),
          ),

          */
          ListTile(
            title: const Text('已看判定阈值'),
            subtitle: Text('$watchedThreshold%'),
            onTap: () => _showWatchedThresholdSelector(context, ref),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '音轨与字幕',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            title: const Text('首选字幕语言'),
            subtitle: Text(preferredSubtitleLanguage),
            onTap: () => _showSubtitleLanguageSelector(context, ref),
          ),
          ListTile(
            title: const Text('首选音频语言'),
            subtitle: Text(preferredAudioLanguage),
            onTap: () => _showAudioLanguageSelector(context, ref),
          ),
          ListTile(
            title: const Text('首选版本'),
            subtitle: Text(preferredVersion),
            onTap: () => _showVersionSelector(context, ref),
          ),
          ListTile(
            title: const Text('版本筛选（正则）'),
            subtitle: Text(
              versionRegex.isEmpty ? '未设置 · 多版本时优先选中匹配的片源' : versionRegex,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: versionRegex.isEmpty
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.clear),
                    onPressed: () => ref
                        .read(preferredVersionRegexProvider.notifier)
                        .state = '',
                  ),
            onTap: () => _showRegexEditor(
              context,
              ref,
              title: '版本筛选（正则）',
              hint: r'例：4K|2160 匹配 4K 片源；HEVC|265 匹配 HEVC 编码',
              provider: preferredVersionRegexProvider,
            ),
          ),
          ListTile(
            title: const Text('字幕筛选（正则）'),
            subtitle: Text(
              subtitleRegex.isEmpty ? '未设置 · 自动选轨时优先选中匹配字幕' : subtitleRegex,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: subtitleRegex.isEmpty
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.clear),
                    onPressed: () => ref
                        .read(preferredSubtitleRegexProvider.notifier)
                        .state = '',
                  ),
            onTap: () => _showRegexEditor(
              context,
              ref,
              title: '字幕筛选（正则）',
              hint: r'例：中文|简|繁|chi|zh 匹配各种中文字幕（不分简繁）',
              provider: preferredSubtitleRegexProvider,
            ),
          ),
          ListTile(
            title: const Text('音频筛选（正则）'),
            subtitle: Text(
              audioRegex.isEmpty ? '未设置 · 自动选轨时优先选中匹配音轨' : audioRegex,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: audioRegex.isEmpty
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.clear),
                    onPressed: () => ref
                        .read(preferredAudioRegexProvider.notifier)
                        .state = '',
                  ),
            onTap: () => _showRegexEditor(
              context,
              ref,
              title: '音频筛选（正则）',
              hint: r'例：jpn|日|flac 匹配日语/FLAC 音轨；7\.1|truehd 匹配高规格',
              provider: preferredAudioRegexProvider,
            ),
          ),
          ListTile(
            title: const Text('字幕字体'),
            subtitle: Text(subtitleFont),
            onTap: () => _showSubtitleFontSelector(context, ref),
          ),
          SwitchListTile(
            title: const Text('字幕黑色背景'),
            subtitle: const Text('为字幕添加半透明黑色背景'),
            value: subtitleBackground,
            onChanged: (value) =>
                ref.read(subtitleBackgroundProvider.notifier).state = value,
          ),
          if (isDesktopPlatform)
            ListTile(
              title: const Text('图形字幕渲染模式 (PGS/SUP)'),
              subtitle: Text(_pgsBlendLabel(pgsBlendMode)),
              trailing: DropdownButton<String>(
                value: pgsBlendMode,
                onChanged: (v) {
                  if (v != null) {
                    ref.read(pgsBlendModeProvider.notifier).state = v;
                  }
                },
                items: const [
                  DropdownMenuItem(value: 'no', child: Text('覆盖层（默认）')),
                  DropdownMenuItem(value: 'video', child: Text('混合到视频')),
                  DropdownMenuItem(value: 'yes', child: Text('混合到输出帧')),
                ],
              ),
            ),

          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '解码与渲染',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('硬件解码'),
            value: hardwareDecoding,
            onChanged: (value) =>
                ref.read(hardwareDecodingProvider.notifier).state = value,
          ),
          if (playerCore == 'mpv' || playerCore == 'nativeMpv')
            SwitchListTile(
              title: const Text('杜比视界自动切换软解'),
              subtitle: const Text(
                  '播放杜比视界时自动启用 gpu-next 渲染 + 软件解码，修正硬解偏色',
              ),
              value: dolbyAutoGpuNextSw,
              onChanged: (value) => ref
                  .read(dolbyAutoGpuNextSwProvider.notifier)
                  .state = value,
            ),
          SwitchListTile(
            title: const Text('记忆亮度'),
            subtitle: const Text('记住上次调整的播放亮度'),
            value: rememberBrightness,
            onChanged: (value) =>
                ref.read(rememberBrightnessProvider.notifier).state = value,
          ),

          // MPV特有设置
          if (playerCore == 'mpv') ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'MPV 高级设置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('自动修正杜比视界颜色'),
              subtitle: const Text('开启后软件修正杜比视界颜色偏差'),
              value: mpvDolbyVisionFix,
              onChanged: (value) =>
                  ref.read(mpvDolbyVisionFixProvider.notifier).state = value,
            ),
          ],

          // 原生MPV特有设置
          if (playerCore == 'nativeMpv') ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '原生MPV 渲染设置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('启用 gpu-next 渲染'),
              subtitle: const Text('使用 libplacebo/gpu-next 渲染（需要 SurfaceView 支持）'),
              value: gpuNextEnabled,
              onChanged: (value) =>
                  ref.read(gpuNextEnabledProvider.notifier).state = value,
            ),
          ],

          // 实验性功能
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '实验性功能',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          if (isDesktopPlatform) ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '外部播放器',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey,
                ),
              ),
            ),
            ListTile(
              title: const Text('外部 MPV 路径'),
              subtitle: Text(
                externalMpvPath.isEmpty ? '点击选择外部 MPV 可执行文件' : externalMpvPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: externalMpvPath.isEmpty
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      tooltip: '清除路径',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        ref.read(externalMpvPathProvider.notifier).state = '';
                      },
                    ),
              onTap: () => _pickExternalMpvPath(context, ref),
            ),
          ],
          if (!isDesktopPlatform && playerCore == 'exoPlayer')
            SwitchListTile(
              title: const Text('EXO 启用 ASS 原生渲染'),
              subtitle: const Text(
                  '关闭时将 ASS 转为 SRT 兼容播放；开启后优先使用 Media3/libass 管线保留 ASS 效果'),
              value: exoLibass,
              onChanged: (value) =>
                  ref.read(exoLibassProvider.notifier).state = value,
            ),
        ],
      ),
    );
  }

  void _showCoreSelector(BuildContext context, WidgetRef ref) {
    // ExoPlayer/AVPlayer 与原生 MPV 都是移动端专属；桌面端只有 media_kit(mpv)。
    final children = <Widget>[
      if (Platform.isAndroid || Platform.isIOS)
        const RadioListTile<String>(
          title: Text('ExoPlayer/AVPlayer'),
          subtitle: Text('轻量稳定，适合大多数场景'),
          value: 'exoPlayer',
        ),
      if (Platform.isAndroid)
        const RadioListTile<String>(
          title: Text('MPV 原生'),
          subtitle: Text('通过 libplayer.so 直接调用 libmpv，支持 HDR/着色器/PGS/SUP'),
          value: 'nativeMpv',
        ),
      if (!Platform.isAndroid)
        const RadioListTile<String>(
          title: Text('MPV (media_kit)'),
          subtitle: Text('libmpv FFI，支持 HDR/着色器/PGS/SUP'),
          value: 'mpv',
        ),
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('播放器内核'),
        content: RadioGroup<String>(
          groupValue: normalizePlayerCore(ref.read(playerCoreProvider)),
          onChanged: (value) {
            if (value != null) {
              ref.read(playerCoreProvider.notifier).state =
                  normalizePlayerCore(value);
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }

  void _showSpeedSelector(BuildContext context, WidgetRef ref) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('默认播放速度'),
        content: RadioGroup<double>(
          groupValue: ref.read(defaultPlaybackSpeedProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(defaultPlaybackSpeedProvider.notifier).state = value;
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

  /*
  void _showWatchedThresholdSelector(BuildContext context, WidgetRef ref) {
    final thresholds = [75, 80, 85, 90, 95];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('宸茬湅鍒ゅ畾闃堝€?),
        content: RadioGroup<int>(
          groupValue: ref.read(watchedThresholdProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(watchedThresholdProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: thresholds
                .map((threshold) => RadioListTile<int>(
                      title: Text('$threshold%'),
                      subtitle:
                          Text('鎾斁杩涘害杈惧埌 $threshold% 鍚庤涓哄凡鐪?),
                      value: threshold,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  */
  void _showWatchedThresholdSelector(BuildContext context, WidgetRef ref) {
    final thresholds = [75, 80, 85, 90, 95];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('已看判定阈值'),
        content: RadioGroup<int>(
          groupValue: ref.read(watchedThresholdProvider),
          onChanged: (value) {
            if (value != null) {
              ref.read(watchedThresholdProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: thresholds
                .map((threshold) => RadioListTile<int>(
                      title: Text('$threshold%'),
                      subtitle: Text('播放进度达到 $threshold% 后视为已看'),
                      value: threshold,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showSubtitleLanguageSelector(BuildContext context, WidgetRef ref) {
    final languages = {
      'chi': '中文',
      'jpn': '日语',
      'eng': '英语',
      'kor': '韩语',
    };
    final current = ref.read(preferredSubtitleLanguageProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('首选字幕语言'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(preferredSubtitleLanguageProvider.notifier).state =
                  value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: languages.entries
                .map((entry) => RadioListTile<String>(
                      title: Text(entry.value),
                      value: entry.key,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showAudioLanguageSelector(BuildContext context, WidgetRef ref) {
    final languages = {
      'jpn': '日语',
      'chi': '中文',
      'eng': '英语',
      'kor': '韩语',
    };
    final current = ref.read(preferredAudioLanguageProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('首选音频语言'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(preferredAudioLanguageProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: languages.entries
                .map((entry) => RadioListTile<String>(
                      title: Text(entry.value),
                      value: entry.key,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showVersionSelector(BuildContext context, WidgetRef ref) {
    final versions = ['原盘', 'HEVC', 'HDR', 'SDR'];
    final current = ref.read(preferredVersionProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('首选版本'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(preferredVersionProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: versions
                .map((version) => RadioListTile<String>(
                      title: Text(version),
                      value: version,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  /// 通用正则编辑器：编辑「版本/字幕/音频」筛选正则，保存前校验合法性。
  void _showRegexEditor(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String hint,
    required StateNotifierProvider<PreferenceNotifier<String>, String> provider,
  }) {
    final controller = TextEditingController(text: ref.read(provider));
    String? errorText;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: null,
                decoration: InputDecoration(
                  hintText: '输入正则表达式（留空表示不启用）',
                  errorText: errorText,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (errorText != null) setState(() => errorText = null);
                },
              ),
              const SizedBox(height: 8),
              Text(
                '$hint\n大小写不敏感，留空清除该筛选。',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) {
                  try {
                    RegExp(value);
                  } catch (_) {
                    setState(() => errorText = '正则表达式格式不正确');
                    return;
                  }
                }
                ref.read(provider.notifier).state = value;
                Navigator.pop(context);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  String _pgsBlendLabel(String mode) {
    switch (mode) {
      case 'video':
        return '混合到视频分辨率 · 覆盖层闪现时可试此项';
      case 'yes':
        return '混合到输出帧 · 最不易闪但可能略糊';
      default:
        return '覆盖层渲染（默认）· 性能最好，部分显卡滑动时会闪';
    }
  }

  void _showSubtitleFontSelector(BuildContext context, WidgetRef ref) {
    final fonts = ['默认', '思源黑体', '微软雅黑', '苹方'];
    final current = ref.read(subtitleFontProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('字幕字体'),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(subtitleFontProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: fonts
                .map((font) => RadioListTile<String>(
                      title: Text(font),
                      value: font,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _pickExternalMpvPath(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '选择外部 MPV 可执行文件',
      allowMultiple: false,
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? const ['exe'] : null,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) {
      return;
    }

    ref.read(externalMpvPathProvider.notifier).state = path;
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已更新外部 MPV 路径')),
    );
  }
}

/// 弹幕设置页
