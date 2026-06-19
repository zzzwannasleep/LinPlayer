part of 'player_screen.dart';

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late VideoPlayerService _playerService;
  bool _showRemaining = false;
  bool _isLongPressing = false;
  bool _isSliderDragging = false;
  double? _sliderDragValue;
  Timer? _longPressTimer;
  Timer? _sleepTimer;
  double? _initialVideoAspectRatio;
  // 本次播放是否已上报「看过」到同步服务，避免 onStop 多次触发导致重复写入。
  bool _didScrobble = false;

  /// 内封字幕流式翻译器（无法整轨下载时边播边译，叠加层按双语排版显示）。
  StreamingSubtitleTranslator? _streamTranslator;

  /// 自动跳过片头/片尾控制器（introdb），左下角按钮随控制栏显隐。
  late final IntroSkipController _introSkip;

  static VideoPlayerService? _activePlayerService;

  static VideoPlayerService? get activePlayerService => _activePlayerService;

  /// 当前活跃的播放页实例，供字幕设置面板触发流式翻译回退。
  static _PlayerScreenState? _activeState;

  /// 供字幕设置面板在整轨翻译失败时回退到流式翻译。
  static void startStreamingTranslateFromPanel(
          TranslationEngine engine, MediaStream stream) =>
      _activeState?._startStreamingTranslate(engine, stream);

  MediaSource? _resolveMediaSource(
    PlaybackInfo playbackInfo, {
    String? preferredMediaSourceId,
  }) {
    final targetSourceId = preferredMediaSourceId ??
        ref.read(selectedMediaSourceProvider) ??
        widget.mediaSourceId;
    return resolvePreferredMediaSource(
      playbackInfo,
      preferredMediaSourceId: targetSourceId,
    );
  }

  void _sanitizeSelectionState(MediaSource? mediaSource) {
    if (mediaSource == null) {
      ref.read(audioTrackProvider.notifier).state = null;
      ref.read(subtitleTrackProvider.notifier).state = null;
      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
      return;
    }

    final audioIndexes = mediaSource.mediaStreams
        .where((stream) => stream.isAudio)
        .map((stream) => stream.index)
        .toSet();
    final subtitleIndexes = mediaSource.mediaStreams
        .where((stream) => stream.isSubtitle)
        .map((stream) => stream.index)
        .toSet();

    final selectedAudioIndex = ref.read(audioTrackProvider);
    if (selectedAudioIndex != null &&
        !audioIndexes.contains(selectedAudioIndex)) {
      ref.read(audioTrackProvider.notifier).state = null;
    }

    final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (selectedSubtitleIndex != null &&
        !subtitleIndexes.contains(selectedSubtitleIndex)) {
      ref.read(subtitleTrackProvider.notifier).state = null;
    }

    final selectedSecondarySubtitleIndex =
        ref.read(secondarySubtitleTrackProvider);
    if (selectedSecondarySubtitleIndex != null &&
        (!subtitleIndexes.contains(selectedSecondarySubtitleIndex) ||
            selectedSecondarySubtitleIndex ==
                ref.read(subtitleTrackProvider))) {
      ref.read(secondarySubtitleTrackProvider.notifier).state = null;
    }
  }

  Rect _computeContentRect(Size containerSize) {
    if (containerSize.width <= 0 || containerSize.height <= 0) {
      return Rect.zero;
    }
    final ratio = _resolveDisplayAspectRatio();
    if (ratio == null || ratio <= 0) {
      return Offset.zero & containerSize;
    }

    final containerRatio = containerSize.width / containerSize.height;
    if (containerRatio > ratio) {
      final contentWidth = containerSize.height * ratio;
      final left = (containerSize.width - contentWidth) / 2;
      return Rect.fromLTWH(left, 0, contentWidth, containerSize.height);
    }

    final contentHeight = containerSize.width / ratio;
    final top = (containerSize.height - contentHeight) / 2;
    return Rect.fromLTWH(0, top, containerSize.width, contentHeight);
  }

  double? _resolveDisplayAspectRatio() {
    final aspectMode = ref.read(aspectRatioProvider);
    if (aspectMode == '全屏') return null;

    switch (aspectMode) {
      case '16:9':
        return 16 / 9;
      case '4:3':
        return 4 / 3;
      case '21:9':
        return 21 / 9;
      case '原始':
      case '自动':
      default:
        break;
    }

    final adapter = _playerService.adapter;
    if (adapter is ExoPlayerAdapter) {
      return adapter.videoAspectRatio ?? _initialVideoAspectRatio;
    }
    if (adapter is NativeMpvPlayerAdapter) {
      return adapter.videoAspectRatio ?? _initialVideoAspectRatio;
    }
    return _initialVideoAspectRatio;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeState = this;
    _introSkip = IntroSkipController(service: ref.read(introSkipServiceProvider));
    _playerService = VideoPlayerService();
    _playerService.addListener(_onPlayerUpdate);

    // Delay initialization when using nativeMpv to allow SurfaceView to be created
    // This ensures the AndroidView is rendered before we try to use the SurfaceView
    final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
    if (coreString == 'nativeMpv') {
      // Use addPostFrameCallback to delay until after the first frame is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initializePlayer();
      });
    } else {
      _initializePlayer();
    }

    // 监听播放器设置变化并下发到播放器
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual(subtitleDelayProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleDelay(next);
      });
      ref.listenManual(audioDelayProvider, (prev, next) {
        if (prev != next) _playerService.setAudioDelay(next);
      });
      ref.listenManual(subtitleSizeProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleSize(next);
      });
      ref.listenManual(subtitlePositionProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitlePosition(next);
      });
      ref.listenManual(subtitleFontProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleFont(next);
      });
      ref.listenManual(subtitleBackgroundProvider, (prev, next) {
        if (prev != next) _playerService.setSubtitleBackground(next);
      });
      ref.listenManual(subtitleTrackProvider, (prev, next) {
        _onSubtitleTrackChanged(prev, next);
      });
      ref.listenManual(secondarySubtitleTrackProvider, (prev, next) {
        _onSecondarySubtitleTrackChanged(next);
      });
      ref.listenManual(currentPlayingItemProvider, (prev, next) {
        if (prev?.id != next?.id) {
          ref.read(loadedDanmakuProvider.notifier).state = [];
        }
      });
    });
  }

  Future<void> _initializePlayer() async {
    final api = ref.read(apiClientProvider);

    // 离线优先：本集已下载完成则用本地文件，且拉取元数据失败时兜底离线播放。
    final downloadManager = ref.read(downloadManagerProvider);
    final localPath = downloadManager.completedFilePath(widget.itemId);
    final hasLocal = localPath != null && await File(localPath).exists();

    MediaItem item;
    PlaybackInfo? playbackInfo;
    try {
      item = await api.media.getItemDetails(widget.itemId);
      playbackInfo = await api.playback.getPlaybackInfo(widget.itemId);
    } catch (e) {
      final record = downloadManager.byItemId(widget.itemId);
      if (!hasLocal || record == null) rethrow;
      // 完全离线：用下载记录还原最简元数据继续播放。
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
          )
        : buildOfflinePlaybackSelection(itemId: widget.itemId);
    final mediaSource = selection.mediaSource;
    _sanitizeSelectionState(mediaSource);
    final videoStream =
        mediaSource?.mediaStreams.where((stream) => stream.isVideo).firstOrNull;
    _initialVideoAspectRatio = (videoStream?.width != null &&
            videoStream?.height != null &&
            videoStream!.width! > 0 &&
            videoStream.height! > 0)
        ? videoStream.width! / videoStream.height!
        : null;

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

    // 本地文件覆盖播放源：用 file:// 形式喂给内核；在线地址作为本地失效时的回退。
    final localFileSource =
        hasLocal ? Uri.file(localPath).toString() : null;
    final effectiveVideoUrl = localFileSource ?? videoUrl;
    final effectiveFallbackUrl = localFileSource != null
        ? (playbackInfo != null ? videoUrl : null)
        : fallbackVideoUrl;

    Duration? startPosition;
    try {
      startPosition = await _resolveResumeStartPosition(api, item);
    } catch (_) {
      startPosition = null;
    }

    ref.read(currentPlayingItemProvider.notifier).state = item;
    ref.read(selectedMediaSourceProvider.notifier).state = mediaSource?.id;

    // 自动跳过片头/片尾：联网识别本集片段（仅剧集，受设置开关控制）。
    unawaited(_introSkip.loadForItem(
      item,
      enabled: ref.read(autoSkipSegmentsProvider),
      fetchItem: (id) => api.media.getItemDetails(id),
    ));

    final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
    final coreType = switch (coreString) {
      'mpv' => PlayerCoreType.mpv,
      'nativeMpv' => PlayerCoreType.nativeMpv,
      _ => PlayerCoreType.exoPlayer,
    };

    final dolbyVisionFix = coreType == PlayerCoreType.mpv
        ? ref.read(mpvDolbyVisionFixProvider)
        : false;
    // nativeMpv 的 libass 内置在 libmpv.so 中，始终启用，不需要开关
    // exoPlayer 需要通过 exoLibass 设置控制
    final useLibass = coreType == PlayerCoreType.exoPlayer
        ? ref.read(exoLibassProvider)
        : false;
    final hardwareDecoding = ref.read(hardwareDecodingProvider);

    final preferredSubtitleLanguage =
        ref.read(preferredSubtitleLanguageProvider);

    // Read gpu-next setting for nativeMpv
    final gpuNextEnabled = ref.read(gpuNextEnabledProvider);

    // Generate a unique surfaceViewId for nativeMpv gpu-next rendering
    // This ID is used to coordinate between Flutter's AndroidView and the native plugin
    final int? surfaceViewId = coreType == PlayerCoreType.nativeMpv
        ? DateTime.now().microsecondsSinceEpoch
        : null;

    // 在 widget 仍 mounted 时捕获 scrobble 所需依赖：onStop 可能在退出
    // 播放页（dispose）后才触发，那时再用 widget 级 ref 会抛
    // "Cannot use ref after the widget was disposed"。
    final watchedThreshold = ref.read(watchedThresholdProvider);
    final syncController = ref.read(syncControllerProvider.notifier);
    _didScrobble = false;
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
      surfaceViewId: surfaceViewId, // Pass for gpu-next rendering
      useGpuNext: gpuNextEnabled, // Pass gpu-next rendering mode
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
        await _maybeScrobbleWatched(
            info, item, api, watchedThreshold, syncController);
      },
    );

    await _playerService.play();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // 加载字幕（内封/外挂）—— 两个内核都支持
    if (mediaSource != null) {
      await _waitForTracksReady();
      await _loadSubtitles(item, mediaSource);
    }

    final audioStreams =
        mediaSource?.mediaStreams.where((stream) => stream.isAudio).toList() ??
            const <MediaStream>[];
    var selectedAudioIndex = ref.read(audioTrackProvider);
    // 「音频选择」正则：用户未手动选轨时，按正则自动挑选匹配的音频轨。
    if (selectedAudioIndex == null && audioStreams.isNotEmpty) {
      final audioMatch =
          matchPreferredStream(audioStreams, ref.read(preferredAudioRegexProvider));
      if (audioMatch != null) {
        selectedAudioIndex = audioMatch.index;
        ref.read(audioTrackProvider.notifier).state = audioMatch.index;
      }
    }
    if (selectedAudioIndex != null) {
      await _applyInitialAudioTrack(audioStreams, selectedAudioIndex);
    }

    final selectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (selectedSubtitleIndex != null) {
      await _onSubtitleTrackChanged(null, selectedSubtitleIndex);
    }

    final selectedSecondarySubtitleIndex =
        ref.read(secondarySubtitleTrackProvider);
    if (selectedSecondarySubtitleIndex != null) {
      await _onSecondarySubtitleTrackChanged(selectedSecondarySubtitleIndex);
    }

    _playerService.setSubtitleSize(ref.read(subtitleSizeProvider));
    _playerService.setSubtitlePosition(ref.read(subtitlePositionProvider));
    _playerService.setSubtitleDelay(ref.read(subtitleDelayProvider));
    _playerService.setSubtitleFont(ref.read(subtitleFontProvider));
    _playerService.setSubtitleBackground(ref.read(subtitleBackgroundProvider));
    _playerService.setAspectRatio(ref.read(aspectRatioProvider));
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
            );
    if (resolvedTicks == null || resolvedTicks <= 0) {
      return null;
    }
    return Duration(milliseconds: (resolvedTicks / 10000).round());
  }

  Future<void> _waitForTracksReady() async {
    for (int i = 0; i < 30; i++) {
      final tracks = _playerService.tracksInfo;
      final subtitleTracks = tracks
          .where((t) =>
              (t['type'] == 'text' || t['type'] == 'bitmap') &&
              t['id'] != 'auto' &&
              t['id'] != 'no')
          .toList();
      if (subtitleTracks.isNotEmpty) return;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    AppLogger().w('Player', '等待轨道就绪超时，继续加载');
  }

  Future<void> _loadSubtitles(MediaItem item, MediaSource mediaSource) async {
    final logger = AppLogger();
    final api = ref.read(apiClientProvider);
    final subtitleStreams =
        mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();

    logger.i('Player', '开始加载字幕 - 可用字幕流: ${subtitleStreams.length} 个');

    if (subtitleStreams.isEmpty) {
      logger.w('Player', '没有可用字幕流');
      return;
    }

    final userSelectedSubtitleIndex = ref.read(subtitleTrackProvider);
    if (userSelectedSubtitleIndex != null) {
      logger.i('Player', '保留用户在详情页中选择的字幕轨道: $userSelectedSubtitleIndex');
      return;
    }

    for (final stream in subtitleStreams) {
      logger.d('Player',
          '字幕流: index=${stream.index}, codec=${stream.codec}, language=${stream.language}, external=${stream.isExternal}, title=${stream.displayTitle}');
    }

    final preferredLang = ref.read(preferredSubtitleLanguageProvider);
    // 「字幕选择」正则优先：命中则用正则结果，否则回退到首选字幕语言。
    final subtitleRegex = ref.read(preferredSubtitleRegexProvider);
    final regexMatched = matchPreferredStream(subtitleStreams, subtitleRegex);
    logger.i('Player',
        '首选字幕语言: $preferredLang, 字幕正则: "$subtitleRegex", 正则命中: ${regexMatched?.index}');

    final target = regexMatched ??
        subtitleStreams.firstWhere(
          (s) => s.language == preferredLang,
          orElse: () => subtitleStreams.first,
        );

    final codec = target.codec?.toLowerCase() ?? 'ass';
    final isExternal = target.isExternal ?? false;
    final targetIndex = target.index;
    final isGraphical = _isGraphicalSubtitleCodec(codec);
    final isAss = _isAssSubtitleCodec(codec);
    logger.i('Player',
        '选择字幕: index=$targetIndex, codec=$codec, language=${target.language}, external=$isExternal, graphical=$isGraphical, isAss=$isAss');

    ref.read(subtitleTrackProvider.notifier).state = targetIndex;

    if (!isExternal) {
      final isExoAss = isAss &&
          !isGraphical &&
          _playerService.coreType == PlayerCoreType.exoPlayer;

      if (isExoAss) {
        logger.i('Player', 'EXO内核: 内封ASS字幕直接走Media3轨道选择，由原生ASS管线处理');
        try {
          await _selectInternalSubtitleEXO(target, preferredLang, logger);
        } catch (e, stackTrace) {
          logger.eWithStack('Player', 'EXO内封ASS轨道选择失败，回退原生选择', e, stackTrace);
          await _selectInternalSubtitleEXO(target, preferredLang, logger);
        }
      } else {
        logger.i('Player', '内封字幕，通过播放器轨道选择');
        try {
          if (_playerService.coreType == PlayerCoreType.mpv ||
              _playerService.coreType == PlayerCoreType.nativeMpv) {
            await _selectInternalSubtitleMPV(target, preferredLang, logger);
          } else {
            await _selectInternalSubtitleEXO(target, preferredLang, logger);
          }
        } catch (e, stackTrace) {
          logger.eWithStack('Player', '内封字幕轨道选择失败', e, stackTrace);
        }
      }
      return;
    }

    try {
      if (_playerService.coreType == PlayerCoreType.mpv ||
          _playerService.coreType == PlayerCoreType.nativeMpv) {
        final embyCodec = _embySubtitleCodec(codec);
        final subUrl = api.playback.getSubtitleStreamUrl(
          widget.itemId,
          mediaSource.id,
          targetIndex,
          embyCodec,
        );
        if (isGraphical) {
          final ext = _subtitleFileExtension(codec, _playerService.coreType);
          final subFile = await _downloadSubtitleToTempFile(
            subtitleUrl: subUrl,
            fileName: 'subtitle_${widget.itemId}_$targetIndex.$ext',
          );
          logger.i('Player', 'MPV内核: 图形外挂字幕使用本地文件: ${subFile.path}');
          if (subFile.existsSync() && await subFile.length() > 0) {
            await _playerService.loadLibassSubtitle(subFile.path);
          }
        } else {
          logger.i('Player', 'MPV内核: 直接加载Emby字幕URL: $subUrl');
          await _playerService.loadLibassSubtitle(subUrl);
        }
        logger.i('Player', 'MPV外挂字幕加载成功');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    '外挂字幕: ${target.language ?? '默认'} (${codec.toUpperCase()})')),
          );
        }
      } else {
        final embyCodec = _embySubtitleCodec(codec);
        final subUrl = api.playback.getSubtitleStreamUrl(
          widget.itemId,
          mediaSource.id,
          targetIndex,
          embyCodec,
        );
        logger.i('Player', 'EXO内核: 下载字幕后再加载: $subUrl');

        final ext = _subtitleFileExtension(codec, _playerService.coreType);
        final subFile = await _prepareSubtitleFileForPlayer(
          subtitleUrl: subUrl,
          fileName: 'subtitle_${widget.itemId}_$targetIndex.$ext',
          codec: codec,
          coreType: _playerService.coreType,
          logger: logger,
        );
        logger.i('Player', '字幕下载完成/使用缓存 (${await subFile.length()} bytes)');

        if (subFile.existsSync() && await subFile.length() > 0) {
          await _playerService.loadLibassSubtitle(subFile.path);
          logger.i('Player', 'EXO外挂字幕加载成功');

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(
                      '外挂字幕: ${target.language ?? '默认'} (${codec.toUpperCase()})')),
            );
          }
        }
      }
    } catch (e, stackTrace) {
      logger.eWithStack('Player', '外挂字幕加载失败', e, stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('字幕加载失败: $e')),
        );
      }
    }
  }

  // 字幕编解码归一收敛到公共 [PlayerSubtitleLoader]（三端共用，逻辑一致）。
  String _embySubtitleCodec(String codec) =>
      PlayerSubtitleLoader.embySubtitleCodec(codec, _playerService.coreType);

  String _subtitleFileExtension(String codec, PlayerCoreType coreType) =>
      PlayerSubtitleLoader.subtitleFileExtension(codec, coreType);

  bool _isAssSubtitleCodec(String codec) =>
      PlayerSubtitleLoader.isAssSubtitleCodec(codec);

  bool _isGraphicalSubtitleCodec(String codec) =>
      PlayerSubtitleLoader.isGraphicalSubtitleCodec(codec);

  Future<File> _prepareSubtitleFileForPlayer({
    required String subtitleUrl,
    required String fileName,
    required String codec,
    required PlayerCoreType coreType,
    required AppLogger logger,
  }) async {
    final sourceFile = await _downloadSubtitleToTempFile(
      subtitleUrl: subtitleUrl,
      fileName: fileName,
    );

    if (coreType != PlayerCoreType.exoPlayer) {
      return sourceFile;
    }

    if (_isAssSubtitleCodec(codec)) {
      final preferLibass = ref.read(exoLibassProvider);
      if (preferLibass) {
        logger.i('Player', 'EXO内核: ASS/SSA 保留原文件，交给Media3原生ASS管线处理');
        return sourceFile;
      }

      final convertedPath = await SubtitleProcessor.convertAssToSrt(
        sourceFile.path,
        outputPath: sourceFile.path.replaceFirst(RegExp(r'\.[^.]+$'), '.srt'),
      );
      logger.i('Player', 'EXO内核: ASS/SSA 已转换为 SRT 兼容播放: $convertedPath');
      return File(convertedPath);
    }

    if (_isGraphicalSubtitleCodec(codec)) {
      logger.w('Player', 'EXO内核: 图形字幕仍依赖 Media3 设备侧解析，若不显示请切换 MPV');
    }

    return sourceFile;
  }

  Future<File> _downloadSubtitleToTempFile({
    required String subtitleUrl,
    required String fileName,
  }) async {
    final server = ref.read(currentServerProvider);
    final tempDir = await getTemporaryDirectory();
    final subFile = File('${tempDir.path}/$fileName');

    if (!subFile.existsSync() || await subFile.length() == 0) {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      if (server?.authToken != null) {
        dio.options.headers['X-Emby-Token'] = server!.authToken;
        dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
      }
      await dio.download(subtitleUrl, subFile.path);
    }

    return subFile;
  }

  Future<void> _selectInternalSubtitleMPV(
      MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks
        .where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' &&
            t['id'] != 'no')
        .toList();
    logger.i('Player', 'MPV 可用字幕轨道: ${subtitleTracks.length} 个');
    for (final track in subtitleTracks) {
      logger.d('Player',
          '  轨道: id=${track['id']}, title=${track['title']}, language=${track['language']}, codec=${track['codec']}, type=${track['type']}');
    }

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'MPV 无可用字幕轨道 - 设置pending等待轨道就绪');
      final mpvAdapter = _playerService.adapter;
      if (mpvAdapter is MpvPlayerAdapter) {
        mpvAdapter.setPendingSubtitle(
          target.codec?.toLowerCase() ?? 'ass',
          title: target.displayTitle ?? target.title,
        );
      }
      await _playerService.selectSubtitleTrack('auto');
      return;
    }

    String? trackId;
    final codec = target.codec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' ||
        codec == 'sup' ||
        codec == 'pgs' ||
        codec == 'dvdsub' ||
        codec == 'vobsub' ||
        codec.contains('hdmv') ||
        codec.contains('pgs');

    if (isGraphical) {
      final bitmapMatches = subtitleTracks
          .where((t) => t['type'] == 'bitmap' || (t['isBitmap'] == true))
          .toList();
      if (bitmapMatches.isNotEmpty) {
        final targetTitle = target.displayTitle ?? target.title;
        if (targetTitle != null && targetTitle.isNotEmpty) {
          for (final t in bitmapMatches) {
            final tTitle = t['title']?.toString() ?? '';
            if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
              trackId = t['id']?.toString();
              break;
            }
          }
        }
        if (trackId == null) {
          final langMatch = bitmapMatches
              .where((t) =>
                  t['language'] == preferredLang ||
                  t['language'] == 'chi' ||
                  t['language'] == 'zh')
              .toList();
          trackId = (langMatch.isNotEmpty ? langMatch : bitmapMatches)
              .first['id']
              ?.toString();
        }
      }
    }

    trackId ??= _matchMpvSubtitleTrack(
      subtitleTracks,
      target.language,
      target.displayTitle ?? target.title,
      target.codec,
      target.index,
    );

    if (trackId != null) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', 'MPV 已选择内封字幕轨道: $trackId');
    } else {
      logger.w('Player', 'MPV 未找到匹配的字幕轨道');
    }
  }

  Future<void> _selectInternalSubtitleEXO(
      MediaStream target, String? preferredLang, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    var subtitleTracks = tracks
        .where((t) => t['type'] == 'text' || t['type'] == 'bitmap')
        .toList();
    logger.i('Player', 'EXO 可用字幕轨道: ${subtitleTracks.length} 个');

    if (subtitleTracks.isEmpty) {
      logger.w('Player', 'EXO 无可用字幕轨道 - 等待轨道就绪后重试');
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 300));
        final retryTracks = _playerService.tracksInfo
            .where((t) => t['type'] == 'text' || t['type'] == 'bitmap')
            .toList();
        if (retryTracks.isNotEmpty) {
          subtitleTracks = retryTracks;
          logger.i('Player', 'EXO 轨道就绪 - 可用字幕轨道: ${subtitleTracks.length} 个');
          break;
        }
      }
      if (subtitleTracks.isEmpty) {
        logger.w('Player', 'EXO 等待轨道超时，放弃字幕选择');
        return;
      }
    }

    final codec = target.codec?.toLowerCase() ?? '';
    final isGraphical = codec == 'pgssub' ||
        codec == 'sup' ||
        codec == 'pgs' ||
        codec == 'dvdsub' ||
        codec == 'vobsub' ||
        codec.contains('hdmv') ||
        codec.contains('pgs');

    String? trackId;

    if (isGraphical) {
      final bitmapTracks = subtitleTracks
          .where((t) => t['type'] == 'bitmap' || t['isBitmap'] == true)
          .toList();
      if (bitmapTracks.isNotEmpty) {
        final targetTitle = target.displayTitle ?? target.title;
        if (targetTitle != null && targetTitle.isNotEmpty) {
          for (final t in bitmapTracks) {
            final tTitle =
                t['title']?.toString() ?? t['label']?.toString() ?? '';
            if (tTitle.isNotEmpty && _titlesMatch(targetTitle, tTitle)) {
              trackId = t['id']?.toString();
              break;
            }
          }
        }
        if (trackId == null) {
          final langMatch = bitmapTracks
              .where((t) =>
                  t['language'] == preferredLang ||
                  t['language'] == 'chi' ||
                  t['language'] == 'zh')
              .toList();
          final targetList = langMatch.isNotEmpty ? langMatch : bitmapTracks;
          trackId = targetList.first['id']?.toString();
        }
      }
    }

    trackId ??= _matchExoSubtitleTrack(
      subtitleTracks,
      target.language,
      target.displayTitle ?? target.title,
      target.codec,
      target.index,
    );

    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', 'EXO 已选择内封字幕轨道: id=$trackId');

      // PGS 字幕提示：显示能力依赖设备侧 Media3 解码输出，异常时建议切换 MPV
      if (isGraphical && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PGS字幕加载中，如无法显示请切换MPV内核'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  // 内封字幕匹配统一委托公共 [PlayerSubtitleLoader]（三端一致、单一来源）。
  String? _matchMpvSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) =>
      PlayerSubtitleLoader.matchMpvSubtitleTrack(
          subtitleTracks, targetLang, targetTitle, targetCodec, targetStreamIndex);

  String? _matchMpvSecondarySubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    MediaStream target,
    String? primaryTrackId,
  ) =>
      PlayerSubtitleLoader.matchMpvSecondarySubtitleTrack(
          subtitleTracks, target, primaryTrackId);

  String? _matchExoSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) =>
      PlayerSubtitleLoader.matchExoSubtitleTrack(
          subtitleTracks, targetLang, targetTitle, targetCodec, targetStreamIndex);

  bool _titlesMatch(String embyTitle, String playerTitle) =>
      PlayerSubtitleLoader.titlesMatch(embyTitle, playerTitle);

  Future<void> _selectInternalSubtitleViaTrack(
      MediaStream target, int next, AppLogger logger) async {
    final tracks = _playerService.tracksInfo;
    final subtitleTracks = tracks
        .where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' &&
            t['id'] != 'no')
        .toList();

    String? trackId;
    final targetDisplayTitle = target.displayTitle ?? target.title;

    if (_playerService.coreType == PlayerCoreType.mpv ||
        _playerService.coreType == PlayerCoreType.nativeMpv) {
      trackId = _matchMpvSubtitleTrack(
        subtitleTracks,
        target.language,
        targetDisplayTitle,
        target.codec,
        next,
      );
    } else {
      trackId = _matchExoSubtitleTrack(
        subtitleTracks,
        target.language,
        targetDisplayTitle,
        target.codec,
        next,
      );
    }

    if (trackId != null) {
      await _playerService.selectSubtitleTrack(trackId);
      logger.i('Player', '切换字幕轨道: id=$trackId');
    } else {
      logger.w('Player',
          '切换字幕轨道: 未找到匹配轨道, targetIndex=$next, lang=${target.language}, title=$targetDisplayTitle');
    }
  }

  /// 内封字幕无法整轨下载时，启动流式翻译（边播边译，叠加层按双语排版显示）。
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
      if (msg != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('流式翻译引擎错误: $msg')),
        );
      }
    });
    _streamTranslator = translator;
    translator.start(_playerService);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该字幕为内封、无法整轨下载，已改为流式翻译（边播边译）')),
      );
    }
  }

  void _stopStreamingTranslate() {
    if (_streamTranslator == null) return;
    _streamTranslator?.stop();
    _streamTranslator = null;
    if (mounted) setState(() {});
  }

  Future<void> _onSubtitleTrackChanged(int? prev, int? next) async {
    // 用户切换/关闭字幕轨 → 结束流式翻译：清掉译文叠加层并恢复原文字幕，
    // 否则旧译文叠加层会与新选中字幕叠加，造成双字幕。
    if (_streamTranslator != null) {
      _stopStreamingTranslate();
    }
    if (prev == next || next == null) {
      if (next == null && prev != null) {
        await _playerService.deselectSubtitleTrack();
      }
      return;
    }

    final item = ref.read(currentPlayingItemProvider);
    if (item == null) return;

    final api = ref.read(apiClientProvider);
    final logger = AppLogger();

    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = _resolveMediaSource(playbackInfo);
      if (mediaSource == null) return;

      final subtitleStreams =
          mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = _isGraphicalSubtitleCodec(codec);

      if (!isExternal) {
        final isAss = _isAssSubtitleCodec(codec);
        final isExoAss = _playerService.coreType == PlayerCoreType.exoPlayer &&
            isAss &&
            !isGraphical;

        if (isExoAss) {
          try {
            logger.i('Player', 'EXO内核: 内封ASS切换直接走Media3轨道选择');
            await _selectInternalSubtitleViaTrack(target, next, logger);
          } catch (e, stackTrace) {
            logger.eWithStack('Player', 'EXO内封ASS切换失败，回退原生轨道选择', e, stackTrace);
            await _selectInternalSubtitleViaTrack(target, next, logger);
          }
        } else {
          await _selectInternalSubtitleViaTrack(target, next, logger);
        }
      } else {
        final embyCodec = _embySubtitleCodec(codec);
        final isGraphicalExternal = _isGraphicalSubtitleCodec(codec);

        if (_playerService.coreType == PlayerCoreType.mpv ||
            _playerService.coreType == PlayerCoreType.nativeMpv ||
            isGraphicalExternal) {
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );

          await _playerService.deselectSubtitleTrack();

          if (isGraphicalExternal) {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );
            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          } else {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );

            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          }
        } else {
          final subUrl = api.playback.getSubtitleStreamUrl(
            item.id,
            mediaSource.id,
            target.index,
            embyCodec,
          );
          if (_playerService.coreType == PlayerCoreType.exoPlayer) {
            final ext = _subtitleFileExtension(codec, _playerService.coreType);
            final subFile = await _prepareSubtitleFileForPlayer(
              subtitleUrl: subUrl,
              fileName: 'subtitle_${item.id}_${target.index}.$ext',
              codec: codec,
              coreType: _playerService.coreType,
              logger: logger,
            );

            if (subFile.existsSync() && await subFile.length() > 0) {
              await _playerService.loadLibassSubtitle(subFile.path);
            }
          } else {
            await _playerService.loadLibassSubtitle(subUrl);
          }
        }
      }
    } catch (e) {
      logger.e('Player', '切换字幕轨道失败: $e');
    }
  }

  Future<void> _onSecondarySubtitleTrackChanged(int? next) async {
    if (next == null) {
      await _playerService.deselectSecondarySubtitle();
      return;
    }

    final item = ref.read(currentPlayingItemProvider);
    if (item == null) return;

    final api = ref.read(apiClientProvider);
    final server = ref.read(currentServerProvider);
    final logger = AppLogger();

    if (_playerService.coreType != PlayerCoreType.mpv &&
        _playerService.coreType != PlayerCoreType.nativeMpv) {
      logger.w('Player', '次字幕仅支持MPV内核');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('次字幕功能需要MPV内核，请在设置中切换')),
        );
      }
      return;
    }

    try {
      final playbackInfo = await api.playback.getPlaybackInfo(item.id);
      final mediaSource = _resolveMediaSource(playbackInfo);
      if (mediaSource == null) return;

      final subtitleStreams =
          mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
      final target = subtitleStreams.where((s) => s.index == next).firstOrNull;
      if (target == null) return;

      final isExternal = target.isExternal ?? false;
      final codec = target.codec?.toLowerCase() ?? 'ass';
      final isGraphical = codec == 'pgssub' ||
          codec == 'sup' ||
          codec == 'pgs' ||
          codec.contains('hdmv') ||
          codec.contains('pgs');

      if (isGraphical) {
        logger.w('Player', '次字幕: 图形字幕暂不支持作为次字幕');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('图形字幕(PGS/SUP)暂不支持作为次字幕')),
          );
        }
        return;
      }

      if (!isExternal) {
        logger.i('Player', '次字幕: 内封字幕，通过MPV轨道ID直接设置');
        final tracks = _playerService.tracksInfo;
        final subtitleTracks = tracks
            .where((t) =>
                (t['type'] == 'text' || t['type'] == 'bitmap') &&
                t['id'] != 'auto' &&
                t['id'] != 'no')
            .toList();
        final currentPrimaryIndex = ref.read(subtitleTrackProvider);
        String? primaryTrackId;
        if (currentPrimaryIndex != null) {
          final primaryTarget = subtitleStreams
              .where((s) => s.index == currentPrimaryIndex)
              .firstOrNull;
          if (primaryTarget != null) {
            primaryTrackId = _matchMpvSubtitleTrack(
              subtitleTracks,
              primaryTarget.language,
              primaryTarget.displayTitle ?? primaryTarget.title,
              primaryTarget.codec,
              primaryTarget.index,
            );
          }
        }

        final trackId = _matchMpvSecondarySubtitleTrack(
          subtitleTracks,
          target,
          primaryTrackId,
        );

        if (trackId != null && trackId.isNotEmpty) {
          await _playerService.selectSecondarySubtitleTrack(trackId);
          logger.i('Player', '内封次字幕已设置: trackId=$trackId');
        } else {
          logger.w('Player', '未找到匹配的MPV字幕轨道');
        }
        return;
      }

      final embyCodec = _embySubtitleCodec(codec);
      final subUrl = api.playback.getSubtitleStreamUrl(
        item.id,
        mediaSource.id,
        target.index,
        embyCodec,
      );

      final tempDir = await getTemporaryDirectory();
      final ext = _subtitleFileExtension(codec, _playerService.coreType);
      final subFile = File(
          '${tempDir.path}/secondary_subtitle_${item.id}_${target.index}.$ext');

      if (!subFile.existsSync() || await subFile.length() == 0) {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ));
        if (server?.authToken != null) {
          dio.options.headers['X-Emby-Token'] = server!.authToken;
          dio.options.headers['X-MediaBrowser-Token'] = server.authToken;
        }
        await dio.download(subUrl, subFile.path);
      }

      if (subFile.existsSync() && await subFile.length() > 0) {
        await _playerService.loadSecondarySubtitle(subFile.path);
        logger.i('Player', '次字幕加载成功: ${subFile.path}');
      }
    } catch (e) {
      logger.e('Player', '加载次字幕失败: $e');
    }
  }

  void _onPlayerUpdate() {
    setState(() {});
    _checkSkipOpening();
    _introSkip.onPosition(_playerService.position);
  }

  /// 点按「跳过片头/片尾」：片尾且开启自动连播则切下一集，否则 seek 到段末。
  void _onIntroSkipPressed(SkipPrompt prompt) {
    if (prompt.kind == SkipKind.outro &&
        ref.read(autoPlayNextProvider) &&
        ref.read(currentPlayingItemProvider)?.seriesId != null) {
      _playNext();
    } else {
      _playerService.seekTo(prompt.target);
      _introSkip.onPosition(prompt.target); // 立即收起按钮
    }
  }

  bool _showSkipButton = false;
  Timer? _skipButtonTimer;

  void _checkSkipOpening() {
    final openingStart = ref.read(skipOpeningStartProvider);
    final openingEnd = ref.read(skipOpeningEndProvider);
    final autoSkip = ref.read(skipAutoModeProvider);
    if (openingStart <= 0 || openingEnd <= 0 || openingEnd <= openingStart) {
      return;
    }

    final pos = _playerService.position.inSeconds;
    final inOpening = pos >= openingStart && pos < openingEnd;

    if (inOpening && autoSkip) {
      _playerService.seekTo(Duration(seconds: openingEnd));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已自动跳过片头')),
      );
    } else if (inOpening && !_showSkipButton) {
      setState(() => _showSkipButton = true);
      _skipButtonTimer?.cancel();
      _skipButtonTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() => _showSkipButton = false);
        }
      });
    } else if (!inOpening && _showSkipButton) {
      setState(() => _showSkipButton = false);
      _skipButtonTimer?.cancel();
    }
  }

  void _onSkipOpeningPressed() {
    final openingEnd = ref.read(skipOpeningEndProvider);
    _playerService.seekTo(Duration(seconds: openingEnd));
    setState(() => _showSkipButton = false);
    _skipButtonTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _playerService.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamTranslator?.stop();
    _streamTranslator = null;
    _introSkip.dispose();
    if (_activeState == this) _activeState = null;
    _activePlayerService = null;
    _playerService.removeListener(_onPlayerUpdate);
    _playerService.dispose();
    _longPressTimer?.cancel();
    _skipButtonTimer?.cancel();
    _sleepTimer?.cancel();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(currentPlayingItemProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _playerService.toggleControls,
                onDoubleTapDown: _onDoubleTapDown,
                onLongPressStart: (_) => _onLongPressStart(),
                onLongPressEnd: (_) => _onLongPressEnd(),
                onHorizontalDragStart: (details) =>
                    _playerService.onDragStart(details, constraints),
                onHorizontalDragUpdate: (details) =>
                    _playerService.onDragUpdate(details, constraints),
                onHorizontalDragEnd: _playerService.onDragEnd,
                onVerticalDragStart: (details) =>
                    _playerService.onDragStart(details, constraints),
                onVerticalDragUpdate: (details) =>
                    _playerService.onDragUpdate(details, constraints),
                onVerticalDragEnd: _playerService.onDragEnd,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildVideoArea(),
                    // 流式翻译叠加层（按双语排版显示原文/译文，位于控制条之下）。
                    if (_streamTranslator != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 64,
                        child: IgnorePointer(
                          child: ValueListenableBuilder<String>(
                            valueListenable: _streamTranslator!.displayText,
                            builder: (context, text, _) {
                              if (text.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Center(
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 24),
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
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                      shadows: [
                                        Shadow(
                                            blurRadius: 4, color: Colors.black),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    if (_playerService.isBuffering)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    if (_playerService.hasError)
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline,
                                  color: Colors.white, size: 48),
                              const SizedBox(height: 16),
                              Text(
                                friendlyPlaybackError(
                                    _playerService.errorMessage),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                kPlaybackErrorFeedbackHint,
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.65),
                                    fontSize: 11.5,
                                    height: 1.6),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),
                              const SelectableText(
                                kFeedbackChannelUrl,
                                style: TextStyle(
                                    color: Color(0xFF5B8DEF),
                                    fontSize: 12.5,
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
                    if (_playerService.isDragging &&
                        !_playerService.isScrubbingPosition)
                      _buildGestureIndicator(),
                    if (_isLongPressing) _buildLongPressIndicator(),
                    if (_playerService.isDragging &&
                        _playerService.isScrubbingPosition)
                      _buildDragIndicator(),
                    if (_showSkipButton)
                      Positioned(
                        top: 100,
                        right: 24,
                        child: ElevatedButton.icon(
                          onPressed: _onSkipOpeningPressed,
                          icon: const Icon(Icons.skip_next, size: 18),
                          label: const Text('跳过片头'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.7),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_playerService.showControls && !_playerService.isLocked)
                Positioned.fill(child: _buildControlsOverlay(item)),
              if (_playerService.isLocked)
                Positioned(
                  top: 40,
                  left: 16,
                  child: IconButton(
                    icon: const Icon(Icons.lock, color: Colors.white),
                    onPressed: _playerService.toggleLock,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVideoArea() {
    final videoWidget = _playerService.buildVideo();
    final danmakuItems = ref.watch(loadedDanmakuProvider);
    final danmakuEnabled = ref.watch(danmakuEnabledProvider);
    final danmakuOpacity = ref.watch(danmakuOpacityProvider);
    final danmakuFontSize = ref.watch(danmakuFontSizeProvider);
    final danmakuSpeed = ref.watch(danmakuSpeedProvider);
    final danmakuDensity = ref.watch(danmakuDensityProvider);
    final danmakuDelay = ref.watch(danmakuDelayProvider);
    final danmakuDisplayArea = ref.watch(danmakuDisplayAreaProvider);
    final danmakuStroke = ref.watch(danmakuStrokeProvider);
    final danmakuFontFamily = ref.watch(customDanmakuFontPathProvider).isEmpty
        ? null
        : FontService.danmakuFontFamily;

    if (_playerService.coreType != PlayerCoreType.exoPlayer) {
      final overlays = <Widget>[];
      if (danmakuEnabled && danmakuItems.isNotEmpty) {
        final delayedPosition = _playerService.position -
            Duration(milliseconds: (danmakuDelay * 1000).round());
        overlays.add(
          Positioned.fill(
            child: DanmakuOverlay(
              items: danmakuItems,
              position: delayedPosition,
              isPlaying: _playerService.isPlaying,
              opacity: danmakuOpacity,
              fontSizeFactor: danmakuFontSize,
              speedFactor: danmakuSpeed,
              densityFactor: danmakuDensity,
              displayArea: danmakuDisplayArea,
              stroke: danmakuStroke,
              fontFamily: danmakuFontFamily,
            ),
          ),
        );
      }
      if (overlays.isEmpty) return videoWidget;
      return Stack(fit: StackFit.expand, children: [videoWidget, ...overlays]);
    }

    final adapter = _playerService.adapter;
    if (adapter is! ExoPlayerAdapter) {
      return videoWidget;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentRect = _computeContentRect(
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        final delayedPosition = _playerService.position -
            Duration(milliseconds: (danmakuDelay * 1000).round());

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: contentRect,
              child: videoWidget,
            ),
            if (danmakuEnabled && danmakuItems.isNotEmpty)
              Positioned.fromRect(
                rect: contentRect,
                child: DanmakuOverlay(
                  items: danmakuItems,
                  position: delayedPosition,
                  isPlaying: _playerService.isPlaying,
                  opacity: danmakuOpacity,
                  fontSizeFactor: danmakuFontSize,
                  speedFactor: danmakuSpeed,
                  densityFactor: danmakuDensity,
                  displayArea: danmakuDisplayArea,
                  stroke: danmakuStroke,
                  fontFamily: danmakuFontFamily,
                ),
              ),
            if (contentRect == Rect.zero)
              Positioned.fill(
                child: IgnorePointer(
                  child: videoWidget,
                ),
              ),
          ],
        );
      },
    );
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_playerService.isLocked) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    if (tapX < screenWidth / 3) {
      _playerService
          .seekBy(Duration(seconds: -ref.read(skipForwardStepProvider)));
    } else if (tapX > screenWidth * 2 / 3) {
      _playerService
          .seekBy(Duration(seconds: ref.read(skipForwardStepProvider)));
    } else {
      _playerService.togglePlay();
    }
  }

  void _onLongPressStart() {
    if (_playerService.isLocked) return;
    setState(() => _isLongPressing = true);
    _longPressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isLongPressing) {
        _playerService.setSpeed(ref.read(longPressSpeedProvider));
      }
    });
  }

  void _onLongPressEnd() {
    setState(() => _isLongPressing = false);
    _longPressTimer?.cancel();
    _playerService.setSpeed(ref.read(defaultPlaybackSpeedProvider));
  }

  Widget _buildGestureIndicator() {
    final screenWidth = MediaQuery.of(context).size.width;
    final dragX = _playerService.dragStartX;

    String label;
    IconData icon;
    double value;

    if (dragX < screenWidth / 2) {
      // 左侧：亮度
      label = '亮度';
      icon = Icons.brightness_high;
      value = _playerService.brightness;
    } else {
      // 右侧：音量
      label = '音量';
      icon = Icons.volume_up;
      value = _playerService.volume;
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 100,
              child: LinearProgressIndicator(
                value: value,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(value * 100).toInt()}%',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLongPressIndicator() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fast_forward, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              '${ref.read(longPressSpeedProvider)}x 快进中',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(MediaItem? item) {
    // 上下渐变蒙版：让顶/底栏文字在任意画面上都清晰，中间画面不被遮。
    return Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x99000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xB3000000),
                ],
                stops: [0.0, 0.22, 0.7, 1.0],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              _buildTopBar(item),
              Expanded(child: _buildCenterControls()),
              _buildProgressBar(),
              _buildBottomBar(item),
            ],
          ),
        ),
        // 自动跳过片头/片尾按钮：左下角、底栏之上，随控制栏一并显隐。
        Positioned(
          left: 16,
          bottom: 78,
          child: SafeArea(
            child: ValueListenableBuilder<SkipPrompt?>(
              valueListenable: _introSkip.prompt,
              builder: (context, prompt, _) {
                if (prompt == null) return const SizedBox.shrink();
                return _IntroSkipButton(
                  label: prompt.label,
                  onTap: () => _onIntroSkipPressed(prompt),
                );
              },
            ),
          ),
        ),
      ],
    ).animate().fadeIn(duration: AppMotion.fast);
  }

  Widget _buildTopBar(MediaItem? item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
            iconSize: 20,
            tooltip: '返回',
            onPressed: () => context.pop(),
          ),
          // 标题：只占左侧；超长才匀速滚动，右侧留给操作按钮。
          Expanded(
            child: _MarqueeText(
              text: item?.name ?? widget.itemId,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: Icon(
              _playerService.isLocked ? Icons.lock : Icons.lock_open,
              color: Colors.white,
            ),
            iconSize: 20,
            tooltip: '锁定',
            onPressed: _playerService.toggleLock,
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, color: Colors.white),
            iconSize: 22,
            tooltip: '更多',
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }

  /// 中央主控件（拇指区）：上一集 · 快退 · 播放/暂停 · 快进 · 下一集。
  Widget _buildCenterControls() {
    final isPlaying = _playerService.isPlaying;
    final step = ref.read(skipForwardStepProvider);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CenterControlButton(
          icon: Icons.skip_previous_rounded,
          size: 30,
          tooltip: '上一集',
          onTap: _playPrevious,
        ),
        _CenterControlButton(
          icon: Icons.replay_10_rounded,
          size: 38,
          tooltip: '快退 ${step}s',
          onTap: () => _playerService.seekBy(Duration(seconds: -step)),
        ),
        _CenterControlButton(
          icon: isPlaying
              ? Icons.pause_circle_filled_rounded
              : Icons.play_circle_fill_rounded,
          size: 64,
          tooltip: '播放/暂停',
          onTap: _playerService.togglePlay,
        ),
        _CenterControlButton(
          icon: Icons.forward_10_rounded,
          size: 38,
          tooltip: '快进 ${step}s',
          onTap: () => _playerService.seekBy(Duration(seconds: step)),
        ),
        _CenterControlButton(
          icon: Icons.skip_next_rounded,
          size: 30,
          tooltip: '下一集',
          onTap: _playNext,
        ),
      ],
    );
  }

  /// 切换硬解/软解：改 provider 后重建播放器并恢复进度。
  /// （原先内联在顶栏按钮里，重构后挪进「更多」菜单，逻辑保持一致。）
  Future<void> _toggleHardwareDecoding() async {
    final current = ref.read(hardwareDecodingProvider);
    ref.read(hardwareDecodingProvider.notifier).state = !current;
    final savedPosition = _playerService.position;
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer();
    if (savedPosition > Duration.zero) {
      await _playerService.seekTo(savedPosition);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(!current ? '已切换硬件解码' : '已切换软件解码')),
      );
    }
  }

  /// 开启 Anime4K 超分（仅 mpv 内核）。
  Future<void> _applySuperResolution() async {
    await _playerService.applySuperResolution(true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已开启 Anime4K 超分辨率')),
      );
    }
  }

  /// 倍速选择面板（替代原先顶栏的 +/- 微调；长按手势仍可临时倍速）。
  void _showSpeedDialog() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    final current = _playerService.speed;
    _showRightPanel(
      title: '播放速度',
      children: [
        for (final s in speeds)
          PanelOptionTile(
            label: s == 1.0 ? '正常 (1.0x)' : '${s}x',
            selected: (current - s).abs() < 0.01,
            onTap: () {
              _playerService.setSpeed(s);
              Navigator.of(context).maybePop();
            },
          ),
      ],
    );
  }

  Widget _buildProgressBar() {
    final effectiveProgress = _isSliderDragging
        ? (_sliderDragValue ?? _playerService.progress).clamp(0.0, 1.0)
        : _playerService.progress.clamp(0.0, 1.0);
    final effectivePosition = Duration(
      milliseconds:
          (effectiveProgress * _playerService.duration.inMilliseconds).round(),
    );
    final currentTime = _formatDuration(effectivePosition);
    final remaining = _playerService.duration - effectivePosition;
    final remainingTime = _formatDuration(
      remaining.isNegative ? Duration.zero : remaining,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _showRemaining = !_showRemaining),
                child: Text(
                  _showRemaining ? '-$remainingTime' : currentTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF5B8DEF),
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    thumbColor: const Color(0xFF5B8DEF),
                    overlayColor:
                        const Color(0xFF5B8DEF).withValues(alpha: 0.2),
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: effectiveProgress,
                    onChanged: (value) {
                      setState(() {
                        _isSliderDragging = true;
                        _sliderDragValue = value;
                      });
                    },
                    onChangeEnd: (value) async {
                      final position = Duration(
                        milliseconds:
                            (value * _playerService.duration.inMilliseconds)
                                .round(),
                      );
                      setState(() {
                        _isSliderDragging = false;
                        _sliderDragValue = null;
                      });
                      await _playerService.seekTo(position);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _formatDuration(_playerService.duration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底栏：只保留**次级功能**（选集 / 字幕 / 音轨 / 弹幕）+ 全屏方向切换。
  /// 主控件（播放、快进退、上下集）已移到中央拇指区；截图/超分/硬解等进「更多」。
  Widget _buildBottomBar(MediaItem? item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BottomBarAction(
            icon: Icons.playlist_play_rounded,
            label: '选集',
            onTap: () => _showEpisodeSelector(item),
          ),
          _BottomBarAction(
            icon: Icons.subtitles_outlined,
            label: '字幕',
            onTap: _showSubtitleSettings,
          ),
          _BottomBarAction(
            icon: Icons.audiotrack_rounded,
            label: '音轨',
            onTap: _showAudioSettings,
          ),
          _BottomBarAction(
            icon: Icons.chat_bubble_outline_rounded,
            label: '弹幕',
            onTap: _showDanmakuSettings,
          ),
          _BottomBarAction(
            icon: Icons.screen_rotation_rounded,
            label: '旋转',
            onTap: _toggleOrientation,
          ),
        ],
      ),
    );
  }

  Widget _buildDragIndicator() {
    final direction = _playerService.dragDirection;
    final isForward = direction == 1;
    final isBackward = direction == -1;
    final previewPosition = _playerService.isScrubbingPosition
        ? _playerService.dragPreviewPosition
        : _playerService.position;

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isForward
                  ? Icons.fast_forward
                  : isBackward
                      ? Icons.fast_rewind
                      : Icons.drag_handle,
              color: Colors.white,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              _formatDuration(previewPosition),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 播放停止时判断是否「看完」（进度达到设置里的统一观看阈值），是则上报到
  /// 已连接的同步服务。onStop 可能因显式停止 + dispose 触发两次，用 [_didScrobble] 去重。
  Future<void> _maybeScrobbleWatched(
    PlaybackStopInfo info,
    MediaItem item,
    ApiClientFactory api,
    int thresholdPercent,
    SyncController syncController,
  ) async {
    if (_didScrobble) return;
    final runtime = item.runTimeTicks;
    if (runtime == null || runtime <= 0) return;
    // 「观看阈值」（linplayer_watched_threshold，75~95，默认90）已在
    // _initializePlayer 里 widget 仍 mounted 时捕获，避免 dispose 后用 ref。
    if (info.positionTicks / runtime < thresholdPercent / 100) return;
    _didScrobble = true;

    // 剧集需要所属剧的 ProviderIds 才能给 Bangumi 取 subject_id。
    Map<String, String>? seriesProviderIds;
    if (item.type == 'Episode' && item.seriesId != null) {
      try {
        final series = await api.media.getItemDetails(item.seriesId!);
        seriesProviderIds = series.providerIds;
      } catch (_) {}
    }

    try {
      await syncController.scrobbleWatched(item,
          seriesProviderIds: seriesProviderIds);
    } catch (_) {}
  }

  Future<void> _playPrevious() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId != null) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
              currentItem!.seriesId!,
              seasonId: currentItem.seasonId,
            );
        final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
        if (currentIndex > 0) {
          final prevEpisode = episodes[currentIndex - 1];
          if (mounted) {
            context.replace('/player/${prevEpisode.id}');
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
  }

  Future<void> _playNext() async {
    final currentItem = ref.read(currentPlayingItemProvider);
    if (currentItem?.seriesId != null) {
      try {
        final episodes = await ref.read(apiClientProvider).media.getEpisodes(
              currentItem!.seriesId!,
              seasonId: currentItem.seasonId,
            );
        final currentIndex = episodes.indexWhere((e) => e.id == currentItem.id);
        if (currentIndex >= 0 && currentIndex < episodes.length - 1) {
          final nextEpisode = episodes[currentIndex + 1];
          if (mounted) {
            context.replace('/player/${nextEpisode.id}');
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
  }

  void _showMoreMenu() {
    void go(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
    final isMpv = coreString == 'mpv' || coreString == 'nativeMpv';
    final hwOn = ref.read(hardwareDecodingProvider);

    _showRightPanel(
      title: '更多选项',
      children: [
        const PanelSectionTitle('播放'),
        PanelOptionTile(
          label: '播放速度',
          subtitle: '当前 ${_playerService.speed}x',
          leading: const Icon(Icons.speed_rounded),
          selected: false,
          onTap: () => go(_showSpeedDialog),
        ),
        PanelOptionTile(
          label: '跳过片头/片尾',
          leading: const Icon(Icons.fast_forward_rounded),
          selected: false,
          onTap: () => go(_showSkipDialog),
        ),
        PanelOptionTile(
          label: '画面比例',
          leading: const Icon(Icons.aspect_ratio),
          selected: false,
          onTap: () => go(_showAspectRatioDialog),
        ),
        const PanelSectionTitle('画质 / 解码'),
        PanelOptionTile(
          label: hwOn ? '硬件解码（点击切软解）' : '软件解码（点击切硬解）',
          leading: Icon(hwOn ? Icons.memory : Icons.slow_motion_video),
          selected: false,
          onTap: () => go(_toggleHardwareDecoding),
        ),
        if (isMpv)
          PanelOptionTile(
            label: '超分辨率 (Anime4K)',
            leading: const Icon(Icons.hd_rounded),
            selected: false,
            onTap: () => go(_applySuperResolution),
          ),
        PanelOptionTile(
          label: '截图',
          leading: const Icon(Icons.camera_alt_outlined),
          selected: false,
          onTap: () => go(_takeScreenshot),
        ),
        const PanelSectionTitle('弹幕 / 其它'),
        PanelOptionTile(
          label: '搜索弹幕',
          leading: const Icon(Icons.search_rounded),
          selected: false,
          onTap: () => go(_showDanmakuSearch),
        ),
        PanelOptionTile(
          label: '线路切换',
          leading: const Icon(Icons.route),
          selected: false,
          onTap: () => go(_showLineSelector),
        ),
        PanelOptionTile(
          label: '定时关闭',
          leading: const Icon(Icons.timer),
          selected: false,
          onTap: () => go(_showTimerDialog),
        ),
        if (!isDesktopPlatform)
          PanelOptionTile(
            label: '内核切换',
            leading: const Icon(Icons.memory),
            selected: false,
            onTap: () => go(_showCoreSwitchDialog),
          ),
        PanelOptionTile(
          label: '统计信息',
          leading: const Icon(Icons.analytics),
          selected: false,
          onTap: () => go(_showStats),
        ),
      ],
    );
  }

  void _showRightPanel(
      {required String title,
      required List<Widget> children,
      double? width}) {
    // 统一走共享的右侧设置面板（透明遮罩 + 局部毛玻璃 + 宽度≤1/3 + 深浅自适应）。
    showPlayerSettingsPanel(
      context: context,
      title: title,
      width: width,
      children: children,
    );
  }

  void _showSkipDialog() {
    _showRightPanel(
      title: '跳过片头',
      children: [
        _SkipDialog(currentPosition: _playerService.position),
      ],
    );
  }

  void _toggleOrientation() {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.portrait) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  Future<void> _takeScreenshot() async {
    try {
      final data = await _playerService.screenshot();
      if (!mounted) return;
      if (data != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图已保存')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('截图功能暂不支持当前播放器内核')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('截图失败: $e')),
      );
    }
  }

  void _showStats() {
    final colors = PlayerPanelColors.resolve(context);
    Widget statRow(String label, String value) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 14)),
            ),
            Text(value,
                style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }

    _showRightPanel(
      title: '播放统计',
      children: [
        statRow('播放速度', '${_playerService.speed}x'),
        statRow('音量', '${(_playerService.volume * 100).toInt()}%'),
        statRow('亮度', '${(_playerService.brightness * 100).toInt()}%'),
        statRow('播放状态', _playerService.isPlaying ? '播放中' : '已暂停'),
        statRow('当前位置',
            '${_formatDuration(_playerService.position)} / ${_formatDuration(_playerService.duration)}'),
      ],
    );
  }

  void _showDanmakuSettings() {
    _showRightPanel(
      title: '弹幕设置',
      children: [
        const _DanmakuSettingsContent(),
      ],
    );
  }

  void _showDanmakuSearch() {
    final item = ref.read(currentPlayingItemProvider);
    _showRightPanel(
      title: '搜索弹幕',
      children: [
        DanmakuSearchContent(item: item),
      ],
    );
  }

  void _showSubtitleSettings() {
    _showRightPanel(
      title: '字幕设置',
      children: [
        const _SubtitleSettingsContent(),
      ],
    );
  }

  Future<void> _applyInitialAudioTrack(
      List<MediaStream> audioStreams, int selectedIndex) async {
    final tracks = _playerService.tracksInfo;
    final audioTracks =
        tracks.where((track) => track['type'] == 'audio').toList();
    final audioPosition =
        audioStreams.indexWhere((stream) => stream.index == selectedIndex);
    if (audioPosition < 0 || audioPosition >= audioTracks.length) {
      return;
    }
    final trackId = audioTracks[audioPosition]['id']?.toString();
    if (trackId != null && trackId.isNotEmpty) {
      await _playerService.selectAudioTrack(trackId);
    }
  }

  void _showAudioSettings() {
    _showRightPanel(
      title: '音频设置',
      children: [
        const _AudioSettingsContent(),
      ],
    );
  }

  void _showEpisodeSelector(MediaItem? item) {
    if (item?.seriesId == null) return;

    _showRightPanel(
      title: '选集',
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: _EpisodeSelectorContent(
            seriesId: item!.seriesId!,
            currentEpisodeId: item.id,
            currentMediaSourceId: ref.read(selectedMediaSourceProvider),
          ),
        ),
      ],
    );
  }

  void _showTimerDialog() {
    final options = [15, 30, 45, 60, 90, 120];
    _showRightPanel(
      title: '定时关闭',
      children: [
        ...options.map((minutes) => PanelOptionTile(
              label: '$minutes 分钟后关闭',
              leading: const Icon(Icons.timer_outlined),
              selected: false,
              onTap: () {
                Navigator.pop(context);
                _startSleepTimer(Duration(minutes: minutes));
              },
            )),
      ],
    );
  }

  void _startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(duration, () {
      if (mounted) {
        _playerService.pause();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已定时关闭播放')),
        );
      }
      _sleepTimer = null;
    });
    ref.read(sleepTimerRemainingProvider.notifier).state = duration;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已设置 ${duration.inMinutes} 分钟后关闭')),
    );
  }

  void _showCoreSwitchDialog() {
    final currentCore = normalizePlayerCore(ref.read(playerCoreProvider));
    final children = <Widget>[
      PanelOptionTile(
        label: 'ExoPlayer',
        subtitle: 'Android 原生，轻量稳定',
        selected: currentCore == 'exoPlayer',
        onTap: () {
          Navigator.pop(context);
          if (currentCore != 'exoPlayer') {
            _switchCore('exoPlayer');
          }
        },
      ),
      if (Platform.isAndroid)
        PanelOptionTile(
          label: 'MPV 原生',
          subtitle: 'libplayer.so 直调 libmpv，全格式/HDR/字幕',
          selected: currentCore == 'nativeMpv',
          onTap: () {
            Navigator.pop(context);
            if (currentCore != 'nativeMpv') {
              _switchCore('nativeMpv');
            }
          },
        ),
      if (!Platform.isAndroid)
        PanelOptionTile(
          label: 'MPV (media_kit)',
          subtitle: 'libmpv FFI，全格式/HDR/高级字幕',
          selected: currentCore == 'mpv',
          onTap: () {
            Navigator.pop(context);
            if (currentCore != 'mpv') {
              _switchCore('mpv');
            }
          },
        ),
    ];

    _showRightPanel(
      title: '切换播放器内核',
      children: children,
    );
  }

  Future<void> _switchCore(String core) async {
    final savedPosition = _playerService.position;
    ref.read(playerCoreProvider.notifier).state = normalizePlayerCore(core);
    await _playerService.dispose();
    _playerService = VideoPlayerService();
    _activePlayerService = _playerService;
    _playerService.addListener(_onPlayerUpdate);
    await _initializePlayer();
    if (savedPosition > Duration.zero) {
      await _playerService.seekTo(savedPosition);
    }
    if (mounted) {
      final normalized = normalizePlayerCore(core);
      final label = switch (normalized) {
        'mpv' => 'MPV (media_kit)',
        'nativeMpv' => 'MPV 原生',
        _ => 'ExoPlayer',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到 $label')),
      );
    }
  }

  void _showLineSelector() {
    final server = ref.read(currentServerProvider);
    if (server == null || server.lines.length <= 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前只有一个可用线路')),
        );
      }
      return;
    }
    _showRightPanel(
      title: '选择线路',
      children: [
        ...server.lines.asMap().entries.map((entry) {
          final idx = entry.key;
          final line = entry.value;
          return PanelOptionTile(
            leading: const Icon(Icons.route),
            label: line.name,
            selected: idx == server.activeLineIndex,
            onTap: () async {
              ref
                  .read(serverListProvider.notifier)
                  .setActiveLine(server.id, idx);
              // 同步更新 currentServerProvider
              final updatedServer = ref
                  .read(serverListProvider)
                  .firstWhere((s) => s.id == server.id);
              ref.read(currentServerProvider.notifier).state = updatedServer;
              Navigator.pop(context);
              // 重新初始化播放器以应用新线路
              final savedPosition = _playerService.position;
              await _playerService.dispose();
              _playerService = VideoPlayerService();
              _activePlayerService = _playerService;
              _playerService.addListener(_onPlayerUpdate);
              await _initializePlayer();
              if (savedPosition > Duration.zero) {
                await _playerService.seekTo(savedPosition);
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已切换到线路: ${line.name}')),
                );
              }
            },
          );
        }),
      ],
    );
  }

  void _showAspectRatioDialog() {
    final ratios = ['自动', '16:9', '4:3', '21:9', '全屏', '原始'];
    _showRightPanel(
      title: '画面比例',
      children: ratios
          .map((ratio) => PanelOptionTile(
                label: ratio,
                selected: ref.read(aspectRatioProvider) == ratio,
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
}

/// 滚动文字组件
