part of 'player_screen.dart';

/// 标题文字：**仅当文字超出可用宽度时才匀速滚动**，否则静止、左对齐。
///
/// 之前的实现无条件 `repeat()` 一直来回滚，短标题也在动、很晃眼；现在用
/// [TextPainter] 测量实际宽度，未溢出就当普通 [Text] 渲染。
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  final ScrollController _scrollController = ScrollController();
  bool _scrollScheduled = false;

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 标题变了：重置滚动状态，回到开头重新判断是否需要滚。
    if (oldWidget.text != widget.text) {
      _scrollScheduled = false;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 仅在「确实溢出」时调度一次滚动循环（用 post-frame 避免在 build 里产生副作用）。
  void _ensureScrollLoop() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _runLoop();
    });
  }

  Future<void> _runLoop() async {
    if (!mounted || !_scrollController.hasClients) return;
    const double velocity = 40; // 逻辑像素/秒，匀速。
    const pause = Duration(milliseconds: 1000); // 两端停顿。
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 0) return; // 不溢出，不滚。
    final forwardMs = (maxExtent / velocity * 1000).round();
    await _scrollController.animateTo(
      maxExtent,
      duration: Duration(milliseconds: forwardMs),
      curve: Curves.linear,
    );
    if (!mounted || !_scrollController.hasClients) return;
    await Future<void>.delayed(pause);
    if (!mounted || !_scrollController.hasClients) return;
    await _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    await Future<void>.delayed(pause);
    if (mounted) _runLoop();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final overflowing = painter.width > constraints.maxWidth + 0.5;

        if (!overflowing) {
          // 未超长：静止左对齐，绝不滚动。
          _scrollScheduled = false;
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: widget.style,
            ),
          );
        }

        _ensureScrollLoop();
        return ClipRect(
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.only(right: 48),
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                style: widget.style,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 中央拇指区主控件按钮：透明背景的大号白色图标。
class _CenterControlButton extends StatelessWidget {
  const _CenterControlButton({
    required this.icon,
    required this.onTap,
    this.size = 36,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: size),
      tooltip: tooltip,
      onPressed: onTap,
      padding: EdgeInsets.all(size * 0.18),
      constraints: const BoxConstraints(),
      splashRadius: size * 0.85,
    );
  }
}

/// 底栏次级功能项：上图标 + 下文字（TDesign 文本），整块可点。
class _BottomBarAction extends StatelessWidget {
  const _BottomBarAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
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
    final colors = PlayerPanelColors.resolve(context);

