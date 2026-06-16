part of 'player_screen.dart';

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 8),
      vsync: this,
    );
    _animation = Tween<double>(begin: 1.0, end: -1.0).animate(_controller);
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          return FractionalTranslation(
            translation: Offset(_animation.value, 0),
            child: Text(
              widget.text,
              maxLines: 1,
              overflow: TextOverflow.visible,
              style: widget.style,
            ),
          );
        },
      ),
    );
  }
}

/// 跳过片头/片尾弹窗
class _SkipDialog extends ConsumerStatefulWidget {
  final Duration currentPosition;

  const _SkipDialog({required this.currentPosition});

  @override
  ConsumerState<_SkipDialog> createState() => _SkipDialogState();
}

class _SkipDialogState extends ConsumerState<_SkipDialog> {
  late Duration _openingStart;
  late Duration _openingEnd;
  late bool _autoSkip;

  @override
  void initState() {
    super.initState();
    final openingStartSec = ref.read(skipOpeningStartProvider);
    final openingEndSec = ref.read(skipOpeningEndProvider);
    _openingStart = Duration(seconds: openingStartSec);
    _openingEnd = Duration(seconds: openingEndSec);
    _autoSkip = ref.read(skipAutoModeProvider);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('跳过片头'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('开始时间'),
              const Spacer(),
              Text(_formatTime(_openingStart)),
              IconButton(
                icon: const Icon(Icons.location_on),
                tooltip: '取当前时间',
                onPressed: () {
                  setState(() => _openingStart = widget.currentPosition);
                },
              ),
            ],
          ),
          Row(
            children: [
              const Text('结束时间'),
              const Spacer(),
              Text(_formatTime(_openingEnd)),
              IconButton(
                icon: const Icon(Icons.location_on),
                tooltip: '取当前时间',
                onPressed: () {
                  setState(() => _openingEnd = widget.currentPosition);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('跳过模式'),
              const Spacer(),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('显示按钮')),
                  ButtonSegment(value: true, label: Text('自动跳过')),
                ],
                selected: {_autoSkip},
                onSelectionChanged: (value) {
                  setState(() => _autoSkip = value.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '当前: ${_autoSkip ? "自动跳过" : "显示跳过按钮"}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
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
            ref.read(skipOpeningStartProvider.notifier).state =
                _openingStart.inSeconds;
            ref.read(skipOpeningEndProvider.notifier).state =
                _openingEnd.inSeconds;
            ref.read(skipAutoModeProvider.notifier).state = _autoSkip;
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('跳过设置已保存')),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  String _formatTime(Duration duration) {
    final m = duration.inMinutes.toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// 弹幕设置内容
class _DanmakuSettingsContent extends ConsumerWidget {
  const _DanmakuSettingsContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final danmakuEnabled = ref.watch(danmakuEnabledProvider);
    final danmakuOpacity = ref.watch(danmakuOpacityProvider);
    final danmakuFontSize = ref.watch(danmakuFontSizeProvider);
    final danmakuSpeed = ref.watch(danmakuSpeedProvider);
    final danmakuDensity = ref.watch(danmakuDensityProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          title: const Text('显示弹幕', style: TextStyle(color: Colors.white)),
          value: danmakuEnabled,
          onChanged: (value) {
            ref.read(danmakuEnabledProvider.notifier).state = value;
          },
        ),
        const Divider(color: Colors.white24),
        const Text('不透明度', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuOpacity,
          onChanged: (value) {
            ref.read(danmakuOpacityProvider.notifier).state = value;
          },
        ),
        const Text('字号', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuFontSize,
          onChanged: (value) {
            ref.read(danmakuFontSizeProvider.notifier).state = value;
          },
        ),
        const Text('速度', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuSpeed,
          onChanged: (value) {
            ref.read(danmakuSpeedProvider.notifier).state = value;
          },
        ),
        const Text('密度', style: TextStyle(color: Colors.white70)),
        Slider(
          value: danmakuDensity,
          onChanged: (value) {
            ref.read(danmakuDensityProvider.notifier).state = value;
          },
        ),
        const Text('延迟', style: TextStyle(color: Colors.white70)),
        Consumer(builder: (context, ref, _) {
          final delay = ref.watch(danmakuDelayProvider);
          return Slider(
            value: delay,
            min: -5.0,
            max: 5.0,
            label: '${delay.toStringAsFixed(1)}s',
            onChanged: (value) {
              ref.read(danmakuDelayProvider.notifier).state = value;
            },
          );
        }),
        const Text('去重', style: TextStyle(color: Colors.white70)),
        Consumer(builder: (context, ref, _) {
          final dedup = ref.watch(danmakuDedupProvider);
          return Switch(
            value: dedup,
            onChanged: (v) => ref.read(danmakuDedupProvider.notifier).state = v,
          );
        }),
      ],
    );
  }
}

/// 字幕设置弹窗
class _SubtitleSettingsContent extends ConsumerStatefulWidget {
  const _SubtitleSettingsContent();

  @override
  ConsumerState<_SubtitleSettingsContent> createState() =>
      _SubtitleSettingsContentState();
}

class _SubtitleSettingsContentState
    extends ConsumerState<_SubtitleSettingsContent> {
  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final subtitleAsync =
        item != null ? ref.watch(playbackInfoProvider(item.id)) : null;
    final subtitleOffset = ref.watch(subtitleDelayProvider);
    final subtitleSize = ref.watch(subtitleSizeProvider);
    final subtitlePosition = ref.watch(subtitlePositionProvider);
    final subtitleFont = ref.watch(subtitleFontProvider);
    final subtitleBackground = ref.watch(subtitleBackgroundProvider);
    final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
    final selectedSecondaryIndex = ref.watch(secondarySubtitleTrackProvider);
    final selectedMediaSourceId = ref.watch(selectedMediaSourceProvider);

    if (subtitleAsync == null) {
      return const _SettingsSection(
        children: [
          Center(child: Text('无播放信息', style: TextStyle(color: Colors.white70)))
        ],
      );
    }

    return subtitleAsync.when(
      data: (info) {
        final fallbackMediaSource = info.mediaSources.firstOrNull;
        if (fallbackMediaSource == null) {
          return const _SettingsSection(
            children: [
              Center(
                  child:
                      Text('无可用字幕轨道', style: TextStyle(color: Colors.white70))),
            ],
          );
        }
        final mediaSource = selectedMediaSourceId != null
            ? info.mediaSources.firstWhere(
                (source) => source.id == selectedMediaSourceId,
                orElse: () => fallbackMediaSource,
              )
            : fallbackMediaSource;
        final subtitles =
            mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
        final playerService = _PlayerScreenState.activePlayerService;
        final nameMap = _buildSubtitleNameMap(subtitles, playerService);

        return _SettingsSection(
          children: [
            const _SectionTitle('字幕轨道'),
            if (subtitles.isEmpty)
              const ListTile(
                leading: Icon(Icons.subtitles_off, color: Colors.white54),
                title: Text('无可用字幕', style: TextStyle(color: Colors.white70)),
              )
            else
              RadioGroup<int>(
                groupValue: selectedSubtitleIndex,
                onChanged: (value) {
                  ref.read(subtitleTrackProvider.notifier).state = value;
                },
                child: Column(
                  children: subtitles
                      .map((stream) => RadioListTile<int>(
                            title: Text(
                              nameMap[stream.index] ??
                                  stream.readableLabel(siblings: subtitles),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14),
                            ),
                            subtitle: stream.codec != null
                                ? Text(
                                    '编码: ${stream.codec}${stream.isExternal == true ? ' (外挂)' : ' (内封)'}',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 12))
                                : null,
                            value: stream.index,
                          ))
                      .toList(),
                ),
              ),
            const SizedBox(height: 8),
            _SettingsButton(
              icon: Icons.upload_file,
              label: '导入外部字幕',
              onTap: () => _pickExternalSubtitle(),
            ),
            const SizedBox(height: 8),
            _SettingsButton(
              icon: Icons.translate,
              label: '翻译字幕（生成中文）',
              onTap: () => _translateSubtitle(
                  item, mediaSource, subtitles, selectedSubtitleIndex),
            ),
            const SizedBox(height: 16),
            const _Divider(),
            const _SectionTitle('次字幕（第二字幕）'),
            RadioGroup<int?>(
              groupValue: selectedSecondaryIndex,
              onChanged: (value) {
                ref.read(secondarySubtitleTrackProvider.notifier).state = value;
              },
              child: Column(
                children: [
                  const RadioListTile<int?>(
                    title: Text('关闭',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                    value: null,
                  ),
                  if (subtitles.isEmpty)
                    const ListTile(
                      title: Text('无可用次字幕',
                          style: TextStyle(color: Colors.white70)),
                    )
                  else
                    ...subtitles.map((stream) => RadioListTile<int?>(
                          title: Text(
                            nameMap[stream.index] ??
                                stream.readableLabel(siblings: subtitles),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                          ),
                          value: stream.index,
                        )),
                ],
              ),
            ),
            const _Divider(),
            const _SectionTitle('字体'),
            _SettingsItem(
              label: subtitleFont,
              onTap: () => _showFontSelector(context),
            ),
            const _Divider(),
            const _SectionTitle('字幕同步'),
            _SyncControl(
              value: subtitleOffset,
              onDecrease: () => ref.read(subtitleDelayProvider.notifier).state =
                  subtitleOffset - 0.5,
              onIncrease: () => ref.read(subtitleDelayProvider.notifier).state =
                  subtitleOffset + 0.5,
              onCustom: () => _showCustomOffsetDialog(context),
              onReset: () =>
                  ref.read(subtitleDelayProvider.notifier).state = 0.0,
            ),
            const _Divider(),
            const _SectionTitle('字幕大小'),
            Slider(
              value: subtitleSize.clamp(0.0, 1.0),
              onChanged: (value) =>
                  ref.read(subtitleSizeProvider.notifier).state = value,
              activeColor: const Color(0xFF5B8DEF),
              inactiveColor: Colors.white24,
            ),
            const _SectionTitle('字幕位置'),
            Slider(
              value: subtitlePosition.clamp(0.0, 1.0),
              onChanged: (value) =>
                  ref.read(subtitlePositionProvider.notifier).state = value,
              activeColor: const Color(0xFF5B8DEF),
              inactiveColor: Colors.white24,
            ),
            const _Divider(),
            SwitchListTile(
              title: const Text('字幕黑色背景',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('为字幕添加半透明黑色背景',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: subtitleBackground,
              onChanged: (value) =>
                  ref.read(subtitleBackgroundProvider.notifier).state = value,
            ),
          ],
        );
      },
      loading: () => const _SettingsSection(
        children: [
          Center(child: CircularProgressIndicator(color: Colors.white54))
        ],
      ),
      error: (_, __) => const _SettingsSection(
        children: [
          Center(
              child: Text('加载字幕信息失败', style: TextStyle(color: Colors.white70)))
        ],
      ),
    );
  }

  Future<void> _pickExternalSubtitle() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'ass', 'ssa', 'vtt', 'sup', 'pgs'],
      );
      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        final logger = AppLogger();
        logger.i('Player', '导入外部字幕: $filePath');

