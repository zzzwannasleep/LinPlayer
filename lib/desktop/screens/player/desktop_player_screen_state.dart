part of 'desktop_player_screen.dart';

class _DesktopPlayerScreenState extends ConsumerState<DesktopPlayerScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _windowChannel =
      MethodChannel('com.linplayer/window');
  static const Duration _uiRefreshInterval = Duration(milliseconds: 200);

  late VideoPlayerService _playerService;
  final FocusNode _focusNode = FocusNode();
  bool _initializingPlayer = false;
  Timer? _uiRefreshTimer;

  // 控制栏显隐状态
  bool _showControls = true;
  Timer? _hideControlsTimer;

  // 全屏状态
  bool _isFullscreen = false;

  // 倍速按钮长按状态
  bool _isSpeedLongPressing = false;
  bool _didTriggerSpeedLongPress = false;
  Timer? _speedLongPressTimer;

  // 跳过片头按钮
  bool _showSkipButton = false;
  Timer? _skipButtonTimer;
  bool _autoSkipTriggeredForCurrentOpening = false;

  // 鼠标是否在控制栏区域内
  bool _mouseInControlsArea = false;

  // 音量滑块显示
  bool _showVolumeSlider = false;
  Timer? _volumeSliderTimer;

  // 统计信息显示
  bool _showStatsOverlay = false;
  Map<String, String> _playbackStats = {};
  Timer? _statsRefreshTimer;
  bool _statsRefreshInFlight = false;
  bool _isSeekingWithSlider = false;
  double? _sliderSeekValue;
  MediaSource? _currentMediaSource;
  String? _videoUrl;
  WhisperSubtitleController? _whisperController;
  StreamingSubtitleTranslator? _streamTranslator;
  String? _displayTitle;
  late final IntroSkipController _introSkip;
  bool _suppressTrackSelectionListeners = false;
  bool _hasUserTouchedSubtitleSelection = false;
  bool _subtitleBootstrapInFlight = false;
  // 初始化阶段（拉取 PlaybackInfo / 元数据）失败信息。播放器适配器尚未创建时
  // _playerService.hasError 不会置位，需用它把网络超时等错误显示给用户。
  String? _initErrorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _introSkip = IntroSkipController(service: ref.read(introSkipServiceProvider));
    _playerService = VideoPlayerService();
    _initializePlayer();
    _focusNode.requestFocus();
    unawaited(_syncFullscreenState());
    _uiRefreshTimer = Timer.periodic(_uiRefreshInterval, (_) {
      if (!mounted) return;
      _checkSkipOpening();
      _introSkip.onPosition(_playerService.position);
      setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(audioTrackProvider, (prev, next) {
        if (_initializingPlayer ||
            _suppressTrackSelectionListeners ||
            prev == next ||
            next == null) {
          return;
        }
        final audioStreams = _audioStreamsFromCurrentSource();
        if (audioStreams.isEmpty) {
          return;
        }
        unawaited(_applyAudioStreamSelection(audioStreams, next));
      });
      ref.listenManual(subtitleTrackProvider, (prev, next) {
        if (_initializingPlayer ||
            _suppressTrackSelectionListeners ||
            prev == next) {
          return;
        }
        _hasUserTouchedSubtitleSelection = true;
        unawaited(_onSubtitleSelectionChanged(prev, next));
      });
      ref.listenManual(secondarySubtitleTrackProvider, (prev, next) {
        if (_initializingPlayer ||
            _suppressTrackSelectionListeners ||
            prev == next) {
          return;
        }
        unawaited(_onSecondarySubtitleSelectionChanged(next));
      });
      ref.listenManual(subtitleDelayProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleDelay(next));
        }
      });
      ref.listenManual(audioDelayProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setAudioDelay(next));
        }
      });
      ref.listenManual(subtitleSizeProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleSize(next));
        }
      });
      ref.listenManual(subtitlePositionProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitlePosition(next));
        }
      });
      ref.listenManual(subtitleFontProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleFont(next));
        }
      });
      ref.listenManual(subtitleBackgroundProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleBackground(next));
        }
      });
      ref.listenManual(pgsBlendModeProvider, (prev, next) {
        if (prev != next) {
          unawaited(_playerService.setSubtitleBlendMode(next));
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      return;
    }
    unawaited(_persistCurrentWatchHistory(force: true));
  }

  void _checkSkipOpening() {
    final openingStart = ref.read(skipOpeningStartProvider);
    final openingEnd = ref.read(skipOpeningEndProvider);
    final autoSkip = ref.read(skipAutoModeProvider);
    if (openingStart <= 0 || openingEnd <= 0 || openingEnd <= openingStart) {
      _autoSkipTriggeredForCurrentOpening = false;
      return;
    }

    final pos = _playerService.position.inSeconds;
    final inOpening = pos >= openingStart && pos < openingEnd;

    if (inOpening && autoSkip) {
      if (_autoSkipTriggeredForCurrentOpening) {
        return;
      }
      _autoSkipTriggeredForCurrentOpening = true;
      unawaited(_playerService.seekTo(Duration(seconds: openingEnd)));
    } else if (inOpening && !_showSkipButton) {
      setState(() => _showSkipButton = true);
      _skipButtonTimer?.cancel();
      _skipButtonTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _showSkipButton = false);
      });
    } else if (!inOpening && _showSkipButton) {
      setState(() => _showSkipButton = false);
      _skipButtonTimer?.cancel();
    } else if (!inOpening) {
      _autoSkipTriggeredForCurrentOpening = false;
    }
  }

  /// 点按「跳过片头/片尾」：片尾且开启自动连播则切下一集，否则 seek 到段末。
  void _onIntroSkipPressed(SkipPrompt prompt) {
    if (prompt.kind == SkipKind.outro &&
        ref.read(autoPlayNextProvider) &&
        ref.read(currentPlayingItemProvider)?.seriesId != null) {
      unawaited(_playNext());
    } else {
      unawaited(_playerService.seekTo(prompt.target));
      _introSkip.onPosition(prompt.target); // 立即收起按钮
    }
  }

  Future<void> _initializePlayer() async {
    if (_initializingPlayer) return;
    _initializingPlayer = true;
    _hasUserTouchedSubtitleSelection = false;
    _initErrorMessage = null;
    final api = ref.read(apiClientProvider);
    List<MediaStream> deferredSubtitleStreams = const <MediaStream>[];
    try {
      // 离线优先：本集已下载完成则用本地文件，拉取元数据失败时兜底离线播放。
      final downloadManager = ref.read(downloadManagerProvider);
      final localPath = downloadManager.completedFilePath(widget.itemId);
      final hasLocal = localPath != null && await File(localPath).exists();

      MediaItem item;
      PlaybackInfo? playbackInfo;
      try {
        final cachedItem = ref.read(currentPlayingItemProvider);
        item = cachedItem != null && cachedItem.id == widget.itemId
            ? cachedItem
            : await api.media.getItemDetails(widget.itemId);
        playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
      } catch (e) {
        final record = downloadManager.byItemId(widget.itemId);
        if (!hasLocal || record == null) rethrow;
        item = mediaItemFromDownload(record);
        playbackInfo = null;
      }

      final selection = playbackInfo != null
          ? buildPlaybackSelection(
              playbackInfo: playbackInfo,
              itemId: widget.itemId,
              preferredMediaSourceId:
                  widget.mediaSourceId ?? ref.read(selectedMediaSourceProvider),
              versionRegex: ref.read(preferredVersionRegexProvider),
              playSessionId:
                  '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
              strmDirectPlay: ref.read(strmDirectPlayProvider),
            )
          : buildOfflinePlaybackSelection(itemId: widget.itemId);
      final mediaSource = selection.mediaSource;

      final videoUrl = api.playback.getVideoStreamUrl(
        selection.primaryRequest.itemId,
        mediaSourceId: selection.primaryRequest.mediaSourceId,
        container: selection.primaryRequest.container,
        playSessionId: selection.primaryRequest.playSessionId,
        staticStream: selection.primaryRequest.staticStream,
        allowDirectPlay: selection.primaryRequest.allowDirectPlay,
        allowDirectStream: selection.primaryRequest.allowDirectStream,
        allowTranscoding: selection.primaryRequest.allowTranscoding,
        enableAutoStreamCopy: selection.primaryRequest.enableAutoStreamCopy,
        enableAutoStreamCopyAudio:
            selection.primaryRequest.enableAutoStreamCopyAudio,
        enableAutoStreamCopyVideo:
            selection.primaryRequest.enableAutoStreamCopyVideo,
      );
      final fallbackVideoUrl = selection.fallbackRequest == null
          ? null
          : api.playback.getVideoStreamUrl(
              selection.fallbackRequest!.itemId,
              mediaSourceId: selection.fallbackRequest!.mediaSourceId,
              container: selection.fallbackRequest!.container,
              playSessionId: selection.fallbackRequest!.playSessionId,
              staticStream: selection.fallbackRequest!.staticStream,
              allowDirectPlay: selection.fallbackRequest!.allowDirectPlay,
              allowDirectStream: selection.fallbackRequest!.allowDirectStream,
              allowTranscoding: selection.fallbackRequest!.allowTranscoding,
              enableAutoStreamCopy:
                  selection.fallbackRequest!.enableAutoStreamCopy,
              enableAutoStreamCopyAudio:
                  selection.fallbackRequest!.enableAutoStreamCopyAudio,
              enableAutoStreamCopyVideo:
                  selection.fallbackRequest!.enableAutoStreamCopyVideo,
            );

      // STRM 直链：开启且解析出可用直链时优先用直链，服务端直传流作为回退。
      final directUrl = selection.directPlayUrl;
      final hasDirect = directUrl != null && directUrl.isNotEmpty;
      final onlineUrl = hasDirect ? directUrl : videoUrl;

      // 本地文件覆盖播放源；在线地址留作本地失效时回退。
      final localFileSource =
          hasLocal ? Uri.file(localPath).toString() : null;
      final effectiveVideoUrl = localFileSource ?? onlineUrl;
      final effectiveFallbackUrl = localFileSource != null
          ? (playbackInfo != null ? onlineUrl : null)
          : (hasDirect ? videoUrl : fallbackVideoUrl);

      Duration? startPosition;
      try {
        startPosition = await _resolveResumeStartPosition(api, item);
      } catch (_) {
        startPosition = null;
      }
      final startPositionTicks = (startPosition?.inMilliseconds ?? 0) * 10000;

      ref.read(currentPlayingItemProvider.notifier).state = item;
      ref.read(selectedMediaSourceProvider.notifier).state = mediaSource?.id;
      // 自动跳过片头/片尾：联网识别本集片段（仅剧集，受设置开关控制）。
      unawaited(_introSkip.loadForItem(
        item,
        enabled: ref.read(autoSkipSegmentsProvider),
        fetchItem: (id) => api.media.getItemDetails(id),
      ));
      _currentMediaSource = mediaSource;
      _videoUrl = effectiveVideoUrl;
      _displayTitle = item.name;

      final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
      final coreType =
          coreString == 'mpv' ? PlayerCoreType.mpv : PlayerCoreType.exoPlayer;

      // 杜比视界自动切换（默认开，可关）：DV 流 + media_kit(mpv) 时强制软解 + DV 色彩修正，
      // 避免硬解杜比视界偏色。桌面 media_kit 走 vo=libmpv，无独立 gpu-next vo，
      // 故以软解 + dolbyVisionFix 的色调映射作为等效处理。见 dolbyAutoGpuNextSwProvider。
      // 取最高分辨率视频流判定 DV，避免被排在前面的低清流误导。
      final dvVideoStream = mediaSource?.primaryVideoStream;
      final autoDvMode = coreType == PlayerCoreType.mpv &&
          ref.read(dolbyAutoGpuNextSwProvider) &&
          (dvVideoStream?.isDolbyVision ?? false);
      final dolbyVisionFix = coreType == PlayerCoreType.mpv
          ? (autoDvMode || ref.read(mpvDolbyVisionFixProvider))
          : false;
      final useLibass = coreType == PlayerCoreType.exoPlayer
          ? ref.read(exoLibassProvider)
          : false;
      final hardwareDecoding =
          autoDvMode ? false : ref.read(hardwareDecodingProvider);
      final preferredSubtitleLanguage =
          ref.read(preferredSubtitleLanguageProvider);

      await _playerService.initialize(
        videoUrl: effectiveVideoUrl,
        itemId: widget.itemId,
        mediaSourceId: mediaSource?.id,
        fallbackVideoUrl: effectiveFallbackUrl,
        startPosition: startPosition,
        coreType: coreType,
        dolbyVisionFix: dolbyVisionFix,
        useLibass: useLibass,
        hardwareDecoding: hardwareDecoding,
        startWithSoftwareDecoding:
            selection.startsWithSoftwareDecoding && hardwareDecoding,
        fallbackReason: selection.fallbackReason,
        preferredSubtitleLanguage: preferredSubtitleLanguage,
        onStart: (info) async {
          try {
            await api.playback.reportPlaybackStart(info);
          } catch (_) {}
          await _writeWatchHistoryForItem(
            item: item,
            positionTicks: startPositionTicks,
            incrementPlayCount: true,
            force: true,
          );
        },
        onProgress: (info) async {
          try {
            await api.playback.reportPlaybackProgress(info);
          } catch (_) {}
          await _writeWatchHistoryForItem(
            item: item,
            positionTicks: info.positionTicks,
          );
        },
        onStop: (info) async {
          try {
            await api.playback.reportPlaybackStopped(info);
          } catch (_) {}
          await _writeWatchHistoryForItem(
            item: item,
            positionTicks: info.positionTicks,
            force: true,
          );
        },
      );

      // 初始化为异步过程，若期间用户已返回（widget 销毁），直接收尾退出，
      // 不再继续起播/选轨。VideoPlayerService 内部也已对 dispose 后的调用做短路。
      if (!mounted) return;

      await Future.wait([
        _playerService.setSubtitleSize(ref.read(subtitleSizeProvider)),
        _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider)),
        _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider)),
        _playerService.setSubtitleFont(ref.read(subtitleFontProvider)),
        _playerService
            .setSubtitleBackground(ref.read(subtitleBackgroundProvider)),
        _playerService.setAspectRatio(ref.read(aspectRatioProvider)),
      ]);

      await _playerService.play();

      final audioStreams =
          mediaSource?.mediaStreams.where((s) => s.isAudio).toList() ?? [];
      final subtitleStreams =
          mediaSource?.mediaStreams.where((s) => s.isSubtitle).toList() ?? [];
      await _waitForTracksReady(
        requireAudio: audioStreams.isNotEmpty,
      );

      final selectedAudioIndex = ref.read(audioTrackProvider);
      if (audioStreams.isNotEmpty) {
        final initialAudio =
            selectedAudioIndex ?? _resolveInitialAudioIndex(audioStreams);
        if (initialAudio != null) {
          ref.read(audioTrackProvider.notifier).state = initialAudio;
          await _applyAudioStreamSelection(audioStreams, initialAudio);
        }
      }

      if (subtitleStreams.isNotEmpty) {
        deferredSubtitleStreams = subtitleStreams;
      } else {
        ref.read(subtitleTrackProvider.notifier).state = null;
      }

      _startHideControlsTimer();
    } catch (e, st) {
      // 拉取 PlaybackInfo / 元数据失败（如服务器连接超时）。在适配器创建前抛出时，
      // _playerService 不会进入错误态，必须在此兜底显示错误，否则页面会停在 loading 且
      // 异常变成未捕获的异步错误。原始错误仅写日志（供导出反馈），界面只显示安全文案。
      AppLogger().eWithStack(
          'DesktopPlayer', '播放初始化失败: ${widget.itemId}', e, st);
      if (mounted) {
        _initErrorMessage = e.toString();
      }
    } finally {
      _initializingPlayer = false;
      if (mounted) {
        setState(() {});
      }
    }

    if (deferredSubtitleStreams.isNotEmpty) {
      unawaited(
          _initializeSubtitleSelectionAfterStartup(deferredSubtitleStreams));
    }
  }

  Future<Duration?> _resolveResumeStartPosition(
    ApiClientFactory api,
    MediaItem item,
  ) async {
    final remotePlayed = item.userData?.played ?? false;
    final remotePositionTicks =
        remotePlayed ? null : item.userData?.playbackPositionTicks?.round();
    final scopeKey = buildWatchHistoryScopeKey(ref.read(currentServerProvider));
    final resolvedTicks = scopeKey == null
        ? remotePositionTicks
        : await ref.read(watchHistoryProvider).resolveResumePositionTicks(
              scopeKey: scopeKey,
              api: api,
              item: item,
              remotePositionTicks: remotePositionTicks,
              remotePlayed: remotePlayed,
              crossServer: ref.read(crossServerResumeProvider),
            );
    if (resolvedTicks == null || resolvedTicks <= 0) {
      return null;
    }
    return Duration(milliseconds: (resolvedTicks / 10000).round());
  }

  Future<T> _runWithSuppressedTrackSelectionListeners<T>(
    Future<T> Function() action,
  ) async {
    _suppressTrackSelectionListeners = true;
    try {
      return await action();
    } finally {
      _suppressTrackSelectionListeners = false;
    }
  }

  Future<void> _initializeSubtitleSelectionAfterStartup(
    List<MediaStream> subtitleStreams,
  ) async {
    if (_subtitleBootstrapInFlight || subtitleStreams.isEmpty) {
      return;
    }
    _subtitleBootstrapInFlight = true;
    try {
      AppLogger().i(
        'DesktopPlayer',
        '起播后异步初始化字幕轨道: count=${subtitleStreams.length}',
      );
      await _waitForTracksReady(requireSubtitle: true);
      if (!mounted) {
        return;
      }

      final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
      if (selectedSubtitleIndex != null) {
        await _applyInitialSubtitleTrack(
            subtitleStreams, selectedSubtitleIndex);
      } else if (_hasUserTouchedSubtitleSelection) {
        AppLogger().i(
          'DesktopPlayer',
          '用户已手动处理字幕选择，跳过默认字幕自动挂载',
        );
      } else {
        await _applyPreferredSubtitleTrack(subtitleStreams);
      }

      // 起播后应用用户在详情页选择的次字幕（次字幕默认为「无」，不自动挂载）
      final selectedSecondaryIndex = ref.read(secondarySubtitleTrackProvider);
      if (selectedSecondaryIndex != null) {
        await _onSecondarySubtitleSelectionChanged(selectedSecondaryIndex);
      }
    } catch (e, stackTrace) {
      AppLogger().eWithStack(
        'DesktopPlayer',
        '起播后异步初始化字幕失败',
        e,
        stackTrace,
      );
    } finally {
      _subtitleBootstrapInFlight = false;
    }
  }

  Future<void> _applyInitialAudioTrack(
      List<MediaStream> audioStreams, int selectedIndex) async {
    final trackId = _matchAudioTrackId(audioStreams, selectedIndex);
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  List<Map<String, dynamic>> _subtitleTracksFrom(
      [List<Map<String, dynamic>>? tracks]) {
    final source = tracks ?? _playerService.tracksInfo;
    return source.where((track) {
      final type = track['type']?.toString();
      return type == 'subtitle' || type == 'text' || type == 'bitmap';
    }).toList();
  }

  List<Map<String, dynamic>> _selectableSubtitleTracksFrom([
    List<Map<String, dynamic>>? tracks,
  ]) {
    return _subtitleTracksFrom(tracks)
        .where((track) => track['id'] != 'auto' && track['id'] != 'no')
        .toList();
  }

  Future<void> _waitForTracksReady({
    bool requireAudio = false,
    bool requireSubtitle = false,
  }) async {
    if (!requireAudio && !requireSubtitle) {
      return;
    }
    final waitBudget =
        requireSubtitle && _playerService.coreType == PlayerCoreType.mpv
            ? const Duration(seconds: 18)
            : const Duration(milliseconds: 4500);
    final deadline = DateTime.now().add(waitBudget);
    while (DateTime.now().isBefore(deadline)) {
      final tracks = _playerService.tracksInfo;
      final audioReady =
          !requireAudio || tracks.any((track) => track['type'] == 'audio');
      final subtitleReady =
          !requireSubtitle || _selectableSubtitleTracksFrom(tracks).isNotEmpty;
      if (audioReady && subtitleReady) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    AppLogger().w(
      'DesktopPlayer',
      '等待轨道就绪超时: audio=$requireAudio, subtitle=$requireSubtitle, '
          'knownTracks=${_playerService.tracksInfo.length}, '
          'selectableSubtitles=${_selectableSubtitleTracksFrom().length}',
    );
  }

  Future<void> _applyInitialSubtitleTrack(
    List<MediaStream> subtitleStreams,
    int selectedIndex,
  ) async {
    await _onSubtitleSelectionChanged(null, selectedIndex);
  }

  /// 应用次字幕（MPV `secondary-sid`）。次字幕默认为「无」。
  /// 内封轨道直接按 trackId 设置，外挂字幕下载后加载；图形字幕(PGS/SUP)不支持。
  Future<void> _onSecondarySubtitleSelectionChanged(int? next) async {
    if (_currentMediaSource == null) {
      return;
    }
    if (next == null) {
      await _playerService.deselectSecondarySubtitle();
      return;
    }

    final coreType = _playerService.coreType;
    if (coreType != PlayerCoreType.mpv &&
        coreType != PlayerCoreType.nativeMpv) {
      AppLogger().w('DesktopPlayer', '次字幕仅支持 MPV 内核，当前内核: $coreType');
      return;
    }

    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    final target =
        subtitleStreams.where((stream) => stream.index == next).firstOrNull;
    if (target == null) {
      return;
    }

    final codec = (target.codec ?? '').toLowerCase();
    final targetTitle = target.displayTitle ?? target.title;
    final isExternal = target.isExternal == true;
    final kind = SubtitleTrackMatcher.classifyKind(
      codec: target.codec,
      title: targetTitle,
    );
    if (kind == SubtitleKind.bitmap) {
      AppLogger().w('DesktopPlayer', '图形字幕(PGS/SUP)暂不支持作为次字幕: index=$next');
      return;
    }

    try {
      if (!isExternal) {
        var trackId = _matchSubtitleTrackId(
          subtitleStreams,
          target.language,
          targetTitle,
          target.codec,
          target.index,
        );
        if (trackId == null || trackId.isEmpty) {
          trackId = await _waitForInternalSubtitleTrackId(
            subtitleStreams,
            target,
            targetTitle,
          );
        }
        if (trackId != null && trackId.isNotEmpty) {
          await _playerService.selectSecondarySubtitleTrack(trackId);
          AppLogger().i('DesktopPlayer', '内封次字幕已设置: trackId=$trackId');
          return;
        }
        AppLogger().w('DesktopPlayer', '未匹配到内封次字幕轨道，回退外挂加载: index=$next');
      }

      final file = await _prepareExternalSubtitleFile(
        target,
        codec,
        title: targetTitle,
        kind: kind,
      );
      await _playerService.loadSecondarySubtitle(file.path);
      AppLogger().i('DesktopPlayer', '外挂次字幕加载成功: ${file.path}');
    } catch (e, stackTrace) {
      AppLogger().eWithStack('DesktopPlayer', '加载次字幕失败', e, stackTrace);
    }
  }

  Future<void> _applyPreferredSubtitleTrack(
      List<MediaStream> subtitleStreams) async {
    if (subtitleStreams.isEmpty) {
      return;
    }
    final preferredLanguage =
        ref.read(preferredSubtitleLanguageProvider).trim().toLowerCase();
    // 「字幕选择」正则优先：命中则用正则结果，否则回退到首选字幕语言。
    final preferredTrack = matchPreferredStream(
            subtitleStreams, ref.read(preferredSubtitleRegexProvider)) ??
        subtitleStreams.firstWhere(
          (stream) =>
              (stream.language ?? '').trim().toLowerCase() == preferredLanguage,
          orElse: () => subtitleStreams.first,
        );
    await _runWithSuppressedTrackSelectionListeners(() async {
      ref.read(subtitleTrackProvider.notifier).state = preferredTrack.index;
      await _onSubtitleSelectionChanged(null, preferredTrack.index);
    });
  }

  List<MediaStream> _audioStreamsFromCurrentSource() {
    return _currentMediaSource?.mediaStreams
            .where((stream) => stream.isAudio)
            .toList() ??
        const <MediaStream>[];
  }

  List<MediaStream> _subtitleStreamsFromCurrentSource() {
    return _currentMediaSource?.mediaStreams
            .where((stream) => stream.isSubtitle)
            .toList() ??
        const <MediaStream>[];
  }

  int? _resolveInitialAudioIndex(List<MediaStream> audioStreams) {
    if (audioStreams.isEmpty) {
      return null;
    }
    // 「音频选择」正则优先：命中则用正则结果，否则回退到服务端默认轨。
    final regexMatch =
        matchPreferredStream(audioStreams, ref.read(preferredAudioRegexProvider));
    if (regexMatch != null) {
      return regexMatch.index;
    }
    final selected = audioStreams.firstWhere(
      (stream) => stream.isDefault == true,
      orElse: () => audioStreams.first,
    );
    return selected.index;
  }

  Future<void> _applyAudioStreamSelection(
    List<MediaStream> audioStreams,
    int selectedIndex,
  ) async {
    await _applyInitialAudioTrack(audioStreams, selectedIndex);
  }

  Future<void> _onSubtitleSelectionChanged(int? prev, int? next) async {
    if (prev == next || _currentMediaSource == null) {
      return;
    }
    // 用户切换/关闭字幕轨 → 结束流式翻译：清掉译文叠加层并恢复原文字幕可见性，
    // 否则旧译文叠加层会与新选中的内封字幕叠加，造成双字幕（双外语）。
    if (_streamTranslator != null) {
      _stopStreamingTranslate();
    }
    if (next == null) {
      _playerService.setSubtitleSelectionHint();
      await _playerService.deselectSubtitleTrack();
      return;
    }

    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    final target =
        subtitleStreams.where((stream) => stream.index == next).firstOrNull;
    if (target == null) {
      return;
    }

    final codec = (target.codec ?? '').toLowerCase();
    final targetTitle = target.displayTitle ?? target.title;
    final isExternal = target.isExternal == true;
    final subtitleKind = SubtitleTrackMatcher.classifyKind(
      codec: target.codec,
      title: targetTitle,
    );
    final shouldPreferNativeBitmapSubtitle =
        _playerService.coreType == PlayerCoreType.mpv &&
            subtitleKind == SubtitleKind.bitmap &&
            !isExternal;
    final canAttemptExternalSubtitleFallback =
        _canAttemptExternalSubtitleFallback(target);

    AppLogger().i(
      'DesktopPlayer',
      '字幕切换请求: index=${target.index}, codec=${target.codec}, title=$targetTitle, '
          'external=$isExternal, externalUrl=${target.isExternalUrl == true}, '
          'hasDeliveryUrl=${_hasSubtitleDeliveryUrl(target)}, '
          'kind=$subtitleKind, preferNativeBitmap=$shouldPreferNativeBitmapSubtitle, '
          'canExternalFallback=$canAttemptExternalSubtitleFallback',
    );

    if (!isExternal) {
      _playerService.setSubtitleSelectionHint(codec: codec, title: targetTitle);
      var trackId = _matchSubtitleTrackId(
        subtitleStreams,
        target.language,
        targetTitle,
        target.codec,
        target.index,
      );
      if ((trackId == null || trackId.isEmpty) &&
          _playerService.coreType == PlayerCoreType.mpv) {
        AppLogger().i(
          'DesktopPlayer',
          '字幕轨道尚未就绪，等待 MPV 暴露真实字幕轨道: index=${target.index}, codec=${target.codec}, title=$targetTitle',
        );
        trackId = await _waitForInternalSubtitleTrackId(
          subtitleStreams,
          target,
          targetTitle,
        );
      }
      if (trackId != null && trackId.isNotEmpty) {
        await _playerService.selectSubtitleTrack(trackId);
        if (!shouldPreferNativeBitmapSubtitle) {
          return;
        }
        final nativeBitmapSelected = await _verifyNativeBitmapSubtitleSelection(
          trackId,
          codec: codec,
          title: targetTitle,
        );
        if (nativeBitmapSelected) {
          AppLogger().i(
            'DesktopPlayer',
            'PGS/SUP 内封字幕已通过 mpv 原生轨道选中: trackId=$trackId',
          );
          return;
        }
        AppLogger().w(
          'DesktopPlayer',
          'PGS/SUP 内封字幕原生选轨未挂载成功，回退外挂加载: trackId=$trackId',
        );
      } else if (_playerService.coreType == PlayerCoreType.mpv) {
        if (!shouldPreferNativeBitmapSubtitle) {
          AppLogger().w(
            'DesktopPlayer',
            'MPV 内封字幕轨道仍未匹配成功，保留当前字幕状态: index=${target.index}, codec=${target.codec}',
          );
          return;
        }
        AppLogger().w(
          'DesktopPlayer',
          'PGS/SUP 未匹配到内封轨道 ID，回退外挂加载: index=${target.index}',
        );
      } else {
        return;
      }
    }

    // Only use the external bitmap subtitle path as a fallback after native
    // track selection fails, or when the subtitle is already external.
    if (!canAttemptExternalSubtitleFallback) {
      AppLogger().w(
        'DesktopPlayer',
        '跳过外挂字幕回退: index=${target.index}, codec=${target.codec}, '
            'reason=${_describeExternalSubtitleFallbackBlocker(target)}',
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _externalSubtitleFallbackUnavailableMessage(
              target,
              subtitleKind,
            ),
          ),
        ),
      );
      return;
    }
    _playerService.setSubtitleSelectionHint();
    await _playerService.deselectSubtitleTrack();
    try {
      final subtitleFile = await _prepareExternalSubtitleFile(
        target,
        codec,
        title: targetTitle,
        kind: subtitleKind,
      );
      await _loadExternalSubtitleWithRetry(subtitleFile);
    } catch (e, stackTrace) {
      AppLogger().eWithStack(
        'DesktopPlayer',
        '图形字幕加载失败: index=${target.index}, codec=${target.codec}, title=$targetTitle',
        e,
        stackTrace,
      );
      await _playerService.deselectSubtitleTrack();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('字幕加载失败: $e')),
      );
    }
  }

  Future<String?> _waitForInternalSubtitleTrackId(
    List<MediaStream> subtitleStreams,
    MediaStream target,
    String? targetTitle,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 14));
    while (DateTime.now().isBefore(deadline)) {
      final trackId = _matchSubtitleTrackId(
        subtitleStreams,
        target.language,
        targetTitle,
        target.codec,
        target.index,
      );
      if (trackId != null && trackId.isNotEmpty) {
        AppLogger().i(
          'DesktopPlayer',
          '等待后匹配到内封字幕轨道: index=${target.index}, trackId=$trackId',
        );
        return trackId;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<bool> _verifyNativeBitmapSubtitleSelection(
    String trackId, {
    String? codec,
    String? title,
  }) async {
    final adapter = _playerService.adapter;
    if (adapter is! MpvPlayerAdapter) {
      return true;
    }
    try {
      return await adapter.waitForSubtitleTrackSelection(
        trackId,
        hintedCodec: codec,
        hintedTitle: title,
      );
    } catch (e, stackTrace) {
      AppLogger().eWithStack(
        'DesktopPlayer',
        '校验 PGS/SUP 内封字幕轨道失败: trackId=$trackId',
        e,
        stackTrace,
      );
      return false;
    }
  }

  bool _hasSubtitleDeliveryUrl(MediaStream target) {
    final deliveryUrl = target.deliveryUrl?.trim();
    return deliveryUrl != null && deliveryUrl.isNotEmpty;
  }

  bool _hasHttpSubtitlePath(MediaStream target) {
    final path = target.path?.trim();
    return path != null &&
        path.isNotEmpty &&
        (path.startsWith('http://') || path.startsWith('https://'));
  }

  bool _canUseApiSubtitleStreamRoute(MediaStream target) {
    if (target.isExternal == true || target.isExternalUrl == true) {
      return true;
    }
    final deliveryMethod = target.deliveryMethod?.trim().toLowerCase();
    return deliveryMethod == 'external';
  }

  bool _canAttemptExternalSubtitleFallback(MediaStream target) {
    return _hasSubtitleDeliveryUrl(target) ||
        _hasHttpSubtitlePath(target) ||
        _canUseApiSubtitleStreamRoute(target);
  }

  String _describeExternalSubtitleFallbackBlocker(MediaStream target) {
    return 'external=${target.isExternal == true}, '
        'externalUrl=${target.isExternalUrl == true}, '
        'deliveryUrl=${_hasSubtitleDeliveryUrl(target)}, '
        'httpPath=${_hasHttpSubtitlePath(target)}, '
        'deliveryMethod=${target.deliveryMethod ?? ''}';
  }

  String _externalSubtitleFallbackUnavailableMessage(
    MediaStream target,
    SubtitleKind subtitleKind,
  ) {
    final adapter = _playerService.adapter;
    final missingPgsDecoder = subtitleKind == SubtitleKind.bitmap &&
        adapter is MpvPlayerAdapter &&
        !adapter.pgsDecoderAvailable;
    if (missingPgsDecoder) {
      return '当前 PC 端缺少 PGS/SUP 解码器，且该字幕没有可下载外挂源';
    }
    if (target.isExternal == true || target.isExternalUrl == true) {
      return '当前外挂字幕没有可用的下载地址';
    }
    return '当前字幕没有可用的外挂下载地址';
  }

  String? _matchAudioTrackId(
      List<MediaStream> audioStreams, int selectedIndex) {
    final tracks = _playerService.tracksInfo;
    final audioTracks =
        tracks.where((track) => track['type'] == 'audio').toList();
    if (audioTracks.isEmpty) {
      return null;
    }

    final position =
        audioStreams.indexWhere((stream) => stream.index == selectedIndex);
    if (position >= 0 && position < audioTracks.length) {
      final trackId = audioTracks[position]['id']?.toString();
      if (trackId != null && trackId.isNotEmpty) {
        return trackId;
      }
    }

    final target = audioStreams
        .where((stream) => stream.index == selectedIndex)
        .firstOrNull;
    final targetTitle = target?.displayTitle ?? target?.title ?? '';
    final targetLang = (target?.language ?? '').toLowerCase();
    if (targetTitle.isNotEmpty) {
      for (final track in audioTracks) {
        final title = (track['title'] ?? '').toString();
        if (_titlesMatch(targetTitle, title)) {
          return track['id']?.toString();
        }
      }
    }
    if (targetLang.isNotEmpty) {
      final candidates = audioTracks.where((track) {
        final language = (track['language'] ?? '').toString().toLowerCase();
        return language == targetLang;
      }).toList();
      if (candidates.length == 1) {
        return candidates.first['id']?.toString();
      }
      if (position >= 0 && position < candidates.length) {
        return candidates[position]['id']?.toString();
      }
    }

    return audioTracks.first['id']?.toString();
  }

  String? _matchSubtitleTrackId(
    List<MediaStream> subtitleStreams,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) {
    final subtitleTracks = _subtitleTracksFrom()
        .where((track) => track['id'] != 'auto' && track['id'] != 'no')
        .toList();
    if (subtitleTracks.isEmpty) {
      return null;
    }

    final kind = SubtitleTrackMatcher.classifyKind(
      codec: targetCodec,
      title: targetTitle,
    );
    if (_playerService.coreType == PlayerCoreType.mpv) {
      final directMatch = _matchLegacyMpvSubtitleTrack(
        subtitleTracks,
        targetLang: targetLang,
        targetTitle: targetTitle,
        targetCodec: targetCodec,
        targetStreamIndex: targetStreamIndex,
      );
      if (directMatch != null && directMatch.isNotEmpty) {
        return directMatch;
      }
    }
    final typedStreamPosition = _typedSubtitleStreamPosition(
      subtitleStreams,
      targetStreamIndex,
      kind,
    );

    return SubtitleTrackMatcher.matchTrackId(
      subtitleTracks: subtitleTracks,
      targetKind: kind,
      targetStreamIndex: targetStreamIndex,
      typedStreamPosition: typedStreamPosition,
      targetLang: targetLang,
      targetTitle: targetTitle,
      titlesMatch: _titlesMatch,
    );
  }

  String? _matchLegacyMpvSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks, {
    required String? targetLang,
    required String? targetTitle,
    required String? targetCodec,
    required int targetStreamIndex,
  }) {
    final codec = targetCodec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' ||
        codec == 'sup' ||
        codec == 'pgs' ||
        codec == 'dvdsub' ||
        codec == 'vobsub' ||
        codec.contains('hdmv') ||
        codec.contains('pgs');
    final isAss = codec == 'ass' || codec == 'ssa';

    var candidates = isGraphical
        ? subtitleTracks
            .where((track) =>
                track['type'] == 'bitmap' || track['isBitmap'] == true)
            .toList()
        : isAss
            ? subtitleTracks
                .where((track) =>
                    track['isAss'] == true || track['type'] == 'text')
                .toList()
            : subtitleTracks;

    if (candidates.isEmpty) {
      return subtitleTracks.isNotEmpty
          ? subtitleTracks.first['id']?.toString()
          : null;
    }

    if (targetTitle != null && targetTitle.isNotEmpty) {
      for (final track in candidates) {
        final title = (track['title'] ?? '').toString();
        if (title.isNotEmpty && _titlesMatch(targetTitle, title)) {
          return track['id']?.toString();
        }
      }
    }

    final normalizedTargetLang = (targetLang ?? '').trim().toLowerCase();
    if (normalizedTargetLang.isNotEmpty) {
      final langMatches = candidates.where((track) {
        final language =
            (track['language'] ?? '').toString().trim().toLowerCase();
        return language == normalizedTargetLang ||
            language == 'chi' ||
            language == 'zh';
      }).toList();
      if (langMatches.length == 1) return langMatches.first['id']?.toString();
      if (langMatches.length > 1 &&
          targetTitle != null &&
          targetTitle.isNotEmpty) {
        for (final track in langMatches) {
          final title = (track['title'] ?? '').toString();
          if (title.isNotEmpty && _titlesMatch(targetTitle, title)) {
            return track['id']?.toString();
          }
        }
        if (targetStreamIndex >= 0 && targetStreamIndex < langMatches.length) {
          return langMatches[targetStreamIndex]['id']?.toString();
        }
        return langMatches.first['id']?.toString();
      }
    }

    final embySubIndex =
        _extractEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
    if (embySubIndex >= 0 && embySubIndex < candidates.length) {
      return candidates[embySubIndex]['id']?.toString();
    }

    return candidates.first['id']?.toString();
  }

  int _extractEmbySubtitleIndex(
    int targetStreamIndex,
    List<Map<String, dynamic>> subtitleTracks,
  ) {
    if (subtitleTracks.isEmpty) return targetStreamIndex;
    final minId = subtitleTracks
        .map((track) => int.tryParse(track['id']?.toString() ?? ''))
        .whereType<int>()
        .fold<int?>(
            null, (prev, value) => prev == null || value < prev ? value : prev);
    if (minId == null) return targetStreamIndex;
    return targetStreamIndex - minId;
  }

  int _typedSubtitleStreamPosition(
    List<MediaStream> subtitleStreams,
    int targetStreamIndex,
    SubtitleKind targetKind,
  ) {
    final typedStreams = subtitleStreams.where((stream) {
      final streamKind = SubtitleTrackMatcher.classifyKind(
        codec: stream.codec,
        title: stream.displayTitle ?? stream.title,
      );
      if (targetKind == SubtitleKind.bitmap) {
        return streamKind == SubtitleKind.bitmap;
      }
      return streamKind != SubtitleKind.bitmap;
    }).toList();
    return typedStreams
        .indexWhere((stream) => stream.index == targetStreamIndex);
  }

  bool _titlesMatch(String expected, String actual) {
    final e = expected.toLowerCase();
    final a = actual.toLowerCase();
    if (e.isEmpty || a.isEmpty) {
      return false;
    }
    if (e == a || e.contains(a) || a.contains(e)) {
      return true;
    }
    final simpKeywords = ['简', 'chs', '简体', '简日', 'gb', '简中'];
    final tradKeywords = ['繁', 'cht', '繁体', '繁日', 'big5', '繁中'];
    final eIsSimp = simpKeywords.any(e.contains);
    final eIsTrad = tradKeywords.any(e.contains);
    final aIsSimp = simpKeywords.any(a.contains);
    final aIsTrad = tradKeywords.any(a.contains);
    if (eIsSimp && aIsSimp) {
      return true;
    }
    if (eIsTrad && aIsTrad) {
      return true;
    }
    return false;
  }

  String _embySubtitleCodec(String codec, {String? title, SubtitleKind? kind}) {
    final lower = codec.toLowerCase();
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    if (lower == 'srt' || lower == 'subrip') {
      return 'srt';
    }
    if (lower == 'vtt' || lower == 'webvtt') {
      return 'vtt';
    }
    if (resolvedKind == SubtitleKind.bitmap) {
      return 'pgs';
    }
    return 'ass';
  }

  List<String> _embySubtitleCodecCandidates(
    String codec, {
    String? title,
    SubtitleKind? kind,
  }) {
    final primary = _embySubtitleCodec(
      codec,
      title: title,
      kind: kind,
    );
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    if (resolvedKind != SubtitleKind.bitmap) {
      return [primary];
    }

    final candidates = <String>['sup', primary, 'pgs'];
    return candidates.toSet().toList();
  }

  String _subtitleFileExtension(String codec,
      {String? title, SubtitleKind? kind}) {
    final lower = codec.toLowerCase();
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    if (lower == 'srt' || lower == 'subrip') {
      return 'srt';
    }
    if (lower == 'vtt' || lower == 'webvtt') {
      return 'vtt';
    }
    if (resolvedKind == SubtitleKind.ass) {
      return 'ass';
    }
    if (resolvedKind == SubtitleKind.bitmap) {
      return 'sup';
    }
    return 'srt';
  }

  Future<File> _prepareExternalSubtitleFile(
    MediaStream target,
    String codec, {
    String? title,
    SubtitleKind? kind,
  }) async {
    final currentSource = _currentMediaSource;
    if (currentSource == null) {
      throw StateError('当前媒体源为空，无法加载外挂字幕');
    }
    final resolvedKind = kind ??
        SubtitleTrackMatcher.classifyKind(
          codec: codec,
          title: title,
        );
    final embyCodecCandidates = _embySubtitleCodecCandidates(
      codec,
      title: title,
      kind: resolvedKind,
    );
    final fileExtension = _subtitleFileExtension(
      codec,
      title: title,
      kind: resolvedKind,
    );
    final tempDir = await getTemporaryDirectory();
    final file = File(
      p.join(
        tempDir.path,
        'desktop_subtitle_${widget.itemId}_${target.index}.$fileExtension',
      ),
    );

    final shouldForceRefresh = resolvedKind == SubtitleKind.bitmap;
    AppLogger().i(
      'DesktopPlayer',
      '准备外挂字幕文件: index=${target.index}, codec=${target.codec}, title=$title, '
          'kind=$resolvedKind, embyCodecs=${embyCodecCandidates.join('/')}, file=${file.path}',
    );
    if (shouldForceRefresh && file.existsSync()) {
      await file.delete();
    }

    if (!file.existsSync() || await file.length() == 0) {
      final server = ref.read(currentServerProvider);
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      if (server?.authToken != null) {
        dio.options.headers['X-Emby-Token'] = server!.authToken;
        dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
      }
      Object? lastError;
      final subtitleUrls = _subtitleUrlCandidates(
        target: target,
        currentSource: currentSource,
        codecCandidates: embyCodecCandidates,
      );
      if (subtitleUrls.isEmpty) {
        throw StateError('当前字幕没有可用的外挂下载地址');
      }
      AppLogger().i(
        'DesktopPlayer',
        '外挂字幕候选地址: ${subtitleUrls.join(' | ')}',
      );
      for (final subtitleUrl in subtitleUrls) {
        try {
          AppLogger().i(
            'DesktopPlayer',
            '下载外挂字幕: url=$subtitleUrl',
          );
          await dio.download(subtitleUrl, file.path);
          final downloadedSize = await file.length();
          if (downloadedSize <= 0) {
            throw StateError('下载到的字幕文件为空');
          }
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          AppLogger().w(
            'DesktopPlayer',
            '外挂字幕下载失败: url=$subtitleUrl, error=$e',
          );
          if (file.existsSync()) {
            await file.delete();
          }
        }
      }
      if (lastError != null) {
        throw lastError;
      }
    }

    final fileSize = await file.length();
    if (fileSize <= 0) {
      throw StateError('下载到的字幕文件为空: ${file.path}');
    }

    return file;
  }

  List<String> _subtitleUrlCandidates({
    required MediaStream target,
    required MediaSource currentSource,
    required List<String> codecCandidates,
  }) {
    final api = ref.read(apiClientProvider);
    final urls = <String>[];

    final deliveryUrl = target.deliveryUrl?.trim();
    if (deliveryUrl != null && deliveryUrl.isNotEmpty) {
      urls.add(_resolveServerRelativeUrl(deliveryUrl));
    }

    final path = target.path?.trim();
    if (path != null &&
        path.isNotEmpty &&
        (path.startsWith('http://') || path.startsWith('https://'))) {
      urls.add(path);
    }

    if (_canUseApiSubtitleStreamRoute(target)) {
      for (final codec in codecCandidates) {
        urls.add(
          api.playback.getSubtitleStreamUrl(
            widget.itemId,
            currentSource.id,
            target.index,
            codec,
          ),
        );
      }
    }

    return urls.toSet().toList();
  }

  String _resolveServerRelativeUrl(String rawUrl) {
    if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) {
      return rawUrl;
    }
    final server = ref.read(currentServerProvider);
    final baseUrl = (server?.activeLineUrl ?? server?.baseUrl ?? '').trim();
    if (baseUrl.isEmpty) {
      return rawUrl;
    }
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = rawUrl.startsWith('/') ? rawUrl : '/$rawUrl';
    final authToken = server?.authToken?.trim();
    if (authToken == null ||
        authToken.isEmpty ||
        normalizedPath.contains('api_key=')) {
      return '$normalizedBase$normalizedPath';
    }
    final separator = normalizedPath.contains('?') ? '&' : '?';
    return '$normalizedBase$normalizedPath${separator}api_key=${Uri.encodeQueryComponent(authToken)}';
  }

  // ========== 控制栏显隐 ==========

  Future<void> _loadExternalSubtitleWithRetry(File subtitleFile) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        AppLogger().i(
          'DesktopPlayer',
          '尝试加载外挂字幕: attempt=$attempt, path=${subtitleFile.path}',
        );
        await _playerService.loadLibassSubtitle(subtitleFile.path);
        return;
      } catch (e) {
        lastError = e;
        AppLogger().e(
          'DesktopPlayer',
          '外挂字幕加载失败: attempt=$attempt, path=${subtitleFile.path}, error=$e',
        );
        if (attempt >= 3) {
          break;
        }
        await _playerService.deselectSubtitleTrack();
        await Future.delayed(const Duration(milliseconds: 220));
      }
    }
    throw lastError ?? StateError('外挂字幕加载失败');
  }

  void _startHideControlsTimer() {
    _cancelHideControlsTimer();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (_playerService.isPlaying && !_mouseInControlsArea && mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _cancelHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;
  }

  void _onMouseMoved() {
    if (!_showControls) {
      setState(() => _showControls = true);
    }
    if (_playerService.isPlaying) {
      _startHideControlsTimer();
    }
  }

  // ========== 键盘快捷键 ==========

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          _toggleFullscreen();
        } else if (context.canPop()) {
          context.pop();
        }
        break;
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
        _playerService.togglePlay();
        break;
      case LogicalKeyboardKey.arrowLeft:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _playerService.seekBy(const Duration(seconds: -60));
        } else {
          _playerService.seekBy(const Duration(seconds: -15));
        }
        break;
      case LogicalKeyboardKey.arrowRight:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _playerService.seekBy(const Duration(seconds: 60));
        } else {
          _playerService.seekBy(const Duration(seconds: 15));
        }
        break;
      case LogicalKeyboardKey.keyJ:
        _playerService.seekBy(const Duration(seconds: -15));
        break;
      case LogicalKeyboardKey.keyL:
        _playerService.seekBy(const Duration(seconds: 15));
        break;
      case LogicalKeyboardKey.arrowUp:
        _adjustVolume(0.05);
        break;
      case LogicalKeyboardKey.arrowDown:
        _adjustVolume(-0.05);
        break;
      case LogicalKeyboardKey.bracketLeft:
        _adjustSpeed(-0.25);
        break;
      case LogicalKeyboardKey.bracketRight:
        _adjustSpeed(0.25);
        break;
      case LogicalKeyboardKey.backspace:
        _playerService.setSpeed(1.0);
        break;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        break;
      case LogicalKeyboardKey.keyS:
        _cycleSubtitleTrack();
        break;
      case LogicalKeyboardKey.keyA:
        _cycleAudioTrack();
        break;
      case LogicalKeyboardKey.keyM:
        _toggleMute();
        break;
      case LogicalKeyboardKey.controlLeft:
      case LogicalKeyboardKey.controlRight:
        break;
      default:
        if (event.logicalKey == LogicalKeyboardKey.keyH &&
            HardwareKeyboard.instance.isControlPressed) {
          _toggleControlsVisibility();
        } else if (event.logicalKey == LogicalKeyboardKey.keyS &&
            HardwareKeyboard.instance.isControlPressed) {
          _takeScreenshot();
        }
    }
  }

  void _adjustVolume(double delta) {
    final newVolume = (_playerService.volume + delta).clamp(0.0, 1.0);
    _playerService.setVolume(newVolume);
  }

  void _adjustSpeed(double delta) {
    final newSpeed = (_playerService.speed + delta).clamp(0.25, 4.0);
    _playerService.setSpeed(newSpeed);
  }

  void _toggleMute() {
    if (_playerService.volume > 0) {
      _playerService.setVolume(0.0);
    } else {
      _playerService.setVolume(1.0);
    }
  }

  Future<void> _syncFullscreenState() async {
    try {
      final bool? isFullscreen = Platform.isWindows
          ? await _windowChannel.invokeMethod<bool>('isFullscreen')
          : await windowManager.isFullScreen();
      if (mounted && isFullscreen != null) {
        setState(() => _isFullscreen = isFullscreen);
        ref.read(desktopImmersiveModeProvider.notifier).state = isFullscreen;
      }
    } on MissingPluginException {
      // Ignore on platforms without desktop window integration.
    } on PlatformException {
      // Ignore and keep the local fallback state.
    }
  }

  void _toggleFullscreen() async {
    final target = !_isFullscreen;
    var fullscreen = target;

    try {
      if (Platform.isWindows) {
        fullscreen = await _windowChannel.invokeMethod<bool>(
              'setFullscreen',
              {'fullscreen': target},
            ) ??
            target;
      } else {
        // macOS / Linux 走 window_manager 的原生窗口全屏。
        await windowManager.setFullScreen(target);
        fullscreen = await windowManager.isFullScreen();
      }
    } on MissingPluginException {
      fullscreen = target;
    } on PlatformException {
      fullscreen = target;
    }

    if (!mounted) return;
    setState(() => _isFullscreen = fullscreen);
    // 通知应用根隐藏/恢复自绘标题栏，实现真正的全屏。
    ref.read(desktopImmersiveModeProvider.notifier).state = fullscreen;
    if (_showControls && _playerService.isPlaying) {
      _startHideControlsTimer();
    }
  }

  void _toggleControlsVisibility() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _startHideControlsTimer();
    }
  }

  void _cycleSubtitleTrack() {
    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    if (subtitleStreams.isEmpty) return;

    final currentIndex = ref.read(subtitleTrackProvider);
    final currentPosition =
        subtitleStreams.indexWhere((stream) => stream.index == currentIndex);
    final nextPosition = (currentPosition + 1) % (subtitleStreams.length + 1);

    if (nextPosition >= subtitleStreams.length) {
      ref.read(subtitleTrackProvider.notifier).state = null;
      return;
    }

    ref.read(subtitleTrackProvider.notifier).state =
        subtitleStreams[nextPosition].index;
  }

  void _cycleAudioTrack() {
    final tracks = _playerService.tracksInfo;
    final audioTracks = tracks.where((t) => t['type'] == 'audio').toList();
    if (audioTracks.length <= 1) return;

    final currentIndex = audioTracks.indexWhere((t) => t['selected'] == true);
    final nextIndex = (currentIndex + 1) % audioTracks.length;
    final trackId = audioTracks[nextIndex]['id']?.toString();
    if (trackId != null) _playerService.selectAudioTrack(trackId);
  }

  // ========== 截图 ==========

  String _sanitizeFileName(String value) {
    return value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _buildScreenshotFileName(String itemName, DateTime timestamp) {
    final sanitizedName = _sanitizeFileName(itemName);
    final padded = [
      timestamp.year.toString().padLeft(4, '0'),
      timestamp.month.toString().padLeft(2, '0'),
      timestamp.day.toString().padLeft(2, '0'),
      timestamp.hour.toString().padLeft(2, '0'),
      timestamp.minute.toString().padLeft(2, '0'),
      timestamp.second.toString().padLeft(2, '0'),
    ].join('');
    return '${sanitizedName.isEmpty ? widget.itemId : sanitizedName}_$padded.png';
  }

  Future<void> _takeScreenshot() async {
    try {
      final data = await _playerService.screenshot();
      if (!mounted) return;

      if (data != null && data.isNotEmpty) {
        final baseDirectory = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        // 与移动端统一：截图落到 下载/Linpic。
        final screenshotsDirectory =
            Directory(p.join(baseDirectory.path, 'Linpic'));
        if (!await screenshotsDirectory.exists()) {
          await screenshotsDirectory.create(recursive: true);
        }

        final itemName =
            ref.read(currentPlayingItemProvider)?.name ?? widget.itemId;
        final file = File(
          p.join(
            screenshotsDirectory.path,
            _buildScreenshotFileName(itemName, DateTime.now()),
          ),
        );
        await file.writeAsBytes(data, flush: true);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图已保存到 ${file.path}')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图功能暂不支持当前播放器内核')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图失败: $e')),
        );
      }
    }
  }

  // ========== 视频热区 ==========

  void _onVideoTapUp(TapUpDetails details) {
    final width = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    if (tapX < width * 0.25) {
      _playerService.seekBy(const Duration(seconds: -15));
    } else if (tapX > width * 0.75) {
      _playerService.seekBy(const Duration(seconds: 15));
    } else {
      _playerService.togglePlay();
    }
  }

  // ========== 倍速长按 ==========

  void _onSpeedButtonDown(bool increase) {
    _isSpeedLongPressing = true;
    _didTriggerSpeedLongPress = false;
    _speedLongPressTimer?.cancel();
    _speedLongPressTimer = Timer(const Duration(milliseconds: 320), () {
      if (!_isSpeedLongPressing) return;
      _didTriggerSpeedLongPress = true;
      _adjustSpeed(increase ? 0.05 : -0.05);
      _speedLongPressTimer =
          Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (_isSpeedLongPressing) {
          _adjustSpeed(increase ? 0.05 : -0.05);
        }
      });
    });
  }

  void _onSpeedButtonUp() {
    _isSpeedLongPressing = false;
    _speedLongPressTimer?.cancel();
    _speedLongPressTimer = null;
  }

  void _onSpeedButtonCancel() {
    _onSpeedButtonUp();
    _didTriggerSpeedLongPress = false;
  }

  void _handleSpeedButtonTap(bool increase) {
    if (_didTriggerSpeedLongPress) {
      _didTriggerSpeedLongPress = false;
      return;
    }
    _adjustSpeed(increase ? 0.25 : -0.25);
  }

  // ========== 上一集/下一集 ==========

  Future<void> _playPrevious() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) return;
    try {
      final currentMediaSourceId = ref.read(selectedMediaSourceProvider);
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
            currentItem!.seriesId!,
            seasonId: currentItem.seasonId,
          );
      final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
      if (currentIndex > 0) {
        if (mounted) {
          final previousEpisode = episodes[currentIndex - 1];
          context.replace(
            '/player/${previousEpisode.id}'
            '${currentMediaSourceId != null ? '?mediaSourceId=$currentMediaSourceId' : ''}',
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经是第一集了')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  Future<void> _playNext() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId == null) return;
    try {
      final currentMediaSourceId = ref.read(selectedMediaSourceProvider);
      final episodes = await ref.read(apiClientProvider).media.getEpisodes(
            currentItem!.seriesId!,
            seasonId: currentItem.seasonId,
          );
      final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
      if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
        if (mounted) {
          final nextEpisode = episodes[currentIndex + 1];
          context.replace(
            '/player/${nextEpisode.id}'
            '${currentMediaSourceId != null ? '?mediaSourceId=$currentMediaSourceId' : ''}',
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经是最后一集了')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
  }

  // ========== Anime4K ==========

  Future<void> _showAnime4KMenu() async {
    final currentLevel = ref.read(anime4KLevelProvider);
    const levels = [
      {'value': 'off', 'label': '关闭'},
      {'value': 'modeA', 'label': '模式 A - 性能优先'},
      {'value': 'modeB', 'label': '模式 B - 平衡'},
      {'value': 'modeC', 'label': '模式 C - 质量优先'},
    ];
    final result = await showPlayerSettingsPanel<String>(
      context: context,
      title: 'Anime4K 超分设置',
      width: 320,
      children: levels
          .map((level) => PanelOptionTile(
                label: level['label']!,
                selected: currentLevel == level['value'],
                onTap: () => Navigator.pop(context, level['value']),
              ))
          .toList(),
    );
    if (result != null && mounted) {
      try {
        if (result == 'off') {
          await _playerService.applySuperResolution(false);
        } else {
          await _playerService.applySuperResolutionLevel(result);
        }
        ref.read(anime4KLevelProvider.notifier).state = result;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result == 'off'
                  ? '已关闭 Anime4K 超分'
                  : '已应用 Anime4K ${_anime4KLevelLabel(result)}',
            ),
          ),
        );
      } catch (e) {
        ref.read(anime4KLevelProvider.notifier).state = 'off';
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Anime4K 应用失败: $e')),
        );
      }
    }
  }

  String _anime4KLevelLabel(String level) {
    switch (level) {
      case 'modeA':
        return '模式 A';
      case 'modeB':
        return '模式 B';
      case 'modeC':
        return '模式 C';
      default:
        return level;
    }
  }

  // ========== 跳过片头 ==========

  void _onSkipOpeningPressed() {
    final openingEnd = ref.read(skipOpeningEndProvider);
    _playerService.seekTo(Duration(seconds: openingEnd));
    setState(() => _showSkipButton = false);
    _skipButtonTimer?.cancel();
  }

  // ========== 更多菜单 ==========

  void _showMoreMenu() {
    final item = ref.read(currentPlayingItemProvider);
    final isMpv = normalizePlayerCore(ref.read(playerCoreProvider)) == 'mpv';
    final anime4KLevel = ref.read(anime4KLevelProvider);
    final hardwareDecoding = ref.read(hardwareDecodingProvider);

    void go(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    showPlayerSettingsPanel(
      context: context,
      title: '更多选项',
      width: 320,
      children: [
        PanelOptionTile(
          label: '截图',
          leading: const Icon(Icons.camera_alt_outlined),
          selected: false,
          onTap: () => go(_takeScreenshot),
        ),
        PanelOptionTile(
          label: '字幕选择',
          leading: const Icon(Icons.subtitles_outlined),
          selected: false,
          onTap: () => go(_showSubtitleSelector),
        ),
        PanelOptionTile(
          label: '音轨选择',
          leading: const Icon(Icons.audiotrack),
          selected: false,
          onTap: () => go(_showAudioSelector),
        ),
        if (item?.seriesId != null)
          PanelOptionTile(
            label: '选集',
            leading: const Icon(Icons.playlist_play),
            selected: false,
            onTap: () => go(_showEpisodeSelector),
          ),
        PanelOptionTile(
          label: '画面比例',
          leading: const Icon(Icons.aspect_ratio),
          selected: false,
          onTap: () => go(_showAspectRatioDialog),
        ),
        const PanelDivider(),
        PanelOptionTile(
          label: '硬件解码',
          subtitle: hardwareDecoding ? '当前已开启' : '当前已关闭',
          leading: const Icon(Icons.memory),
          selected: hardwareDecoding,
          onTap: () => go(_toggleHardwareDecoding),
        ),
        if (isMpv)
          PanelOptionTile(
            label: 'Anime4K 超分',
            subtitle: anime4KLevel == 'off'
                ? '当前已关闭'
                : '当前: ${_anime4KLevelLabel(anime4KLevel)}',
            leading: const Icon(Icons.hd),
            selected: anime4KLevel != 'off',
            onTap: () => go(_showAnime4KMenu),
          ),
        PanelOptionTile(
          label: '统计信息',
          subtitle: _showStatsOverlay ? '显示中' : '已隐藏',
          leading: const Icon(Icons.analytics),
          selected: _showStatsOverlay,
          onTap: () => go(_toggleStatsOverlay),
        ),
        PanelOptionTile(
          label: _isFullscreen ? '退出全屏' : '进入全屏',
          leading: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
          selected: false,
          onTap: () => go(_toggleFullscreen),
        ),
      ],
    );
  }

  void _showAspectRatioDialog() {
    final ratios = ['自动', '16:9', '4:3', '21:9', '全屏', '原始'];
    final currentRatio = ref.read(aspectRatioProvider);

    showPlayerSettingsPanel(
      context: context,
      title: '画面比例',
      width: 300,
      children: ratios
          .map((ratio) => PanelOptionTile(
                label: ratio,
                selected: currentRatio == ratio,
                onTap: () {
                  ref.read(aspectRatioProvider.notifier).state = ratio;
                  _playerService.setAspectRatio(ratio);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('画面比例: $ratio')),
                  );
                },
              ))
          .toList(),
    );
  }

  // ========== 选集弹窗 ==========

  void _showEpisodeSelector() {
    final item = ref.read(currentPlayingItemProvider);
    if (item?.seriesId == null) return;

    final maxHeight = MediaQuery.of(context).size.height * 0.7;
    showPlayerSettingsPanel(
      context: context,
      title: '选集',
      width: 420,
      children: [
        SizedBox(
          height: maxHeight,
          child: _EpisodeSelectorList(
            seriesId: item!.seriesId!,
            currentEpisodeId: item.id,
            currentMediaSourceId: ref.read(selectedMediaSourceProvider),
          ),
        ),
      ],
    );
  }

  // ========== 字幕/音轨弹窗 ==========

  Future<void> _waitForTrackSelectorItems({
    required bool subtitle,
  }) async {
    for (var i = 0; i < 10; i++) {
      final streams = subtitle
          ? _subtitleStreamsFromCurrentSource()
          : _audioStreamsFromCurrentSource();
      if (streams.isNotEmpty) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _showSubtitleSelector() async {
    await _waitForTrackSelectorItems(subtitle: true);
    final subtitleStreams = _subtitleStreamsFromCurrentSource();
    if (subtitleStreams.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有可切换的字幕轨道')),
      );
      return;
    }
    _showTrackSelectorDialog(
      title: '字幕选择',
      streams: subtitleStreams,
      selectedIndex: ref.read(subtitleTrackProvider),
      onSelect: (streamIndex) {
        ref.read(subtitleTrackProvider.notifier).state = streamIndex;
      },
      canDisable: true,
      subtitle: true,
      onTranslate: () => _translateSubtitle(subtitleStreams),
      translateStreaming: _streamTranslator != null,
      onWhisper: ref.read(whisperEnabledProvider)
          ? () => _toggleWhisperStreaming()
          : null,
      whisperRunning: _whisperController?.isRunning ?? false,
    );
  }

  Future<void> _showAudioSelector() async {
    await _waitForTrackSelectorItems(subtitle: false);
    final audioStreams = _audioStreamsFromCurrentSource();
    if (audioStreams.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前没有可切换的音轨')),
      );
      return;
    }
    _showTrackSelectorDialog(
      title: '音轨选择',
      streams: audioStreams,
      selectedIndex: ref.read(audioTrackProvider),
      onSelect: (streamIndex) {
        ref.read(audioTrackProvider.notifier).state = streamIndex;
      },
      subtitle: false,
    );
  }

  /// 翻译字幕轨为中文并加载（桌面）。
  Future<void> _translateSubtitle(List<MediaStream> subtitleStreams) async {
    // 已在流式翻译中 → 再次点击即停止。
    if (_streamTranslator != null) {
      _stopStreamingTranslate();
      _translateMsg('已停止流式翻译');
      return;
    }
    final engine = ref.read(activeTranslationEngineProvider);
    if (engine == null) {
      _translateMsg('请先在「设置 → 字幕翻译」中配置翻译引擎');
      return;
    }
    final source = _currentMediaSource;
    if (source == null) {
      _translateMsg('无播放信息');
      return;
    }
    MediaStream? stream;
    final sel = ref.read(subtitleTrackProvider);
    if (sel != null) {
      for (final s in subtitleStreams) {
        if (s.index == sel) {
          stream = s;
          break;
        }
      }
    }
    stream ??= subtitleStreams.length == 1
        ? subtitleStreams.first
        : await _pickStreamToTranslate(subtitleStreams);
    if (stream == null) return;

    final progress = ValueNotifier<String>('准备中…');
    if (!mounted) {
      progress.dispose();
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(ctx).colorScheme.primary)),
              const SizedBox(width: 16),
              ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final path = await TranslationActions.translateEmbyStream(
        api: ref.read(apiClientProvider),
        service: ref.read(subtitleTranslationServiceProvider),
        engine: engine,
        itemId: widget.itemId,
        mediaSourceId: source.id,
        stream: stream,
        targetLang: ref.read(translationTargetLangProvider),
        layout: ref.read(bilingualLayoutProvider),
        authToken: ref.read(currentServerProvider)?.authToken,
        onProgress: (done, total, stage) {
          progress.value = total > 1 ? '$stage $done/$total' : stage;
        },
      );
      await _playerService.loadLibassSubtitle(path);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _translateMsg('翻译完成并已加载中文字幕');
      }
    } catch (e, st) {
      AppLogger().eWithStack('DesktopPlayer', '字幕翻译失败', e, st);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      // 内封字幕拉取不到（服务端不支持单轨导出）→ 自动改为流式翻译。
      if (e.toString().contains('所有字幕地址均不可用')) {
        _startStreamingTranslate(engine, stream);
      } else if (mounted) {
        _translateMsg('翻译失败: $e');
      }
    } finally {
      progress.dispose();
    }
  }

  /// 内封字幕无法整轨下载时，启动流式翻译（边播边译，叠加层显示中文）。
  void _startStreamingTranslate(TranslationEngine engine, MediaStream stream) {
    _streamTranslator?.stop();
    final translator = StreamingSubtitleTranslator(
      engine: engine,
      sourceLang: (stream.language?.isNotEmpty ?? false)
          ? stream.language!
          : 'auto',
      targetLang: ref.read(translationTargetLangProvider),
      layout: ref.read(bilingualLayoutProvider),
    );
    translator.errorMessage.addListener(() {
      final msg = translator.errorMessage.value;
      if (msg != null && mounted) {
        _translateMsg('流式翻译引擎错误: $msg');
      }
    });
    _streamTranslator = translator;
    translator.start(_playerService);
    if (mounted) setState(() {});
    _translateMsg('该字幕为内封、无法整轨下载，已改为流式翻译（边播边译）');
  }

  void _stopStreamingTranslate() {
    _streamTranslator?.stop();
    _streamTranslator = null;
    if (mounted) setState(() {});
  }

  Future<MediaStream?> _pickStreamToTranslate(List<MediaStream> subs) {
    return showPlayerSettingsPanel<MediaStream>(
      context: context,
      title: '选择要翻译的字幕轨',
      width: 380,
      children: [
        for (final s in subs)
          PanelOptionTile(
            label: s.readableLabel(siblings: subs),
            subtitle: s.codec != null ? '编码: ${s.codec}' : null,
            selected: false,
            onTap: () => Navigator.pop(context, s),
          ),
      ],
    );
  }

  void _translateMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 启动/停止 Whisper 实时字幕（桌面专属）。
  Future<void> _toggleWhisperStreaming() async {
    if (_whisperController?.isRunning ?? false) {
      _whisperController?.stop();
      if (mounted) setState(() {});
      _translateMsg('已停止 Whisper 实时字幕');
      return;
    }
    final engine = ref.read(activeTranslationEngineProvider);
    if (engine == null) {
      _translateMsg('请先在「设置 → 字幕翻译」中配置翻译引擎');
      return;
    }
    final source = _videoUrl;
    if (source == null) {
      _translateMsg('无视频源');
      return;
    }

    final manager = WhisperModelManager();
    final model = ref.read(whisperModelProvider);
    if (!await manager.isDownloaded(model)) {
      _translateMsg('请先在「设置 → 字幕翻译 → Whisper」中下载 ${model.displayName} 模型');
      return;
    }
    final modelFile = await manager.modelFile(model);

    final binMgr = DesktopBinaryManager();
    // whisper-cli：内置/PATH/已配置中定位。
    final whisperPath =
        await binMgr.resolveWhisper(configured: ref.read(whisperBinaryPathProvider));
    if (whisperPath == null) {
      _translateMsg('未找到 whisper-cli（应随应用内置，或在「设置」中指定其路径）');
      return;
    }
    // ffmpeg：自动检测，缺失则征求许可下载。
    var ffmpegPath =
        await binMgr.resolveFfmpeg(configured: ref.read(ffmpegPathProvider));
    if (ffmpegPath == null) {
      ffmpegPath = await _promptDownloadFfmpeg(binMgr);
      if (ffmpegPath == null) {
        _translateMsg('未安装 ffmpeg，已取消');
        return;
      }
      ref.read(ffmpegPathProvider.notifier).state = ffmpegPath;
    }

    final extractor = WhisperAudioExtractor(ffmpegPath: ffmpegPath);
    final transcriber = WhisperTranscriber(
      modelPath: modelFile.path,
      binaryPath: whisperPath,
    );

    final controller = WhisperSubtitleController(
      engine: engine,
      translationService: ref.read(subtitleTranslationServiceProvider),
      extractor: extractor,
      transcriber: transcriber,
      sourceLang: 'auto',
      targetLang: ref.read(translationTargetLangProvider),
      layout: ref.read(bilingualLayoutProvider),
      onSubtitleUpdated: (path) async {
        try {
          await _playerService.loadLibassSubtitle(path);
        } catch (_) {}
      },
    );
    _whisperController = controller;
    if (mounted) setState(() {});
    _translateMsg('Whisper 实时字幕已启动，将随播放逐步生成');

    final token = ref.read(currentServerProvider)?.authToken;
    // 后台运行，不阻塞 UI。
    unawaited(controller.start(
      source: source,
      total: _playerService.duration,
      positionGetter: () => _playerService.position,
      authToken: token,
    ));
  }

  /// 征求许可后下载 ffmpeg，返回安装路径或 null（取消/失败）。
  Future<String?> _promptDownloadFfmpeg(DesktopBinaryManager binMgr) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('需要 ffmpeg'),
        content: const Text(
          'Whisper 实时字幕需要 ffmpeg 抽取音频。系统中未检测到 ffmpeg，'
          '是否现在下载官方静态构建？',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下载')),
        ],
      ),
    );
    if (ok != true) return null;

    final progress = ValueNotifier<String>('下载 ffmpeg…');
    if (!mounted) {
      progress.dispose();
      return null;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(ctx).colorScheme.primary)),
              const SizedBox(width: 16),
              ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      final path = await binMgr.downloadFfmpeg(onProgress: (r, t, p) {
        progress.value =
            t > 0 ? '下载 ffmpeg… ${(p * 100).toStringAsFixed(0)}%' : '下载 ffmpeg…';
      });
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      return path;
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _translateMsg('ffmpeg 下载失败: $e');
      }
      return null;
    } finally {
      progress.dispose();
    }
  }

  void _showTrackSelectorDialog({
    required String title,
    required List<MediaStream> streams,
    required int? selectedIndex,
    required ValueChanged<int> onSelect,
    required bool subtitle,
    bool canDisable = false,
    VoidCallback? onTranslate,
    bool translateStreaming = false,
    VoidCallback? onWhisper,
    bool whisperRunning = false,
  }) {
    showPlayerSettingsPanel(
      context: context,
      title: title,
      width: 380,
      children: [
        if (onTranslate != null)
          PanelActionTile(
            icon: translateStreaming ? Icons.stop_circle : Icons.translate,
            label: translateStreaming ? '停止流式翻译' : '翻译字幕（生成中文）',
            onTap: () {
              Navigator.pop(context);
              onTranslate();
            },
          ),
        if (onWhisper != null)
          PanelActionTile(
            icon: whisperRunning ? Icons.stop_circle : Icons.record_voice_over,
            label: whisperRunning ? '停止 Whisper 实时字幕' : 'Whisper 实时字幕',
            onTap: () {
              Navigator.pop(context);
              onWhisper();
            },
          ),
        if (onTranslate != null || onWhisper != null) const PanelDivider(),
        if (canDisable)
          PanelOptionTile(
            label: '关闭字幕',
            selected: selectedIndex == null,
            onTap: () {
              _playerService.deselectSubtitleTrack();
              Navigator.pop(context);
            },
          ),
        ...streams.map((stream) => PanelOptionTile(
              label: stream.readableLabel(siblings: streams),
              subtitle: stream.codec != null
                  ? '编码: ${stream.codec}${subtitle ? (stream.isExternal == true ? ' (外挂)' : ' (内封)') : ''}'
                  : null,
              selected: selectedIndex == stream.index,
              onTap: () {
                onSelect(stream.index);
                Navigator.pop(context);
              },
            )),
      ],
    );
  }

  // ========== 格式化时间 ==========

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // ========== 鼠标滚轮音量 ==========

  void _onMouseWheelScroll(PointerScrollEvent event) {
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    _adjustVolume(delta);
  }

  // ========== 统计信息行 ==========

  List<Widget> _buildStatsRows() {
    final rows = <Widget>[];

    // 文件信息
    final versionName = _currentMediaSource?.name?.trim();
    if (versionName != null && versionName.isNotEmpty) {
      rows.add(_buildStatRow('文件', versionName));
    }

    final fileSize = _playbackStats['file-size'];
    if (fileSize != null && fileSize != 'null') {
      final size = int.tryParse(fileSize);
      if (size != null) {
        rows.add(_buildStatRow('大小', _formatFileSize(size)));
      }
    }

    // 视频信息
    final width = _playbackStats['width'];
    final height = _playbackStats['height'];
    if (width != null && height != null) {
      rows.add(_buildStatRow('分辨率', '$width x $height'));
    }

    final fps = _playbackStats['container-fps'] ?? _playbackStats['fps'];
    if (fps != null) {
      rows.add(_buildStatRow('帧率', '$fps fps'));
    }

    final videoBitrate = _playbackStats['video-bitrate'];
    if (videoBitrate != null) {
      final bitrate = int.tryParse(videoBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('视频码率', _formatBitrate(bitrate)));
      }
    }

    final videoCodec = _playbackStats['video-codec'] ??
        _playbackStats['current-tracks/video/codec'];
    if (videoCodec != null && videoCodec.isNotEmpty) {
      rows.add(_buildStatRow('视频编码', videoCodec));
    }

    final pixelFormat = _playbackStats['video-params/pixelformat'];
    if (pixelFormat != null && pixelFormat.isNotEmpty) {
      rows.add(_buildStatRow('像素格式', pixelFormat));
    }

    // 音频信息
    final audioCodec = _playbackStats['audio-codec'] ??
        _playbackStats['current-tracks/audio/codec'];
    if (audioCodec != null && audioCodec.isNotEmpty) {
      rows.add(_buildStatRow('音频编码', audioCodec));
    }

    final audioBitrate = _playbackStats['audio-bitrate'];
    if (audioBitrate != null) {
      final bitrate = int.tryParse(audioBitrate);
      if (bitrate != null) {
        rows.add(_buildStatRow('音频码率', _formatBitrate(bitrate)));
      }
    }

    final sampleRate = _playbackStats['audio-params/sample-rate'];
    if (sampleRate != null) {
      rows.add(_buildStatRow('采样率', '${sampleRate}Hz'));
    }

    final channels = _playbackStats['audio-params/channel-count'];
    if (channels != null) {
      rows.add(_buildStatRow('声道', '${channels}ch'));
    }

    // 渲染信息
    final hwdec = _playbackStats['hwdec-current'];
    if (hwdec != null && hwdec.isNotEmpty && hwdec != 'no') {
      rows.add(_buildStatRow('硬解', hwdec));
    }

    final voFps = _playbackStats['estimated-vf-fps'];
    if (voFps != null) {
      rows.add(_buildStatRow('渲染帧率', '${voFps}fps'));
    }

    final dropCount = _playbackStats['frame-drop-count'] ??
        _playbackStats['vo-drop-frame-count'];
    if (dropCount != null && dropCount != '0') {
      rows.add(_buildStatRow('丢帧', dropCount));
    }

    final cacheDuration = _playbackStats['demuxer-cache-duration'];
    if (cacheDuration != null) {
      rows.add(_buildStatRow('缓冲', '${cacheDuration}s'));
    }

    final cacheSpeed = _playbackStats['cache-speed'];
    if (cacheSpeed != null && cacheSpeed.isNotEmpty) {
      rows.add(_buildStatRow('缓存速率', '${cacheSpeed}x'));
    }

    final pausedForCache = _playbackStats['paused-for-cache'];
    if (pausedForCache != null && pausedForCache.isNotEmpty) {
      rows.add(_buildStatRow(
          '缓存等待', pausedForCache == 'yes' ? '是' : pausedForCache));
    }

    final cacheBufferingState = _playbackStats['cache-buffering-state'];
    if (cacheBufferingState != null && cacheBufferingState.isNotEmpty) {
      rows.add(_buildStatRow('缓存状态', cacheBufferingState));
    }

    // 播放状态
    rows.add(
        _buildStatRow('速度', '${_playerService.speed.toStringAsFixed(2)}x'));
    rows.add(_buildStatRow('位置',
        '${_formatDuration(_playerService.position)} / ${_formatDuration(_playerService.duration)}'));

    return rows;
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        Text(value),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String _formatBitrate(int bps) {
    if (bps < 1000) return '${bps}bps';
    if (bps < 1000000) return '${(bps / 1000).toStringAsFixed(0)}Kbps';
    return '${(bps / 1000000).toStringAsFixed(2)}Mbps';
  }

  // ========== 生命周期 ==========

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 先取消所有定时器/订阅，确保即便后续 ref 调用抛错也不会留下仍在运行的
    // 周期定时器（它们会在半销毁状态下继续 ref.read 触发连环崩溃）。
    _cancelHideControlsTimer();
    _skipButtonTimer?.cancel();
    _speedLongPressTimer?.cancel();
    _volumeSliderTimer?.cancel();
    _statsRefreshTimer?.cancel();
    _uiRefreshTimer?.cancel();
    // 离开播放页时退出全屏并恢复标题栏，避免窗口停在无边框全屏、标题栏却消失的状态。
    if (_isFullscreen) {
      if (Platform.isWindows) {
        _windowChannel.invokeMethod<bool>(
            'setFullscreen', {'fullscreen': false});
      } else {
        windowManager.setFullScreen(false);
      }
    }
    // 整棵路由子树被销毁时 ProviderScope 可能已先行 dispose，此处 ref 访问会抛
    // "Cannot use ref after the widget was disposed"。用 try/catch 包裹，避免 dispose
    // 中途抛错导致 super.dispose() 不被调用、State 停留在半销毁的僵尸态。
    try {
      ref.read(desktopImmersiveModeProvider.notifier).state = false;
    } catch (_) {}
    _whisperController?.stop();
    _streamTranslator?.dispose();
    _introSkip.dispose();
    _focusNode.dispose();
    _playerService.dispose();
    super.dispose();
  }

  Future<void> _writeWatchHistoryForItem({
    required MediaItem item,
    required int positionTicks,
    bool incrementPlayCount = false,
    bool force = false,
  }) async {
    // 播放器进度/停止回调可能在播放页销毁后仍触发，此时严禁再用 ref。
    if (!mounted) return;
    final scopeKey = buildWatchHistoryScopeKey(ref.read(currentServerProvider));
    if (scopeKey == null) {
      return;
    }
    try {
      final record = await ref.read(watchHistoryProvider).capturePlayback(
            scopeKey: scopeKey,
            api: ref.read(apiClientProvider),
            item: item,
            positionTicks: positionTicks,
            source: WatchHistoryWriteSource.internalPlayer,
            watchedThresholdPercent: ref.read(watchedThresholdProvider),
            incrementPlayCount: incrementPlayCount,
            force: force,
          );
      _maybeWriteBackCrossServer(
        scopeKey: scopeKey,
        item: item,
        record: record,
        force: force,
      );
    } catch (_) {
      // Ignore local watch history failures to avoid interrupting playback.
    }
  }

  /// 看完 / 停止时，把进度与「已看完」回传到其它服务器（受设置开关控制）。
  void _maybeWriteBackCrossServer({
    required String scopeKey,
    required MediaItem item,
    required WatchHistoryRecord? record,
    required bool force,
  }) {
    if (record == null || !mounted) return;
    if (!ref.read(crossServerWritebackEnabledProvider)) return;
    // 仅在「看完」或显式停止时回传，避免每个进度回调都打其它服务器。
    if (!record.played && !force) return;
    unawaited(
      ref.read(watchHistoryWritebackServiceProvider).propagate(
            currentScopeKey: scopeKey,
            currentApi: ref.read(apiClientProvider),
            item: item,
            positionTicks: record.lastPositionTicks,
            played: record.played,
            servers: ref.read(serverListProvider),
            range: ref.read(crossServerWritebackRangeProvider),
            includeProgress: ref.read(crossServerWritebackProgressProvider),
          ),
    );
  }

  Future<void> _persistCurrentWatchHistory({bool force = false}) async {
    final item = ref.read(currentPlayingItemProvider);
    if (item == null) {
      return;
    }
    await _writeWatchHistoryForItem(
      item: item,
      positionTicks: (_playerService.position.inMilliseconds * 10000).round(),
      force: force,
    );
  }

  // ========== 统计信息显示 ==========

  void _toggleStatsOverlay() {
    setState(() {
      _showStatsOverlay = !_showStatsOverlay;
      if (_showStatsOverlay) {
        _refreshStats();
        _statsRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          _refreshStats();
        });
      } else {
        _statsRefreshTimer?.cancel();
        _statsRefreshTimer = null;
        _playbackStats = {};
      }
    });
  }

  Future<void> _refreshStats() async {
    if (!_showStatsOverlay || !mounted || _statsRefreshInFlight) return;
    _statsRefreshInFlight = true;
    try {
      final stats = await _playerService.getPlaybackStats();
      if (mounted && _showStatsOverlay) {
        setState(() {
          _playbackStats = stats;
        });
      }
    } finally {
      _statsRefreshInFlight = false;
    }
  }

  /// 弹幕叠加层（鼠标穿透）。开关/无弹幕时返回空。
  Widget _buildDanmakuOverlay() {
    final enabled = ref.watch(danmakuEnabledProvider);
    final items = ref.watch(loadedDanmakuProvider);
    if (!enabled || items.isEmpty) return const SizedBox.shrink();
    final delay = ref.watch(danmakuDelayProvider);
    return Positioned.fill(
      child: IgnorePointer(
        child: DanmakuOverlay(
          items: items,
          position: _playerService.position -
              Duration(milliseconds: (delay * 1000).round()),
          isPlaying: _playerService.isPlaying,
          opacity: ref.watch(danmakuOpacityProvider),
          fontSizeFactor: ref.watch(danmakuFontSizeProvider),
          speedFactor: ref.watch(danmakuSpeedProvider),
          densityFactor: ref.watch(danmakuDensityProvider),
          displayArea: ref.watch(danmakuDisplayAreaProvider),
          stroke: ref.watch(danmakuStrokeProvider),
          fontFamily: ref.watch(customDanmakuFontPathProvider).isEmpty
              ? null
              : FontService.danmakuFontFamily,
        ),
      ),
    );
  }

  /// 打开「搜索弹幕」弹层（复用移动端的分源搜索面板）。
  void _openDanmakuSearch() {
    final item = ref.read(currentPlayingItemProvider);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1C1C1E),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                child: Row(
                  children: [
                    const Icon(Icons.subtitles_outlined,
                        color: Colors.white70, size: 20),
                    const SizedBox(width: 8),
                    const Text('搜索弹幕',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: DanmakuSearchContent(item: item),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 弹幕快捷设置弹层（开关 + 透明度/显示区域/描边）。
  void _openDanmakuSettings() {
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, r, _) {
          return Dialog(
            backgroundColor: const Color(0xFF1C1C1E),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示弹幕',
                          style: TextStyle(color: Colors.white)),
                      value: r.watch(danmakuEnabledProvider),
                      onChanged: (v) =>
                          r.read(danmakuEnabledProvider.notifier).state = v,
                    ),
                    _slider(r, '透明度', danmakuOpacityProvider),
                    _slider(r, '字号', danmakuFontSizeProvider),
                    _slider(r, '速度', danmakuSpeedProvider),
                    _slider(r, '密度', danmakuDensityProvider),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示区域',
                          style: TextStyle(color: Colors.white)),
                      trailing: DropdownButton<double>(
                        dropdownColor: const Color(0xFF2C2C2E),
                        value: r.watch(danmakuDisplayAreaProvider),
                        items: const [
                          DropdownMenuItem(
                              value: 0.25,
                              child: Text('顶部 1/4',
                                  style: TextStyle(color: Colors.white))),
                          DropdownMenuItem(
                              value: 0.5,
                              child: Text('半屏',
                                  style: TextStyle(color: Colors.white))),
                          DropdownMenuItem(
                              value: 1.0,
                              child: Text('全屏',
                                  style: TextStyle(color: Colors.white))),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            r.read(danmakuDisplayAreaProvider.notifier).state =
                                v;
                          }
                        },
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('描边文字',
                          style: TextStyle(color: Colors.white)),
                      value: r.watch(danmakuStrokeProvider),
                      onChanged: (v) =>
                          r.read(danmakuStrokeProvider.notifier).state = v,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _slider(
      WidgetRef r,
      String label,
      StateNotifierProvider<PreferenceNotifier<double>, double> p) {
    final value = r.watch(p);
    return Row(
      children: [
        SizedBox(
            width: 48,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13))),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: (v) => r.read(p.notifier).state = v,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);
    final isMpv = normalizePlayerCore(ref.read(playerCoreProvider)) == 'mpv';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, event) {
          _handleKeyEvent(event);
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          onHover: (_) => _onMouseMoved(),
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _onMouseWheelScroll(event);
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 视频区域
                _playerService.buildVideo(),

                // 弹幕层（鼠标穿透，不挡控制栏）。
                _buildDanmakuOverlay(),

                // 流式翻译译文叠加层（中文显示在 mpv 原文字幕上方，构成双语）。
                if (_streamTranslator != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 72,
                    child: IgnorePointer(
                      child: ValueListenableBuilder<String>(
                        valueListenable: _streamTranslator!.displayText,
                        builder: (context, text, _) {
                          if (text.isEmpty) return const SizedBox.shrink();
                          return Center(
                            child: Container(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                text,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
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

                // 缓冲指示器
                if (_playerService.isBuffering)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: 1,
                        duration: const Duration(milliseconds: 140),
                        curve: Curves.easeOut,
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.88),
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.12)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.4,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Text(
                                  '正在缓冲，等待更多数据...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // 错误显示：只展示安全文案，绝不回显含播放地址的原始报错。
                if (_playerService.hasError || _initErrorMessage != null)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.white, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            friendlyPlaybackError(
                                _initErrorMessage ?? _playerService.errorMessage),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            kPlaybackErrorFeedbackHint,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.65),
                                fontSize: 12,
                                height: 1.6),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 6),
                          const SelectableText(
                            kFeedbackChannelUrl,
                            style: TextStyle(
                                color: Color(0xFF5B8DEF),
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _initializePlayer,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 视频热区点击层
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: _onVideoTapUp,
                  onDoubleTap: _toggleFullscreen,
                ),

                // 统计信息覆盖层（MPV式OSD）
                if (_showStatsOverlay)
                  Positioned(
                    top: 80,
                    left: 16,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DefaultTextStyle(
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontFamily: 'monospace',
                            height: 1.5,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_playbackStats.isEmpty)
                                const Text('正在获取统计信息...')
                              else
                                ..._buildStatsRows(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // 跳过片头按钮
                if (_showSkipButton)
                  Positioned(
                    top: 80,
                    right: 24,
                    child: ElevatedButton.icon(
                      onPressed: _onSkipOpeningPressed,
                      icon: const Icon(Icons.skip_next, size: 18),
                      label: const Text('跳过片头'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),

                // 控制栏覆盖层
                if (_showControls && !_playerService.isLocked)
                  _buildControlsOverlay(item, isMpv),

                // 锁定状态指示
                if (_playerService.isLocked)
                  Positioned(
                    top: 16,
                    left: 16,
                    child: IconButton(
                      icon: const Icon(Icons.lock, color: Colors.white),
                      tooltip: '已锁定',
                      onPressed: _playerService.toggleLock,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 控制栏覆盖层 ==========

  Widget _buildControlsOverlay(MediaItem? item, bool isMpv) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 顶栏渐变背景
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Container(
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.8),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: _buildTopBar(item, isMpv),
              ),
            ),
          ),
        ),

        // 左侧浮动按钮
        Positioned(
          left: 0,
          top: 120,
          bottom: 132,
          width: 60,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildIconButton(
                    icon: Icons.camera_alt,
                    tooltip: '截图 (Ctrl+S)',
                    onPressed: _takeScreenshot,
                  ),
                  const SizedBox(height: 16),
                  _buildIconButton(
                    icon:
                        _playerService.isLocked ? Icons.lock : Icons.lock_open,
                    tooltip: '锁定',
                    onPressed: _playerService.toggleLock,
                  ),
                ],
              ),
            ),
          ),
        ),

        // 右侧浮动按钮（倍速）
        Positioned(
          right: 0,
          top: 120,
          bottom: 132,
          width: 60,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildIconButton(
                    icon: Icons.add,
                    tooltip: '加速',
                    onPressed: () => _handleSpeedButtonTap(true),
                    onTapDown: (_) => _onSpeedButtonDown(true),
                    onTapUp: (_) => _onSpeedButtonUp(),
                    onTapCancel: _onSpeedButtonCancel,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_playerService.speed.toStringAsFixed(2)}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildIconButton(
                    icon: Icons.remove,
                    tooltip: '减速',
                    onPressed: () => _handleSpeedButtonTap(false),
                    onTapDown: (_) => _onSpeedButtonDown(false),
                    onTapUp: (_) => _onSpeedButtonUp(),
                    onTapCancel: _onSpeedButtonCancel,
                  ),
                ],
              ),
            ),
          ),
        ),

        // 自动跳过片头/片尾按钮：左下角、底栏之上，随控制栏一并显隐。
        Positioned(
          left: 24,
          bottom: 96,
          child: ValueListenableBuilder<SkipPrompt?>(
            valueListenable: _introSkip.prompt,
            builder: (context, prompt, _) {
              if (prompt == null) return const SizedBox.shrink();
              return ElevatedButton.icon(
                onPressed: () => _onIntroSkipPressed(prompt),
                icon: const Icon(Icons.skip_next, size: 18),
                label: Text(prompt.label),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                ),
              );
            },
          ),
        ),

        // 底栏渐变背景
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: MouseRegion(
            onEnter: (_) => setState(() => _mouseInControlsArea = true),
            onExit: (_) => setState(() => _mouseInControlsArea = false),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.85),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildProgressBar(),
                    _buildBottomBar(item),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ========== 顶栏 ==========

  Widget _buildTopBar(MediaItem? item, bool isMpv) {
    final title = _displayTitle?.trim().isNotEmpty == true
        ? _displayTitle!
        : item?.name ?? widget.itemId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // 返回按钮
          _buildIconButton(
            icon: Icons.arrow_back,
            tooltip: '返回',
            onPressed: () => context.pop(),
          ),
          const SizedBox(width: 12),
          // 标题
          Expanded(
            child: _MarqueeText(
              text: title,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          // Anime4K
          if (isMpv)
            _buildIconButton(
              icon: Icons.hd,
              tooltip: 'Anime4K 超分',
              color: ref.watch(anime4KLevelProvider) != 'off'
                  ? const Color(0xFF5B8DEF)
                  : Colors.white,
              onPressed: _showAnime4KMenu,
            ),
          // 跳过片头
          _buildIconButton(
            icon: Icons.skip_next,
            tooltip: '跳过片头设置',
            onPressed: _showSkipDialog,
          ),
          // 硬解开关
          _buildIconButton(
            icon: ref.watch(hardwareDecodingProvider)
                ? Icons.memory
                : Icons.slow_motion_video,
            tooltip: '硬件解码',
            onPressed: _toggleHardwareDecoding,
          ),
          // 更多菜单
          _buildIconButton(
            icon: Icons.more_vert,
            tooltip: '更多',
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }

  // ========== 进度条 ==========

  Widget _buildProgressBar() {
    final effectiveProgress =
        _sliderSeekValue ?? _playerService.progress.clamp(0.0, 1.0);
    final effectivePosition = _isSeekingWithSlider
        ? Duration(
            milliseconds:
                (_playerService.duration.inMilliseconds * effectiveProgress)
                    .round(),
          )
        : _playerService.position;
    final currentTime = _formatDuration(effectivePosition);
    final totalTime = _formatDuration(_playerService.duration);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          // 当前时间
          Text(
            currentTime,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 12),
          // 进度条
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF5B8DEF),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                thumbColor: const Color(0xFF5B8DEF),
                overlayColor: const Color(0xFF5B8DEF).withValues(alpha: 0.2),
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: effectiveProgress.clamp(0.0, 1.0),
                onChangeStart: (_) {
                  setState(() {
                    _isSeekingWithSlider = true;
                    _sliderSeekValue = _playerService.progress.clamp(0.0, 1.0);
                  });
                },
                onChanged: (value) {
                  setState(() {
                    _isSeekingWithSlider = true;
                    _sliderSeekValue = value.clamp(0.0, 1.0);
                  });
                },
                onChangeEnd: (value) {
                  final position = Duration(
                    milliseconds: (value.clamp(0.0, 1.0) *
                            _playerService.duration.inMilliseconds)
                        .round(),
                  );
                  setState(() {
                    _isSeekingWithSlider = false;
                    _sliderSeekValue = null;
                  });
                  _playerService.seekTo(position);
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 总时间
          Text(
            totalTime,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  // ========== 底栏 ==========

  Widget _buildBottomBar(MediaItem? item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          // 左侧：音量
          _buildVolumeControl(),
          const Spacer(),
          // 中间：播放控制
          _buildPlaybackControls(),
          const Spacer(),
          // 右侧：功能按钮
          _buildFunctionControls(item),
        ],
      ),
    );
  }

  Widget _buildVolumeControl() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          onEnter: (_) {
            setState(() => _showVolumeSlider = true);
            _volumeSliderTimer?.cancel();
          },
          onExit: (_) {
            _volumeSliderTimer = Timer(const Duration(seconds: 2), () {
              if (mounted) setState(() => _showVolumeSlider = false);
            });
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIconButton(
                icon: _playerService.volume == 0
                    ? Icons.volume_off
                    : _playerService.volume < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up,
                tooltip: '音量',
                onPressed: _toggleMute,
              ),
              if (_showVolumeSlider)
                SizedBox(
                  width: 100,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF5B8DEF),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                      thumbColor: const Color(0xFF5B8DEF),
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
                    ),
                    child: Slider(
                      value: _playerService.volume.clamp(0.0, 1.0),
                      onChanged: (value) => _playerService.setVolume(value),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaybackControls() {
    final isPlayActionBlocked = _initializingPlayer ||
        !_playerService.isInitialized ||
        _playerService.hasError;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildIconButton(
          icon: Icons.skip_previous,
          tooltip: '上一集',
          onPressed: _playPrevious,
        ),
        const SizedBox(width: 16),
        GestureDetector(
          onTap: isPlayActionBlocked ? null : _playerService.togglePlay,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(
                alpha: isPlayActionBlocked ? 0.05 : 0.1,
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _playerService.isPlaybackActionPending || _initializingPlayer
                  ? Icons.hourglass_top
                  : (_playerService.isPlaying ? Icons.pause : Icons.play_arrow),
              color: isPlayActionBlocked
                  ? Colors.white.withValues(alpha: 0.45)
                  : Colors.white,
              size: 28,
            ),
          ),
        ),
        const SizedBox(width: 16),
        _buildIconButton(
          icon: Icons.skip_next,
          tooltip: '下一集',
          onPressed: _playNext,
        ),
      ],
    );
  }

  Widget _buildFunctionControls(MediaItem? item) {
    final danmakuOn = ref.watch(danmakuEnabledProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: '弹幕',
          child: PopupMenuButton<String>(
            tooltip: '',
            color: const Color(0xFF2C2C2E),
            icon: Icon(
              danmakuOn ? Icons.comment : Icons.comments_disabled_outlined,
              color: danmakuOn ? Colors.white : Colors.white60,
              size: 22,
            ),
            onSelected: (v) {
              switch (v) {
                case 'toggle':
                  ref.read(danmakuEnabledProvider.notifier).state = !danmakuOn;
                  break;
                case 'search':
                  _openDanmakuSearch();
                  break;
                case 'settings':
                  _openDanmakuSettings();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'toggle',
                child: Row(children: [
                  Icon(danmakuOn ? Icons.visibility_off : Icons.visibility,
                      color: Colors.white70, size: 18),
                  const SizedBox(width: 10),
                  Text(danmakuOn ? '隐藏弹幕' : '显示弹幕',
                      style: const TextStyle(color: Colors.white)),
                ]),
              ),
              const PopupMenuItem(
                value: 'search',
                child: Row(children: [
                  Icon(Icons.search, color: Colors.white70, size: 18),
                  SizedBox(width: 10),
                  Text('搜索弹幕', style: TextStyle(color: Colors.white)),
                ]),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Row(children: [
                  Icon(Icons.tune, color: Colors.white70, size: 18),
                  SizedBox(width: 10),
                  Text('弹幕设置', style: TextStyle(color: Colors.white)),
                ]),
              ),
            ],
          ),
        ),
        _buildIconButton(
          icon: Icons.subtitles,
          tooltip: '字幕',
          onPressed: _showSubtitleSelector,
        ),
        _buildIconButton(
          icon: Icons.audiotrack,
          tooltip: '音轨',
          onPressed: _showAudioSelector,
        ),
        _buildIconButton(
          icon: _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          tooltip: '全屏 (F)',
          onPressed: _toggleFullscreen,
        ),
        if (item?.seriesId != null)
          _buildIconButton(
            icon: Icons.playlist_play,
            tooltip: '选集',
            onPressed: _showEpisodeSelector,
          ),
      ],
    );
  }

  // ========== 通用按钮 ==========

  Widget _buildIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
    GestureTapDownCallback? onTapDown,
    GestureTapUpCallback? onTapUp,
    GestureTapCancelCallback? onTapCancel,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          onTapDown: onTapDown,
          onTapUp: onTapUp,
          onTapCancel: onTapCancel,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: color ?? Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  // ========== 跳过片头设置 ==========

  void _showSkipDialog() {
    showPlayerSettingsPanel(
      context: context,
      title: '跳过片头设置',
      width: 340,
      children: [
        const PanelSectionTitle('时间区间'),
        _SkipTimeField(
            label: '片头开始 (秒)', provider: skipOpeningStartProvider),
        const SizedBox(height: 4),
        _SkipTimeField(
            label: '片头结束 (秒)', provider: skipOpeningEndProvider),
        const PanelDivider(),
        Consumer(
          builder: (context, ref, _) => PanelSwitchRow(
            label: '自动跳过',
            subtitle: '到达片头区间自动跳过，而不是显示按钮',
            value: ref.watch(skipAutoModeProvider),
            onChanged: (value) =>
                ref.read(skipAutoModeProvider.notifier).state = value,
          ),
        ),
      ],
    );
  }

  // ========== 硬解切换 ==========

  void _toggleHardwareDecoding() async {
    final current = ref.read(hardwareDecodingProvider);
    final savedPosition = _playerService.position;
    final wasPlaying = _playerService.isPlaying;

    ref.read(hardwareDecodingProvider.notifier).state = !current;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    await _initializePlayer();
    if (savedPosition > Duration.zero) {
      await _playerService.seekTo(savedPosition);
    }
    if (!wasPlaying) {
      await _playerService.pause();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(!current ? '已切换硬件解码' : '已切换软件解码')),
      );
    }
  }
}

// ========== 辅助组件 ==========