    Widget timeRow(String label, Duration value, VoidCallback onPick) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.text, fontSize: 14),
              ),
            ),
            Text(
              _formatTime(value),
              style: TextStyle(
                color: colors.accent,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              icon: Icon(Icons.my_location, color: colors.textSecondary),
              tooltip: '取当前时间',
              onPressed: onPick,
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PanelSectionTitle('时间区间'),
        timeRow('开始时间', _openingStart,
            () => setState(() => _openingStart = widget.currentPosition)),
        timeRow('结束时间', _openingEnd,
            () => setState(() => _openingEnd = widget.currentPosition)),
        const PanelDivider(),
        const PanelSectionTitle('跳过模式'),
        PanelOptionTile(
          label: '显示跳过按钮',
          selected: !_autoSkip,
          onTap: () => setState(() => _autoSkip = false),
        ),
        PanelOptionTile(
          label: '自动跳过',
          selected: _autoSkip,
          onTap: () => setState(() => _autoSkip = true),
        ),
        const SizedBox(height: 12),
        PanelActionTile(
          icon: Icons.check_rounded,
          label: '保存',
          filled: true,
          onTap: () {
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
        ),
        const SizedBox(height: 8),
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
        PanelSwitchRow(
          label: '显示弹幕',
          value: danmakuEnabled,
          onChanged: (value) {
            ref.read(danmakuEnabledProvider.notifier).state = value;
          },
        ),
        const PanelDivider(),
        PanelSliderRow(
          label: '不透明度',
          value: danmakuOpacity,
          min: 0,
          max: 1,
          valueLabel: '${(danmakuOpacity * 100).round()}%',
          onChanged: (value) {
            ref.read(danmakuOpacityProvider.notifier).state = value;
          },
        ),
        PanelSliderRow(
          label: '字号',
          value: danmakuFontSize,
          min: 0,
          max: 1,
          valueLabel: danmakuFontSize.toStringAsFixed(2),
          onChanged: (value) {
            ref.read(danmakuFontSizeProvider.notifier).state = value;
          },
        ),
        PanelSliderRow(
          label: '速度',
          value: danmakuSpeed,
          min: 0,
          max: 1,
          valueLabel: danmakuSpeed.toStringAsFixed(2),
          onChanged: (value) {
            ref.read(danmakuSpeedProvider.notifier).state = value;
          },
        ),
        PanelSliderRow(
          label: '密度',
          value: danmakuDensity,
          min: 0,
          max: 1,
          valueLabel: danmakuDensity.toStringAsFixed(2),
          onChanged: (value) {
            ref.read(danmakuDensityProvider.notifier).state = value;
          },
        ),
        Consumer(builder: (context, ref, _) {
          final delay = ref.watch(danmakuDelayProvider);
          return PanelSliderRow(
            label: '延迟',
            value: delay,
            min: -5.0,
            max: 5.0,
            valueLabel: '${delay.toStringAsFixed(1)}s',
            onChanged: (value) {
              ref.read(danmakuDelayProvider.notifier).state = value;
            },
          );
        }),
        const PanelDivider(),
        Consumer(builder: (context, ref, _) {
          final dedup = ref.watch(danmakuDedupProvider);
          return PanelSwitchRow(
            label: '去重',
            subtitle: '合并内容重复的弹幕',
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
      return const _SettingsSection(children: [_PanelEmpty(label: '无播放信息')]);
    }

    return subtitleAsync.when(
      data: (info) {
        final fallbackMediaSource = info.mediaSources.firstOrNull;
        if (fallbackMediaSource == null) {
          return const _SettingsSection(
            children: [_PanelEmpty(label: '无可用字幕轨道')],
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
              const _PanelEmpty(icon: Icons.subtitles_off, label: '无可用字幕')
            else
              ...subtitles.map((stream) => PanelOptionTile(
                    label: nameMap[stream.index] ??
                        stream.readableLabel(siblings: subtitles),
                    subtitle: stream.codec != null
                        ? '编码: ${stream.codec}${stream.isExternal == true ? ' (外挂)' : ' (内封)'}'
                        : null,
                    selected: selectedSubtitleIndex == stream.index,
                    onTap: () => ref.read(subtitleTrackProvider.notifier).state =
                        stream.index,
                  )),
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
            const SizedBox(height: 8),
            const _Divider(),
            const _SectionTitle('次字幕（第二字幕）'),
            PanelOptionTile(
              label: '关闭',
              selected: selectedSecondaryIndex == null,
              onTap: () => ref
                  .read(secondarySubtitleTrackProvider.notifier)
                  .state = null,
            ),
            if (subtitles.isEmpty)
              const _PanelEmpty(label: '无可用次字幕')
            else
              ...subtitles.map((stream) => PanelOptionTile(
                    label: nameMap[stream.index] ??
                        stream.readableLabel(siblings: subtitles),
                    selected: selectedSecondaryIndex == stream.index,
                    onTap: () => ref
                        .read(secondarySubtitleTrackProvider.notifier)
                        .state = stream.index,
                  )),
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
            PanelSliderRow(
              label: '字幕大小',
              value: subtitleSize.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              valueLabel: '${(subtitleSize.clamp(0.0, 1.0) * 100).round()}%',
              onChanged: (value) =>
                  ref.read(subtitleSizeProvider.notifier).state = value,
            ),
            PanelSliderRow(
              label: '字幕位置',
              value: subtitlePosition.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              valueLabel:
                  '${(subtitlePosition.clamp(0.0, 1.0) * 100).round()}%',
              onChanged: (value) =>
                  ref.read(subtitlePositionProvider.notifier).state = value,
            ),
            const _Divider(),
            PanelSwitchRow(
              label: '字幕黑色背景',
              subtitle: '为字幕添加半透明黑色背景',
              value: subtitleBackground,
              onChanged: (value) =>
                  ref.read(subtitleBackgroundProvider.notifier).state = value,
            ),
          ],
        );
      },
      loading: () => const _SettingsSection(children: [_PanelLoading()]),
      error: (_, __) => const _SettingsSection(
        children: [_PanelEmpty(label: '加载字幕信息失败')],
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
      }
      // 内封字幕拉取不到（服务端不支持单轨导出）→ 自动改为流式翻译（边播边译）。
      if (e.toString().contains('所有字幕地址均不可用')) {
        _PlayerScreenState.startStreamingTranslateFromPanel(engine, source);
      } else if (mounted) {
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
      return const _SettingsSection(children: [_PanelEmpty(label: '无播放信息')]);
    }

    return audioAsync.when(
      data: (info) {
        final fallbackMediaSource = info.mediaSources.firstOrNull;
        if (fallbackMediaSource == null) {
          return const _SettingsSection(
            children: [_PanelEmpty(icon: Icons.audiotrack, label: '无可用音轨')],
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
              const _PanelEmpty(icon: Icons.audiotrack, label: '无可用音轨')
            else
              ...audios.map((stream) => PanelOptionTile(
                    label: stream.readableLabel(),
                    subtitle:
                        stream.codec != null ? '编码: ${stream.codec}' : null,
                    selected: selectedIndex == stream.index,
                    onTap: () {
                      ref.read(audioTrackProvider.notifier).state =
                          stream.index;
                      _switchAudioTrack(audios, stream.index);
                    },
                  )),
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
      loading: () => const _SettingsSection(children: [_PanelLoading()]),
      error: (_, __) => const _SettingsSection(
        children: [_PanelEmpty(label: '加载音频信息失败')],
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
    final colors = PlayerPanelColors.resolve(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          // 头部控制栏
          Row(
            children: [
              // 季选择
              Flexible(
                child: seasonsAsync.when(
                  data: (seasons) {
                    if (seasons.isEmpty) return const SizedBox.shrink();
                    return DropdownButton<String>(
                      value: _selectedSeasonId ?? seasons.first.id,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      iconEnabledColor: colors.textSecondary,
                      items: seasons
                          .map((season) => DropdownMenuItem(
                                value: season.id,
                                child: Text(
                                  season.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: colors.text),
                                ),
                              ))
                          .toList(),
                      onChanged: (value) {
                        setState(() => _selectedSeasonId = value);
                      },
                      dropdownColor: colors.surface,
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ),
              const Spacer(),
              // 视图切换
              IconButton(
                icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view,
                    color: colors.text),
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
      ),
    );
  }

  Widget _buildEpisodesList(ApiClientFactory api) {
    final episodesAsync = ref.watch(episodesProvider((
      seriesId: widget.seriesId,
      seasonId: _selectedSeasonId,
    )));
    final colors = PlayerPanelColors.resolve(context);

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
                        ? colors.selectedFill
                        : colors.controlTrack,
                    borderRadius:
                        BorderRadius.circular(PlayerPanelTokens.itemRadius),
                    border: isCurrent
                        ? Border.all(color: colors.accent, width: 2)
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
                            color: isCurrent ? colors.accent : colors.text,
                          ),
                        ),
                        if (isWatched)
                          Icon(Icons.check, color: colors.accent, size: 16),
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
                  color: colors.controlTrack,
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
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.check_circle,
                          size: 16, color: colors.accent),
                    ),
                  Expanded(
                    child: Text(
                      'E${episode.indexNumber} ${episode.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent ? colors.accent : colors.text,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: Text(
                episode.formattedRuntime ?? '',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
              trailing: isCurrent
                  ? Icon(Icons.play_circle, color: colors.accent)
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

/// 面板内的空状态（图标 + 文案），自动适配深浅色。
class _PanelEmpty extends StatelessWidget {
  final IconData? icon;
  final String label;
  const _PanelEmpty({this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: colors.textSecondary, size: 28),
            const SizedBox(height: 8),
          ],
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// 面板内的加载态。
class _PanelLoading extends StatelessWidget {
  const _PanelLoading();

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: colors.accent),
        ),
      ),
    );
  }
}

/// 分组标题（统一走共享的 TDesign 风格组件，自动适配深浅色）。
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => PanelSectionTitle(text);
}

/// 分隔线
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const PanelDivider();
}

/// 设置按钮（描边风格）
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
  Widget build(BuildContext context) =>
      PanelActionTile(label: label, icon: icon, onTap: onTap);
}

/// 设置项（带下拉箭头，点击打开选择器）
class _SettingsItem extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SettingsItem({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = PlayerPanelColors.resolve(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.text, fontSize: 14),
      ),
      trailing: Icon(Icons.arrow_drop_down, color: colors.textSecondary),
      onTap: onTap,
    );
  }
}

/// 同步控制组件（-/+ 微调 + 自定义输入 + 重置），自动适配深浅色。
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
    final colors = PlayerPanelColors.resolve(context);
    Widget stepButton(IconData icon, VoidCallback onTap) {
      return Material(
        color: colors.controlTrack,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: colors.text, size: 20),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            stepButton(Icons.remove, onDecrease),
            const SizedBox(width: 16),
            Text(
              '${value >= 0 ? "+" : ""}${value.toStringAsFixed(1)}s',
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
            stepButton(Icons.add, onIncrease),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: onCustom,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('自定义输入', style: TextStyle(fontSize: 13)),
            ),
            TextButton(
              onPressed: onReset,
              style: TextButton.styleFrom(
                foregroundColor: colors.textSecondary,
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