        final playerService = _PlayerScreenState.activePlayerService;
        if (playerService != null) {
          var pathToLoad = filePath;
          final lowerExt = filePath.split('.').last.toLowerCase();
          if (playerService.coreType == PlayerCoreType.exoPlayer &&
              (lowerExt == 'ass' || lowerExt == 'ssa') &&
              !ref.read(exoLibassProvider)) {
            pathToLoad = await SubtitleProcessor.convertAssToSrt(filePath);
            logger.i('Player', '导入字幕: EXO内核已将 ASS/SSA 转为 SRT: $pathToLoad');
          }
          await playerService.loadLibassSubtitle(pathToLoad);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已导入并加载字幕: ${result.files.single.name}')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('字幕文件已选择，但播放器未就绪')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  /// 翻译指定/选中的字幕轨为中文，并加载到播放器。
  Future<void> _translateSubtitle(
    MediaItem? item,
    MediaSource mediaSource,
    List<MediaStream> subtitles,
    int? selectedIndex,
  ) async {
    final engine = ref.read(activeTranslationEngineProvider);
    if (engine == null) {
      _toast('请先在「设置 → 字幕翻译」中配置并填写翻译引擎');
      return;
    }
    if (item == null) {
      _toast('无播放信息');
      return;
    }
    // 选择要翻译的源字幕轨。
    MediaStream? source;
    if (selectedIndex != null) {
      source = subtitles
          .where((s) => s.index == selectedIndex)
          .cast<MediaStream?>()
          .firstOrNull;
    }
    source ??= subtitles.length == 1 ? subtitles.first : null;
    source ??= await _pickSubtitleStreamToTranslate(subtitles);
    if (source == null) {
      _toast(subtitles.isEmpty
          ? '该片源无字幕轨可翻译；如需无字幕生成可用 Whisper（PC）'
          : '已取消');
      return;
    }

    final playerService = _PlayerScreenState.activePlayerService;
    if (playerService == null) {
      _toast('播放器未就绪');
      return;
    }

    final api = ref.read(apiClientProvider);
    final service = ref.read(subtitleTranslationServiceProvider);
    final target = ref.read(translationTargetLangProvider);
    final layout = ref.read(bilingualLayoutProvider);
    final authToken = ref.read(currentServerProvider)?.authToken;
    final progress = ValueNotifier<String>('准备中…');

    if (!mounted) {
      progress.dispose();
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('翻译字幕'),
        content: Row(
          children: [
            const SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final path = await TranslationActions.translateEmbyStream(
        api: api,
        service: service,
        engine: engine,
        itemId: item.id,
        mediaSourceId: mediaSource.id,
        stream: source,
        targetLang: target,
        layout: layout,
        authToken: authToken,
        onProgress: (done, total, stage) {
          progress.value = total > 1 ? '$stage $done/$total' : stage;
        },
      );
      await playerService.loadLibassSubtitle(path);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _toast('翻译完成并已加载中文字幕');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _toast('翻译失败: $e');
      }
    } finally {
      progress.dispose();
    }
  }

  Future<MediaStream?> _pickSubtitleStreamToTranslate(
      List<MediaStream> subtitles) async {
    if (subtitles.isEmpty) return null;
    return showModalBottomSheet<MediaStream>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择要翻译的字幕轨',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            for (final s in subtitles)
              ListTile(
                leading: const Icon(Icons.subtitles),
                title: Text(s.readableLabel(siblings: subtitles)),
                subtitle: s.codec != null ? Text('编码: ${s.codec}') : null,
                onTap: () => Navigator.pop(ctx, s),
              ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showFontSelector(BuildContext context) {
    final fonts = [
      '默认',
      'Arial',
      'Helvetica',
      'Times New Roman',
      'Courier New'
    ];
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: fonts
              .map((font) => ListTile(
                    title: Text(font),
                    trailing: ref.read(subtitleFontProvider) == font
                        ? const Icon(Icons.check, color: Color(0xFF5B8DEF))
                        : null,
                    onTap: () {
                      ref.read(subtitleFontProvider.notifier).state = font;
                      Navigator.pop(ctx);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  void _showCustomOffsetDialog(BuildContext context) {
    final controller = TextEditingController(
        text: ref.read(subtitleDelayProvider).toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义字幕同步'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          decoration: const InputDecoration(
            labelText: '偏移量（秒）',
            hintText: '正数 = 延后，负数 = 提前',
            suffixText: 's',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                ref.read(subtitleDelayProvider.notifier).state = value;
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Map<int, String> _buildSubtitleNameMap(
    List<MediaStream> embySubtitles,
    VideoPlayerService? playerService,
  ) {
    final result = <int, String>{};
    if (playerService == null) return result;

    final playerTracks = playerService.tracksInfo
        .where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' &&
            t['id'] != 'no')
        .toList();

    if (playerTracks.isEmpty) return result;

    for (final stream in embySubtitles) {
      if (stream.displayTitle != null && stream.displayTitle!.isNotEmpty) {
        continue;
      }
      if (stream.title != null && stream.title!.isNotEmpty) {
        result[stream.index] = stream.title!;
        continue;
      }

      String? playerTitle;
      if (playerService.coreType == PlayerCoreType.exoPlayer) {
        for (final t in playerTracks) {
          if (t['groupIndex'] == stream.index) {
            playerTitle = t['label']?.toString() ?? t['title']?.toString();
            break;
          }
        }
      }

      if (playerTitle == null) {
        final lang = stream.language ?? '';
        final sameLang = playerTracks
            .where((t) =>
                t['language'] == lang ||
                (lang == 'chi' &&
                    (t['language'] == 'chi' || t['language'] == 'zh')))
            .toList();
        if (sameLang.isNotEmpty) {
          final sameCodecEmby = embySubtitles
              .where((s) =>
                  s.language == lang ||
                  (lang == 'chi' &&
                      (s.language == 'chi' || s.language == 'zh')))
              .toList();
          final posInEmby =
              sameCodecEmby.indexWhere((s) => s.index == stream.index);
          if (posInEmby >= 0 && posInEmby < sameLang.length) {
            playerTitle = sameLang[posInEmby]['title']?.toString();
          }
          if (playerTitle == null || playerTitle.isEmpty) {
            for (final t in sameLang) {
              final tTitle = t['title']?.toString() ?? '';
              if (tTitle.isNotEmpty) {
                final codec = stream.codec?.toLowerCase() ?? '';
                final isAss = codec == 'ass' || codec == 'ssa';
                final isBitmap = codec == 'pgssub' ||
                    codec == 'sup' ||
                    codec == 'pgs' ||
                    codec.contains('hdmv') ||
                    codec.contains('pgs');
                final tIsAss = (t['isAss'] == true) ||
                    (t['codec']?.toString().toLowerCase().contains('ass') ==
                        true);
                final tIsBitmap =
                    t['isBitmap'] == true || t['type'] == 'bitmap';
                if (isAss && tIsAss && !tIsBitmap) {
                  playerTitle = tTitle;
                  break;
                }
                if (isBitmap && tIsBitmap) {
                  playerTitle = tTitle;
                  break;
                }
              }
            }
          }
        }
      }

      if (playerTitle != null && playerTitle.isNotEmpty) {
        result[stream.index] = playerTitle;
      }
    }
    return result;
  }
}

/// 音频设置内容
class _AudioSettingsContent extends ConsumerStatefulWidget {
  const _AudioSettingsContent();

  @override
  ConsumerState<_AudioSettingsContent> createState() =>
      _AudioSettingsContentState();
}

class _AudioSettingsContentState extends ConsumerState<_AudioSettingsContent> {
  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final audioAsync =
        item != null ? ref.watch(playbackInfoProvider(item.id)) : null;
    final audioOffset = ref.watch(audioDelayProvider);
    final selectedIndex = ref.watch(audioTrackProvider);
    final selectedMediaSourceId = ref.watch(selectedMediaSourceProvider);

    if (audioAsync == null) {
      return const _SettingsSection(
        children: [
          Center(child: Text('无播放信息', style: TextStyle(color: Colors.white70)))
        ],
      );
    }

    return audioAsync.when(
      data: (info) {
        final fallbackMediaSource = info.mediaSources.firstOrNull;
        if (fallbackMediaSource == null) {
          return const _SettingsSection(
            children: [
              Center(
                  child:
                      Text('无可用音轨', style: TextStyle(color: Colors.white70))),
            ],
          );
        }
        final mediaSource = selectedMediaSourceId != null
            ? info.mediaSources.firstWhere(
                (source) => source.id == selectedMediaSourceId,
                orElse: () => fallbackMediaSource,
              )
            : fallbackMediaSource;
        final audios =
            mediaSource.mediaStreams.where((s) => s.isAudio).toList();

        return _SettingsSection(
          children: [
            const _SectionTitle('音频轨道'),
            if (audios.isEmpty)
              const ListTile(
                leading: Icon(Icons.audiotrack, color: Colors.white54),
                title: Text('无可用音轨', style: TextStyle(color: Colors.white70)),
              )
            else
              RadioGroup<int>(
                groupValue: selectedIndex,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(audioTrackProvider.notifier).state = value;
                    _switchAudioTrack(audios, value);
                  }
                },
                child: Column(
                  children: audios
                      .map((stream) => RadioListTile<int>(
                            title: Text(
                              stream.readableLabel(),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14),
                            ),
                            subtitle: stream.codec != null
                                ? Text('编码: ${stream.codec}',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 12))
                                : null,
                            value: stream.index,
                          ))
                      .toList(),
                ),
              ),
            const _Divider(),
            const _SectionTitle('音频同步'),
            _SyncControl(
              value: audioOffset,
              onDecrease: () => ref.read(audioDelayProvider.notifier).state =
                  audioOffset - 0.5,
              onIncrease: () => ref.read(audioDelayProvider.notifier).state =
                  audioOffset + 0.5,
              onCustom: () => _showCustomOffsetDialog(context),
              onReset: () => ref.read(audioDelayProvider.notifier).state = 0.0,
            ),
          ],
        );
      },
      loading: () => const _SettingsSection(
        children: [
          Center(child: CircularProgressIndicator(color: Colors.white54))
        ],
      ),
      error: (_, __) => const _SettingsSection(
        children: [
          Center(
              child: Text('加载音频信息失败', style: TextStyle(color: Colors.white70)))
        ],
      ),
    );
  }

  Future<void> _switchAudioTrack(
      List<MediaStream> audios, int selectedStreamIndex) async {
    final playerService = _PlayerScreenState.activePlayerService;
    if (playerService == null) return;

    final tracks = playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    final audioPosition =
        audios.indexWhere((stream) => stream.index == selectedStreamIndex);
    if (audioPosition < 0 || audioPosition >= audioTracks.length) {
      return;
    }
    final trackId = audioTracks[audioPosition]['id']?.toString() ?? '';
    if (trackId.isNotEmpty) {
      await playerService.selectAudioTrack(trackId);
    }
  }

  void _showCustomOffsetDialog(BuildContext context) {
    final controller = TextEditingController(
        text: ref.read(audioDelayProvider).toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义音频同步'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          decoration: const InputDecoration(
            labelText: '偏移量（秒）',
            hintText: '正数 = 延后，负数 = 提前',
            suffixText: 's',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                ref.read(audioDelayProvider.notifier).state = value;
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 选集内容
class _EpisodeSelectorContent extends ConsumerStatefulWidget {
  final String seriesId;
  final String currentEpisodeId;
  final String? currentMediaSourceId;

  const _EpisodeSelectorContent({
    required this.seriesId,
    required this.currentEpisodeId,
    this.currentMediaSourceId,
  });

  @override
  ConsumerState<_EpisodeSelectorContent> createState() =>
      _EpisodeSelectorContentState();
}

class _EpisodeSelectorContentState
    extends ConsumerState<_EpisodeSelectorContent> {
  String? _selectedSeasonId;
  bool _isGridView = false;

  void _playEpisode(Episode episode) {
    if (episode.id == widget.currentEpisodeId) {
      Navigator.pop(context);
      return;
    }

    final mediaSourceQuery = widget.currentMediaSourceId != null &&
            widget.currentMediaSourceId!.isNotEmpty
        ? '?mediaSourceId=${widget.currentMediaSourceId!}'
        : '';
    Navigator.pop(context);
    context.replace('/player/${episode.id}$mediaSourceQuery');
  }

  @override
  Widget build(BuildContext context) {
    final seasonsAsync = ref.watch(seasonsProvider(widget.seriesId));
    final api = ref.read(apiClientProvider);

    return Column(
      children: [
        // 头部控制栏
        Row(
          children: [
            // 季选择
            seasonsAsync.when(
              data: (seasons) {
                if (seasons.isEmpty) return const SizedBox.shrink();
                return DropdownButton<String>(
                  value: _selectedSeasonId ?? seasons.first.id,
                  items: seasons
                      .map((season) => DropdownMenuItem(
                            value: season.id,
                            child: Text(season.name,
                                style: const TextStyle(color: Colors.white)),
                          ))
                      .toList(),
                  onChanged: (value) {
                    setState(() => _selectedSeasonId = value);
                  },
                  dropdownColor: Colors.black87,
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            const Spacer(),
            // 视图切换
            IconButton(
              icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view,
                  color: Colors.white),
              onPressed: () => setState(() => _isGridView = !_isGridView),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 集列表
        Expanded(
          child: _buildEpisodesList(api),
        ),
      ],
    );
  }

  Widget _buildEpisodesList(ApiClientFactory api) {
    final episodesAsync = ref.watch(episodesProvider((
      seriesId: widget.seriesId,
      seasonId: _selectedSeasonId,
    )));

    return episodesAsync.when(
      data: (episodes) {
        if (_isGridView) {
          return GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              childAspectRatio: 1,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, index) {
              final episode = episodes[index];
              final isCurrent = episode.id == widget.currentEpisodeId;
              final isWatched = episode.userData?.played ?? false;

              return GestureDetector(
                onTap: () => _playEpisode(episode),
                child: Container(
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? const Color(0xFF5B8DEF).withValues(alpha: 0.2)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: isCurrent
                        ? Border.all(color: const Color(0xFF5B8DEF), width: 2)
                        : null,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${episode.indexNumber}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            color: isCurrent ? const Color(0xFF5B8DEF) : null,
                          ),
                        ),
                        if (isWatched)
                          const Icon(Icons.check,
                              color: Color(0xFF5B8DEF), size: 16),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        }

        return ListView.builder(
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final episode = episodes[index];
            final isCurrent = episode.id == widget.currentEpisodeId;
            final isWatched = episode.userData?.played ?? false;
            final imageUrls = resolveEpisodeLandscapeImageUrls(
              api,
              episode,
              maxWidth: 320,
            );

            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 80,
                  height: 48,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: imageUrls.isNotEmpty
                      ? MediaImage(
                          imageUrl: imageUrls.first,
                          imageUrls: imageUrls.length > 1
                              ? imageUrls.sublist(1)
                              : null,
                          width: 80,
                          height: 48,
                          fit: BoxFit.cover,
                        )
                      : const Center(child: Icon(Icons.play_arrow, size: 20)),
                ),
              ),
              title: Row(
                children: [
                  if (isWatched)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.check_circle,
                          size: 16, color: Color(0xFF5B8DEF)),
                    ),
                  Expanded(
                    child: Text(
                      'E${episode.indexNumber} ${episode.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              subtitle: Text(
                episode.formattedRuntime ?? '',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: isCurrent
                  ? const Icon(Icons.play_circle, color: Color(0xFF5B8DEF))
                  : null,
              selected: isCurrent,
              onTap: () => _playEpisode(episode),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Center(child: Text('加载失败')),
    );
  }
}

/// 设置区块容器
class _SettingsSection extends StatelessWidget {
  final List<Widget> children;
  const _SettingsSection({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// 分组标题
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 分隔线
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      color: Colors.white.withValues(alpha: 0.1),
      height: 1,
      indent: 16,
      endIndent: 16,
    );
  }
}

/// 设置按钮
class _SettingsButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SettingsButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: Colors.white70, size: 20),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置项（带箭头）
class _SettingsItem extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SettingsItem({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      trailing: const Icon(Icons.arrow_drop_down, color: Colors.white54),
      onTap: onTap,
    );
  }
}

/// 同步控制组件
class _SyncControl extends StatelessWidget {
  final double value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onCustom;
  final VoidCallback onReset;

  const _SyncControl({
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
    required this.onCustom,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onDecrease,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  child:
                      const Icon(Icons.remove, color: Colors.white70, size: 20),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              '${value >= 0 ? "+" : ""}${value.toStringAsFixed(1)}s',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onIncrease,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.add, color: Colors.white70, size: 20),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: onCustom,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF5B8DEF),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('自定义输入', style: TextStyle(fontSize: 13)),
            ),
            TextButton(
              onPressed: onReset,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white54,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('重置', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }
}
