import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/services/player_subtitle_loader.dart';
import '../../../core/services/translation/streaming_subtitle_translator.dart';
import '../../../core/services/translation/translation_actions.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/utils/playback_url_resolver.dart';
import '../../theme/tv_design_tokens.dart';
import '../../widgets/tv_control_overlay.dart';
import '../../widgets/tv_panel.dart';

/// TV 播放页 —— 接入 VideoPlayerService 真实播放 + 遥控器控制 + 看完自动同步。
class TvPlayerScreen extends ConsumerStatefulWidget {
  final String? mediaId;
  final String? episodeId;

  const TvPlayerScreen({super.key, this.mediaId, this.episodeId});

  @override
  ConsumerState<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends ConsumerState<TvPlayerScreen> {
  final VideoPlayerService _service = VideoPlayerService();
  bool _ready = false;
  String? _error;
  MediaItem? _item;
  bool _showControls = true;
  Timer? _hideTimer;
  bool _didScrobble = false;
  bool _handledCompletion = false;
  MediaSource? _mediaSource;
  StreamingSubtitleTranslator? _streamTranslator;

  String get _itemId => widget.episodeId ?? widget.mediaId ?? '';

  @override
  void initState() {
    super.initState();
    _service.addListener(_onTick);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _streamTranslator?.stop();
    _service.removeListener(_onTick);
    _service.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    if (_ready && _service.isCompleted && !_handledCompletion) {
      _handledCompletion = true;
      _onPlaybackComplete();
    }
    setState(() {});
  }

  /// 播放自然结束：开启「自动播放下一集」且为剧集时跳到下一集，否则退出。
  Future<void> _onPlaybackComplete() async {
    final item = _item;
    if (item != null &&
        item.type == 'Episode' &&
        item.seriesId != null &&
        ref.read(autoPlayNextProvider)) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
              item.seriesId!,
              seasonId: item.seasonId,
            );
        final idx = episodes.indexWhere((e) => e.id == item.id);
        if (idx >= 0 && idx < episodes.length - 1 && mounted) {
          context.replace('/tv/player?mediaId=${episodes[idx + 1].id}');
          return;
        }
      } catch (_) {}
    }
    if (mounted) context.pop();
  }

  Future<void> _init() async {
    if (_itemId.isEmpty) {
      setState(() => _error = '无效的媒体 ID');
      return;
    }
    try {
      final api = ref.read(apiClientProvider);
      final item = await api.media.getItemDetails(_itemId);
      final playbackInfo = await api.playback.getPlaybackInfo(_itemId);
      final selection = buildPlaybackSelection(
        playbackInfo: playbackInfo,
        itemId: _itemId,
        preferredMediaSourceId: ref.read(selectedMediaSourceProvider),
        playSessionId: '$_itemId-${DateTime.now().microsecondsSinceEpoch}',
      );
      final req = selection.primaryRequest;
      final videoUrl = api.playback.getVideoStreamUrl(
        req.itemId,
        mediaSourceId: req.mediaSourceId,
        container: req.container,
        playSessionId: req.playSessionId,
        staticStream: req.staticStream,
        allowDirectPlay: req.allowDirectPlay,
        allowDirectStream: req.allowDirectStream,
        allowTranscoding: req.allowTranscoding,
        enableAutoStreamCopy: req.enableAutoStreamCopy,
        enableAutoStreamCopyAudio: req.enableAutoStreamCopyAudio,
        enableAutoStreamCopyVideo: req.enableAutoStreamCopyVideo,
      );
      final coreType =
          switch (normalizePlayerCore(ref.read(playerCoreProvider))) {
        'mpv' => PlayerCoreType.mpv,
        'nativeMpv' => PlayerCoreType.nativeMpv,
        _ => PlayerCoreType.exoPlayer,
      };
      // 内核相关开关，与移动端一致：
      // - ExoPlayer 的内封特效 ASS 字幕需要开启 libass（exoLibassProvider）后，
      //   由原生 libass 渲染成位图，经 bitmapNotifier 叠加到画面上。
      // - nativeMpv 的 libass 内置于 libmpv.so，始终生效；gpu-next 需 SurfaceView。
      final useLibass = coreType == PlayerCoreType.exoPlayer
          ? ref.read(exoLibassProvider)
          : false;
      final dolbyVisionFix = coreType == PlayerCoreType.mpv
          ? ref.read(mpvDolbyVisionFixProvider)
          : false;
      final hardwareDecoding = ref.read(hardwareDecodingProvider);
      final useGpuNext = ref.read(gpuNextEnabledProvider);
      final preferredSubtitleLanguage =
          ref.read(preferredSubtitleLanguageProvider);
      final surfaceViewId = coreType == PlayerCoreType.nativeMpv
          ? DateTime.now().microsecondsSinceEpoch
          : null;
      // 续播：未看完且有上次进度则从该位置开始（ticks 为 100ns 单位）。
      final resumeTicks = item.userData?.playbackPositionTicks;
      final startPosition = (!(item.userData?.played ?? false) &&
              resumeTicks != null &&
              resumeTicks > 0)
          ? Duration(milliseconds: (resumeTicks / 10000).round())
          : null;

      await _service.initialize(
        videoUrl: videoUrl,
        itemId: _itemId,
        mediaSourceId: selection.mediaSource?.id,
        coreType: coreType,
        startPosition: startPosition,
        dolbyVisionFix: dolbyVisionFix,
        useLibass: useLibass,
        hardwareDecoding: hardwareDecoding,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        surfaceViewId: surfaceViewId,
        useGpuNext: useGpuNext,
        onStart: (info) async {
          try {
            await api.playback.reportPlaybackStart(info);
          } catch (_) {}
        },
        onProgress: (info) async {
          try {
            await api.playback.reportPlaybackProgress(info);
          } catch (_) {}
        },
        onStop: (info) async {
          try {
            await api.playback.reportPlaybackStopped(info);
          } catch (_) {}
          await _maybeScrobble(info, item);
        },
      );

      _item = item;
      _mediaSource = selection.mediaSource;
      ref.read(currentPlayingItemProvider.notifier).state = item;
      await _service.play();
      if (mounted) {
        setState(() => _ready = true);
        _scheduleHide();
      }
      await _loadSubtitles(preferredSubtitleLanguage, useLibass);
    } catch (e) {
      if (mounted) setState(() => _error = '播放失败：$e');
    }
  }

  /// 看完（进度达到统一观看阈值）→ 上报已连接的 Trakt/Bangumi。
  Future<void> _maybeScrobble(PlaybackStopInfo info, MediaItem item) async {
    if (_didScrobble) return;
    try {
      final runtime = item.runTimeTicks;
      if (runtime == null || runtime <= 0) return;
      final threshold = ref.read(watchedThresholdProvider);
      if (info.positionTicks / runtime < threshold / 100) return;
      _didScrobble = true;

      Map<String, String>? seriesProviderIds;
      if (item.type == 'Episode' && item.seriesId != null) {
        try {
          final series =
              await ref.read(apiClientProvider).media.getItemDetails(item.seriesId!);
          seriesProviderIds = series.providerIds;
        } catch (_) {}
      }
      await ref
          .read(syncControllerProvider.notifier)
          .scrobbleWatched(item, seriesProviderIds: seriesProviderIds);
    } catch (_) {}
  }

  // ============ 字幕 / 音轨 ============

  /// 轨道信息在 initialize 后可能稍有延迟，轮询几次直到就绪。
  Future<List<Map<String, dynamic>>> _tracksOfType(Set<String> types) async {
    for (var i = 0; i < 8; i++) {
      final tracks = _service.tracksInfo
          .where((t) => types.contains(t['type']?.toString()))
          .toList();
      if (tracks.isNotEmpty) return tracks;
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) break;
    }
    return _service.tracksInfo
        .where((t) => types.contains(t['type']?.toString()))
        .toList();
  }

  /// 按首选语言加载字幕：内封走轨道选择，外挂下载到本地再加载（公共加载器）。
  Future<void> _loadSubtitles(String? preferredLang, bool exoLibass) async {
    if (ref.read(subtitleTrackProvider) != null) return; // 尊重已有选择
    final source = _mediaSource;
    if (source == null) return;
    // 等内封轨道就绪，提升内封选中成功率。
    await _tracksOfType({'text', 'bitmap'});
    try {
      final index = await PlayerSubtitleLoader.loadPreferred(
        service: _service,
        api: ref.read(apiClientProvider),
        itemId: _itemId,
        mediaSource: source,
        preferredLanguage: preferredLang,
        exoLibassEnabled: exoLibass,
        authToken: ref.read(currentServerProvider)?.authToken,
      );
      if (index != null && mounted) {
        ref.read(subtitleTrackProvider.notifier).state = index;
      }
    } catch (_) {}
  }

  String _trackLabel(Map<String, dynamic> t) {
    final title = t['title']?.toString();
    if (title != null && title.trim().isNotEmpty) return title;
    final lang = t['language']?.toString();
    if (lang != null && lang.trim().isNotEmpty) return lang;
    return '轨道 ${t['trackIndex'] ?? t['id'] ?? ''}';
  }

  Future<void> _showSubtitlePanel() async {
    _revealControls();
    final subs = await _tracksOfType({'text', 'bitmap'});
    if (!mounted) return;
    final current = _service.selectedSubtitleTrackId;
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (dialogContext) => TvPanel(
        title: '字幕',
        onClose: () => Navigator.pop(dialogContext),
        children: [
          TvPanelOption(
            title: '关闭',
            isSelected: current == null,
            onTap: () {
              _stopStreamingTranslate();
              _service.deselectSubtitleTrack();
              ref.read(subtitleTrackProvider.notifier).state = null;
              Navigator.pop(dialogContext);
            },
          ),
          TvPanelOption(
            title: '翻译字幕（生成中文）',
            subtitle: '用已配置的翻译引擎把字幕译为中文',
            onTap: () {
              Navigator.pop(dialogContext);
              _translateSubtitle();
            },
          ),
          for (final t in subs)
            TvPanelOption(
              title: _trackLabel(t),
              subtitle: (t['type'] == 'bitmap') ? '图形字幕' : t['codec']?.toString(),
              isSelected: t['id']?.toString() == current,
              onTap: () {
                _stopStreamingTranslate();
                final id = t['id']?.toString();
                if (id != null) _service.selectSubtitleTrack(id);
                Navigator.pop(dialogContext);
              },
            ),
        ],
      ),
    );
  }

  /// 翻译字幕轨为中文并加载（TV）。
  Future<void> _translateSubtitle() async {
    final engine = ref.read(activeTranslationEngineProvider);
    final item = _item;
    final source = _mediaSource;
    if (engine == null) {
      _info('请先在「设置 → 翻译」中配置翻译引擎');
      return;
    }
    if (item == null || source == null) {
      _info('无播放信息');
      return;
    }
    final subtitles =
        source.mediaStreams.where((s) => s.isSubtitle).toList();
    if (subtitles.isEmpty) {
      _info('该片源无字幕轨可翻译');
      return;
    }
    final stream =
        subtitles.length == 1 ? subtitles.first : await _pickStreamToTranslate(subtitles);
    if (stream == null) return;

    final progress = ValueNotifier<String>('准备中…');
    if (!mounted) {
      progress.dispose();
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        content: Row(
          children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v,
                    style:
                        const TextStyle(color: TvDesignTokens.textPrimary)),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final path = await TranslationActions.translateEmbyStream(
        api: ref.read(apiClientProvider),
        service: ref.read(subtitleTranslationServiceProvider),
        engine: engine,
        itemId: item.id,
        mediaSourceId: source.id,
        stream: stream,
        targetLang: ref.read(translationTargetLangProvider),
        layout: ref.read(bilingualLayoutProvider),
        authToken: ref.read(currentServerProvider)?.authToken,
        onProgress: (done, total, stage) {
          progress.value = total > 1 ? '$stage $done/$total' : stage;
        },
      );
      await _service.loadLibassSubtitle(path);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _info('翻译完成并已加载中文字幕');
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      // 内封字幕拉取不到（服务端不支持单轨导出）→ 自动改为流式翻译（边播边译）。
      if (e.toString().contains('所有字幕地址均不可用')) {
        _startStreamingTranslate(engine, stream);
      } else if (mounted) {
        _info('翻译失败: $e');
      }
    } finally {
      progress.dispose();
    }
  }

  /// 内封字幕无法整轨下载时，启动流式翻译（叠加层按双语排版显示原文/译文）。
  void _startStreamingTranslate(TranslationEngine engine, MediaStream stream) {
    _streamTranslator?.stop();
    final translator = StreamingSubtitleTranslator(
      engine: engine,
      sourceLang:
          (stream.language?.isNotEmpty ?? false) ? stream.language! : 'auto',
      targetLang: ref.read(translationTargetLangProvider),
      layout: ref.read(bilingualLayoutProvider),
    );
    translator.errorMessage.addListener(() {
      final msg = translator.errorMessage.value;
      if (msg != null && mounted) _info('流式翻译引擎错误: $msg');
    });
    _streamTranslator = translator;
    translator.start(_service);
    if (mounted) setState(() {});
    _info('该字幕为内封、无法整轨下载，已改为流式翻译（边播边译）');
  }

  void _stopStreamingTranslate() {
    if (_streamTranslator == null) return;
    _streamTranslator?.stop();
    _streamTranslator = null;
    if (mounted) setState(() {});
  }

  Future<MediaStream?> _pickStreamToTranslate(List<MediaStream> subs) {
    return showDialog<MediaStream>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => TvPanel(
        title: '选择要翻译的字幕轨',
        onClose: () => Navigator.pop(ctx),
        children: [
          for (final s in subs)
            TvPanelOption(
              title: s.readableLabel(siblings: subs),
              subtitle: s.codec,
              onTap: () => Navigator.pop(ctx, s),
            ),
        ],
      ),
    );
  }

  void _info(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TvDesignTokens.surface,
        content:
            Text(msg, style: const TextStyle(color: TvDesignTokens.textPrimary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAudioPanel() async {
    _revealControls();
    final audios = await _tracksOfType({'audio'});
    if (!mounted) return;
    final current = _service.selectedAudioTrackId;
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (dialogContext) => TvPanel(
        title: '音轨',
        onClose: () => Navigator.pop(dialogContext),
        children: [
          for (final t in audios)
            TvPanelOption(
              title: _trackLabel(t),
              subtitle: t['codec']?.toString(),
              isSelected: t['id']?.toString() == current,
              onTap: () {
                final id = t['id']?.toString();
                if (id != null) _service.selectAudioTrack(id);
                Navigator.pop(dialogContext);
              },
            ),
        ],
      ),
    );
  }

  // ============ 控制 ============

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(TvDesignTokens.playerControlHideDelay, () {
      if (mounted && _service.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _revealControls() {
    if (!_showControls) setState(() => _showControls = true);
    _scheduleHide();
  }

  /// 平板/Pad 触控：点击画面切换控制条显隐（遥控器仍用方向/确认键）。
  void _toggleControls() {
    if (_showControls) {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _revealControls();
    }
  }

  Future<void> _togglePlay() async {
    if (_service.isPlaying) {
      await _service.pause();
      _hideTimer?.cancel();
      setState(() => _showControls = true);
    } else {
      await _service.play();
      _scheduleHide();
    }
  }

  void _seek(int seconds) {
    final target = _service.position + Duration(seconds: seconds);
    final dur = _service.duration;
    _service.seekTo(target < Duration.zero
        ? Duration.zero
        : (target > dur ? dur : target));
    _revealControls();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final step = ref.read(skipForwardStepProvider);

    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      if (_showControls && _service.isPlaying) {
        setState(() => _showControls = false);
      } else {
        context.pop();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      _revealControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      _seek(step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      _seek(-step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _revealControls();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final dur = _service.duration;
    final pos = _service.position;
    final progress =
        dur.inMilliseconds > 0 ? pos.inMilliseconds / dur.inMilliseconds : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_ready)
              Center(child: _service.buildVideo())
            else if (_error != null)
              _buildError()
            else
              const Center(
                child: CircularProgressIndicator(color: TvDesignTokens.brand),
              ),
            // 触控层（位于视频之上、控制条之下）：控制条隐藏时点击画面唤出，
            // 显示时点击空白处隐藏；控制条上的按钮在更上层会优先捕获各自的点击。
            if (_ready)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControls,
                ),
              ),
            // 流式翻译叠加层（按双语排版显示原文/译文，位于控制条之下）。
            if (_streamTranslator != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 96,
                child: IgnorePointer(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _streamTranslator!.displayText,
                    builder: (context, text, _) {
                      if (text.isEmpty) return const SizedBox.shrink();
                      return Center(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 48),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(blurRadius: 4, color: Colors.black),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (_ready)
              AnimatedOpacity(
                duration: TvDesignTokens.playerControlFadeDuration,
                opacity: _showControls ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: TvControlOverlay(
                    isPlaying: _service.isPlaying,
                    isPaused: !_service.isPlaying,
                    currentTime: pos,
                    totalTime: dur,
                    progress: progress.clamp(0.0, 1.0),
                    title: _item?.name ?? '正在播放',
                    onPlayPause: _togglePlay,
                    onSeekBackward: () =>
                        _seek(-ref.read(skipForwardStepProvider)),
                    onSeekForward: () =>
                        _seek(ref.read(skipForwardStepProvider)),
                    onSeek: (p) {
                      _service.seekTo(dur * p);
                      _revealControls();
                    },
                    onSubtitle: _showSubtitlePanel,
                    onAudioTrack: _showAudioPanel,
                    onClose: () => context.pop(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline,
              color: TvDesignTokens.error, size: 64),
          const SizedBox(height: TvDesignTokens.spacingLg),
          Text(
            _error ?? '播放失败',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: TvDesignTokens.fontSizeMd,
              color: TvDesignTokens.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
