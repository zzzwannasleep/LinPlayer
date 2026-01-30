import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_service.dart';
import 'play_network_page_exo.dart';
import 'services/dandanplay_api.dart';
import 'services/emby_api.dart';
import 'server_adapters/server_access.dart';
import 'state/app_state.dart';
import 'state/anime4k_preferences.dart';
import 'state/danmaku_preferences.dart';
import 'state/interaction_preferences.dart';
import 'state/preferences.dart';
import 'state/server_profile.dart';
import 'src/player/anime4k.dart';
import 'src/player/danmaku.dart';
import 'src/player/danmaku_processing.dart';
import 'src/player/playback_controls.dart';
import 'src/player/danmaku_stage.dart';
import 'src/player/net_speed.dart';
import 'src/player/network/network_playback_backend.dart';
import 'src/player/thumbnail_generator.dart';
import 'src/player/track_preferences.dart';
import 'src/player/features/episode_picker.dart';
import 'src/player/features/player_gestures.dart';
import 'src/player/network/emby_media_source_utils.dart';
import 'src/player/network/network_playback_reporter.dart';
import 'src/player/shared/player_types.dart';
import 'src/player/shared/system_ui.dart';
import 'src/ui/glass_blur.dart';

class PlayNetworkPage extends StatefulWidget {
  const PlayNetworkPage({
    super.key,
    required this.title,
    required this.itemId,
    required this.appState,
    this.playbackBackend,
    this.server,
    this.isTv = false,
    this.seriesId,
    this.startPosition,
    this.resumeImmediately = true,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
  });

  final String title;
  final String itemId;
  final AppState appState;
  final NetworkPlaybackBackend? playbackBackend;
  final ServerProfile? server;
  final bool isTv;
  final String? seriesId;
  final Duration? startPosition;
  final bool resumeImmediately;
  final String? mediaSourceId;
  final int? audioStreamIndex; // Emby MediaStream Index
  final int? subtitleStreamIndex; // Emby MediaStream Index, -1 = off

  @override
  State<PlayNetworkPage> createState() => _PlayNetworkPageState();
}

class _PlayNetworkPageState extends State<PlayNetworkPage>
    with WidgetsBindingObserver {
  final PlayerService _playerService = getPlayerService();
  MediaKitThumbnailGenerator? _thumbnailer;
  ServerAccess? _serverAccess;
  late final NetworkPlaybackBackend _playbackBackend;
  bool _loading = true;
  String? _playError;
  late bool _hwdecOn;
  late Anime4kPreset _anime4kPreset;
  Tracks _tracks = const Tracks();
  Map<String, String> _httpHeaders = const {};

  // Subtitle options (MPV + media_kit_video SubtitleView).
  double _subtitleDelaySeconds = 0.0;
  double _subtitleFontSize = 32.0;
  int _subtitlePositionStep = 5; // 0..20, maps to padding-bottom in 5px steps.
  bool _subtitleBold = false;
  bool _subtitleAssOverrideForce = false;

  StreamSubscription<String>? _errorSub;
  String? _resolvedStream;
  int? _resolvedStreamSizeBytes;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<double>? _bufferingPctSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  bool _buffering = false;
  double? _bufferingPct;
  Duration _lastBuffer = Duration.zero;
  DateTime? _lastBufferAt;
  Duration _lastBufferSample = Duration.zero;
  double? _bufferSpeedX;
  Timer? _netSpeedTimer;
  bool _netSpeedPollInFlight = false;
  double? _netSpeedBytesPerSecond;
  bool _appliedAudioPref = false;
  bool _appliedSubtitlePref = false;
  String? _playSessionId;
  String? _mediaSourceId;
  List<Map<String, dynamic>> _availableMediaSources = const [];
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex;
  int? _selectedSubtitleStreamIndex;
  Duration? _overrideStartPosition;
  bool _overrideResumeImmediately = false;
  late final NetworkPlaybackReporter _playbackReporter;
  StreamSubscription<VideoParams>? _videoParamsSub;
  VideoParams? _lastVideoParams;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  String? _lastOrientationKey;
  bool _remoteEnabled = false;
  final FocusNode _tvSurfaceFocusNode =
      FocusNode(debugLabel: 'network_player_tv_surface');
  final FocusNode _tvPlayPauseFocusNode =
      FocusNode(debugLabel: 'network_player_tv_play_pause');
  Duration? _resumeHintPosition;
  bool _showResumeHint = false;
  Timer? _resumeHintTimer;
  Duration? _startOverHintPosition;
  bool _showStartOverHint = false;
  Timer? _startOverHintTimer;
  bool _deferProgressReporting = false;

  late final PlayerGestureController _gestureController;

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;

  final GlobalKey<DanmakuStageState> _danmakuKey =
      GlobalKey<DanmakuStageState>();
  final List<DanmakuSource> _danmakuSources = [];
  int _danmakuSourceIndex = -1;
  bool _danmakuEnabled = false;
  double _danmakuOpacity = 1.0;
  double _danmakuScale = 1.0;
  double _danmakuSpeed = 1.0;
  bool _danmakuBold = true;
  int _danmakuMaxLines = 10;
  int _danmakuTopMaxLines = 10;
  int _danmakuBottomMaxLines = 10;
  bool _danmakuPreventOverlap = true;
  bool _danmakuShowHeatmap = true;
  List<double> _danmakuHeatmap = const [];
  int _nextDanmakuIndex = 0;
  Duration _lastPosition = Duration.zero;
  bool _danmakuPaused = false;
  DateTime? _lastUiTickAt;

  late final EpisodePickerController _episodePicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gestureController = PlayerGestureController();
    _serverAccess =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    _playbackBackend = widget.playbackBackend ??
        EmbyLikeNetworkPlaybackBackend(
          access: _serverAccess,
          baseUrl: _baseUrl!,
          token: _token!,
          userId: _userId!,
          deviceId: widget.appState.deviceId,
          serverType: widget.server?.serverType ?? widget.appState.serverType,
        );
    _playbackReporter = NetworkPlaybackReporter(itemId: widget.itemId);
    _episodePicker = EpisodePickerController(
      itemId: widget.itemId,
      fetchItemDetail: (itemId) async {
        final access = _serverAccess;
        if (access == null) throw Exception('未连接服务器');
        return access.adapter.fetchItemDetail(access.auth, itemId: itemId);
      },
      fetchSeasons: (seriesId) async {
        final access = _serverAccess;
        if (access == null) throw Exception('Not connected');
        final seasons =
            await access.adapter.fetchSeasons(access.auth, seriesId: seriesId);
        return seasons.items;
      },
      fetchEpisodes: (seasonId) async {
        final access = _serverAccess;
        if (access == null) throw Exception('Not connected');
        final eps = await access.adapter
            .fetchEpisodes(access.auth, seasonId: seasonId);
        return eps.items;
      },
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _hwdecOn = widget.appState.preferHardwareDecode;
    _anime4kPreset = widget.appState.anime4kPreset;
    _danmakuEnabled = widget.appState.danmakuEnabled;
    _danmakuOpacity = widget.appState.danmakuOpacity;
    _danmakuScale = widget.appState.danmakuScale;
    _danmakuSpeed = widget.appState.danmakuSpeed;
    _danmakuBold = widget.appState.danmakuBold;
    _danmakuMaxLines = widget.appState.danmakuMaxLines;
    _danmakuTopMaxLines = widget.appState.danmakuTopMaxLines;
    _danmakuBottomMaxLines = widget.appState.danmakuBottomMaxLines;
    _danmakuPreventOverlap = widget.appState.danmakuPreventOverlap;
    _danmakuShowHeatmap = widget.appState.danmakuShowHeatmap;
    _selectedMediaSourceId = widget.mediaSourceId;
    _selectedAudioStreamIndex = widget.audioStreamIndex;
    _selectedSubtitleStreamIndex = widget.subtitleStreamIndex;
    final sid = (widget.seriesId ?? '').trim();
    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    if (serverId != null && serverId.isNotEmpty && sid.isNotEmpty) {
      _selectedAudioStreamIndex ??= widget.appState
          .seriesAudioStreamIndex(serverId: serverId, seriesId: sid);
      _selectedSubtitleStreamIndex ??= widget.appState
          .seriesSubtitleStreamIndex(serverId: serverId, seriesId: sid);
    }
    // ignore: unawaited_futures
    _exitImmersiveMode();
    _init();
    // ignore: unawaited_futures
    _episodePicker.preloadItem();
  }

  Future<void> _init() async {
    await _errorSub?.cancel();
    _errorSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    await _bufferingPctSub?.cancel();
    _bufferingPctSub = null;
    await _bufferSub?.cancel();
    _bufferSub = null;
    await _posSub?.cancel();
    _posSub = null;
    await _playingSub?.cancel();
    _playingSub = null;
    await _completedSub?.cancel();
    _completedSub = null;
    await _videoParamsSub?.cancel();
    _videoParamsSub = null;
    _lastVideoParams = null;
    _lastOrientationKey = null;
    _lastBuffer = Duration.zero;
    _lastBufferAt = null;
    _lastBufferSample = Duration.zero;
    _bufferSpeedX = null;
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
    _netSpeedPollInFlight = false;
    _netSpeedBytesPerSecond = null;
    _appliedAudioPref = false;
    _appliedSubtitlePref = false;
    _playSessionId = null;
    _mediaSourceId = null;
    _playbackReporter.reset();
    _nextDanmakuIndex = 0;
    _danmakuKey.currentState?.clear();
    _lastUiTickAt = null;
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _resumeHintPosition = null;
    _showResumeHint = false;
    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _startOverHintPosition = null;
    _showStartOverHint = false;
    _deferProgressReporting = false;
    _controlsVisible = true;
    _isScrubbing = false;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    try {
      await _thumbnailer?.dispose();
    } catch (_) {}
    _thumbnailer = null;
    try {
      final resolved = await _buildStream();
      _resolvedStream = resolved.streamUrl;
      _httpHeaders = resolved.httpHeaders;
      if (!kIsWeb && (_resolvedStream ?? '').isNotEmpty) {
        _thumbnailer = MediaKitThumbnailGenerator(
          media: Media(_resolvedStream!, httpHeaders: _httpHeaders),
        );
      }
      await _playerService.initialize(
        null,
        networkUrl: _resolvedStream,
        httpHeaders: _httpHeaders,
        isTv: widget.isTv,
        hardwareDecode: _hwdecOn,
        mpvCacheSizeMb: widget.appState.mpvCacheSizeMb,
        bufferBackRatio: widget.appState.playbackBufferBackRatio,
        unlimitedStreamCache: widget.appState.unlimitedStreamCache,
        networkStreamSizeBytes: _resolvedStreamSizeBytes,
        externalMpvPath: widget.appState.externalMpvPath,
      );
      if (_playerService.isExternalPlayback) {
        _playError = _playerService.externalPlaybackMessage ?? '已使用外部播放器播放';
        return;
      }

      _gestureController.setVolume(
        (_playerService.player.state.volume / 100).clamp(0.0, 1.0),
      );

      // ignore: unawaited_futures
      _pollNetSpeed();
      _scheduleNetSpeedTick();

      try {
        await Anime4k.apply(_playerService.player, _anime4kPreset);
      } catch (_) {
        _anime4kPreset = Anime4kPreset.off;
        // ignore: unawaited_futures
        widget.appState.setAnime4kPreset(Anime4kPreset.off);
      }

      await _applyMpvSubtitleOptions();
      final start = _overrideStartPosition ?? widget.startPosition;
      final resumeImmediately =
          _overrideResumeImmediately || widget.resumeImmediately;
      _overrideStartPosition = null;
      _overrideResumeImmediately = false;
      if (start != null && start > Duration.zero) {
        final target = _safeSeekTarget(start, _playerService.duration);
        _deferProgressReporting = true;
        if (resumeImmediately) {
          await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
          final applied = _playerService.position;
          _lastPosition = applied;
          _syncDanmakuCursor(applied);

          final ok = (applied - target).inMilliseconds.abs() <= 1000;
          if (ok) {
            _deferProgressReporting = false;
            if (applied > Duration.zero) {
              _startOverHintPosition = applied;
              _showStartOverHint = true;
            }
          } else {
            _resumeHintPosition = target;
            _showResumeHint = true;
          }
        } else {
          _resumeHintPosition = target;
          _showResumeHint = true;
        }
      }
      _tracks = _playerService.player.state.tracks;
      _maybeApplyInitialTracks(_tracks);
      _playerService.player.stream.tracks.listen((t) {
        if (!mounted) return;
        _maybeApplyInitialTracks(t);
        setState(() => _tracks = t);
      });
      _bufferingSub = _playerService.player.stream.buffering.listen((value) {
        if (!mounted) return;
        _buffering = value;
        _bufferSpeedX = null;
        _lastBufferAt = null;
        _lastBufferSample = _lastBuffer;
        _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
        setState(() {});
      });
      _bufferingPctSub =
          _playerService.player.stream.bufferingPercentage.listen((value) {
        if (!mounted) return;
        setState(() => _bufferingPct = value);
      });
      _bufferSub = _playerService.player.stream.buffer.listen((value) {
        _lastBuffer = value;

        final show = widget.appState.showBufferSpeed;
        if (!show || !_buffering) return;

        final now = DateTime.now();
        final refreshSeconds = widget.appState.bufferSpeedRefreshSeconds
            .clamp(0.2, 3.0)
            .toDouble();
        final refreshMs = (refreshSeconds * 1000).round();

        final prevAt = _lastBufferAt;
        if (prevAt == null) {
          _bufferSpeedX = null;
          _lastBufferAt = now;
          _lastBufferSample = value;
          if (mounted) setState(() {});
          return;
        }

        final dtMs = now.difference(prevAt).inMilliseconds;
        if (dtMs < refreshMs) return;

        final deltaMs = (value - _lastBufferSample).inMilliseconds;
        _lastBufferAt = now;
        _lastBufferSample = value;
        _bufferSpeedX = (dtMs > 0 && deltaMs >= 0) ? (deltaMs / dtMs) : null;

        if (!mounted) return;
        setState(() {});
      });
      _posSub = _playerService.player.stream.position.listen((pos) {
        if (!mounted) return;
        final prev = _lastPosition;
        final wentBack = pos + const Duration(seconds: 2) < prev;
        final jumpedForward = pos > prev + const Duration(seconds: 3);
        _lastPosition = pos;
        if (wentBack || jumpedForward) {
          _syncDanmakuCursor(pos);
        }
        _drainDanmaku(pos);
        _maybeReportPlaybackProgress(pos);

        final now = DateTime.now();
        final shouldRebuild = _lastUiTickAt == null ||
            now.difference(_lastUiTickAt!) >= const Duration(milliseconds: 250);
        if (shouldRebuild) {
          _lastUiTickAt = now;
          setState(() {});
        }
      });
      _playingSub = _playerService.player.stream.playing.listen((playing) {
        if (!mounted) return;
        _applyDanmakuPauseState(_buffering || !playing);
        _maybeReportPlaybackProgress(_lastPosition, force: true);
        setState(() {});
      });
      _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
      _completedSub = _playerService.player.stream.completed.listen((value) {
        if (!value) return;
        // ignore: unawaited_futures
        _reportPlaybackStoppedBestEffort(completed: true);
      });
      _videoParamsSub = _playerService.player.stream.videoParams.listen((p) {
        _lastVideoParams = p;
        // ignore: unawaited_futures
        _applyOrientationForMode(videoParams: p);
      });
      _lastVideoParams = _playerService.player.state.videoParams;
      // ignore: unawaited_futures
      _applyOrientationForMode(videoParams: _lastVideoParams);
      _errorSub?.cancel();
      _errorSub = _playerService.player.stream.error.listen((message) {
        if (!mounted) return;
        final lower = message.toLowerCase();
        final isShaderError =
            lower.contains('glsl') || lower.contains('shader');
        if (!_anime4kPreset.isOff && isShaderError) {
          setState(() => _anime4kPreset = Anime4kPreset.off);
          // ignore: unawaited_futures
          widget.appState.setAnime4kPreset(Anime4kPreset.off);
          // ignore: unawaited_futures
          Anime4k.clear(_playerService.player);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Anime4K 加载失败，已自动关闭')),
          );
          return;
        }
        setState(() => _playError = message);
      });
      if (!_deferProgressReporting) {
        // ignore: unawaited_futures
        _reportPlaybackStartBestEffort();
      }
      _maybeAutoLoadOnlineDanmaku();
    } catch (e) {
      _playError = e.toString();
      _resumeHintPosition = null;
      _showResumeHint = false;
      _startOverHintPosition = null;
      _showStartOverHint = false;
      _deferProgressReporting = false;
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_showResumeHint && _resumeHintPosition != null) {
          _startResumeHintTimer();
        }
        if (_showStartOverHint && _startOverHintPosition != null) {
          _startStartOverHintTimer();
        }
        _scheduleControlsHide();
      }
    }
  }

  void _maybeAutoLoadOnlineDanmaku() {
    final appState = widget.appState;
    if (!appState.danmakuEnabled) return;
    if (appState.danmakuLoadMode != DanmakuLoadMode.online) return;
    if (kIsWeb) return;
    // ignore: unawaited_futures
    _loadOnlineDanmakuForNetwork(showToast: false);
  }

  Future<void> _loadOnlineDanmakuForNetwork({bool showToast = true}) async {
    final appState = widget.appState;
    if (appState.danmakuApiUrls.isEmpty) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置-弹幕中添加在线弹幕源')),
        );
      }
      return;
    }

    final hasOfficial = appState.danmakuApiUrls.any((u) {
      final host = Uri.tryParse(u)?.host.toLowerCase() ?? '';
      return host == 'api.dandanplay.net';
    });
    final hasCreds = appState.danmakuAppId.trim().isNotEmpty &&
        appState.danmakuAppSecret.trim().isNotEmpty;

    if (hasOfficial && !hasCreds && showToast && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('使用官方弹弹play源时通常需要配置 AppId/AppSecret（设置-弹幕）'),
        ),
      );
    }

    var fileName = widget.title;
    int fileSizeBytes = 0;
    int videoDurationSeconds = 0;
    try {
      final access =
          resolveServerAccess(appState: appState, server: widget.server);
      if (access != null) {
        final item = await access.adapter
            .fetchItemDetail(access.auth, itemId: widget.itemId);
        fileName = _buildDanmakuMatchName(item);
        fileSizeBytes = item.sizeBytes ?? 0;
        final ticks = item.runTimeTicks ?? 0;
        if (ticks > 0) {
          videoDurationSeconds = (ticks / 10000000).round().clamp(0, 1 << 31);
        }
      }
    } catch (_) {}

    if (videoDurationSeconds <= 0) {
      videoDurationSeconds = _playerService.duration.inSeconds;
    }

    try {
      final sources = await loadOnlineDanmakuSources(
        apiUrls: appState.danmakuApiUrls,
        fileName: fileName,
        fileHash: null,
        fileSizeBytes: fileSizeBytes,
        videoDurationSeconds: videoDurationSeconds,
        matchMode: appState.danmakuMatchMode,
        chConvert: appState.danmakuChConvert,
        mergeRelated: appState.danmakuMergeRelated,
        appId: appState.danmakuAppId,
        appSecret: appState.danmakuAppSecret,
        throwIfEmpty: showToast,
      );
      if (!mounted) return;
      final processed = processDanmakuSources(
        sources,
        blockWords: appState.danmakuBlockWords,
        mergeDuplicates: appState.danmakuMergeDuplicates,
      );
      if (processed.isEmpty) {
        if (showToast) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未匹配到在线弹幕')),
          );
        }
        return;
      }
      setState(() {
        _danmakuSources.addAll(processed);
        final desiredName = appState.danmakuRememberSelectedSource
            ? appState.danmakuLastSelectedSourceName
            : '';
        final idx = desiredName.isEmpty
            ? -1
            : _danmakuSources.indexWhere((s) => s.name == desiredName);
        _danmakuSourceIndex = idx >= 0 ? idx : (_danmakuSources.length - 1);
        _danmakuEnabled = true;
        _rebuildDanmakuHeatmap();
        _syncDanmakuCursor(_lastPosition);
      });
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已加载在线弹幕：${sources.length} 个来源')),
        );
      }
    } catch (e) {
      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('在线弹幕加载失败：$e')),
        );
      }
    }
  }

  void _maybeApplyInitialTracks(Tracks tracks) {
    final player = _playerService.isInitialized ? _playerService.player : null;
    if (player == null) return;

    if (!_appliedAudioPref) {
      if (_selectedAudioStreamIndex != null) {
        final target = _selectedAudioStreamIndex!.toString();
        for (final a in tracks.audio) {
          if (a.id == target) {
            player.setAudioTrack(a);
            break;
          }
        }
      } else {
        final pref = widget.appState.preferredAudioLang;
        final picked = pickPreferredAudioTrack(tracks, pref);
        if (picked != null) {
          player.setAudioTrack(picked);
        }
      }
      _appliedAudioPref = true;
    }

    if (!_appliedSubtitlePref) {
      if (_selectedSubtitleStreamIndex != null) {
        if (_selectedSubtitleStreamIndex == -1) {
          player.setSubtitleTrack(SubtitleTrack.no());
        } else {
          final target = _selectedSubtitleStreamIndex!.toString();
          for (final s in tracks.subtitle) {
            if (s.id == target) {
              player.setSubtitleTrack(s);
              break;
            }
          }
        }
      } else {
        final pref = widget.appState.preferredSubtitleLang;
        if (isSubtitleOffPreference(pref)) {
          player.setSubtitleTrack(SubtitleTrack.no());
        } else {
          final picked = pickPreferredSubtitleTrack(tracks, pref);
          if (picked != null) {
            player.setSubtitleTrack(picked);
          }
        }
      }
      _appliedSubtitlePref = true;
    }
  }

  void _applyDanmakuPauseState(bool pause) {
    if (_danmakuPaused == pause) return;
    _danmakuPaused = pause;
    final stage = _danmakuKey.currentState;
    if (pause) {
      stage?.pause();
    } else {
      stage?.resume();
    }
  }

  String _buildDanmakuMatchName(MediaItem item) {
    final seriesName = item.seriesName.trim();
    final name = item.name.trim();
    final season = item.seasonNumber ?? 0;
    final episode = item.episodeNumber ?? 0;

    final base = seriesName.isNotEmpty
        ? seriesName
        : (name.isNotEmpty ? name : widget.title);
    final extra = (name.isNotEmpty && name != base) ? ' $name' : '';

    if (season > 0 && episode > 0) {
      final s = season.toString().padLeft(2, '0');
      final e = episode.toString().padLeft(2, '0');
      return '$base S${s}E$e$extra'.trim();
    }
    if (episode > 0) {
      final e = episode.toString().padLeft(2, '0');
      return '$base EP$e$extra'.trim();
    }
    if (seriesName.isNotEmpty && name.isNotEmpty && name != seriesName) {
      return '$seriesName $name'.trim();
    }
    return widget.title;
  }

  bool get _canShowEpisodePickerButton => _episodePicker.canShowButton;

  Future<void> _toggleEpisodePicker() async {
    await _episodePicker.toggle(showControls: _showControls);
  }

  void _playEpisodeFromPicker(MediaItem episode) {
    if (episode.id == widget.itemId) {
      _episodePicker.hide();
      return;
    }

    _episodePicker.hide();
    final ticks = episode.playbackPositionTicks;
    final start =
        ticks > 0 ? Duration(microseconds: (ticks / 10).round()) : null;
    final episodeSeriesId = (episode.seriesId ?? '').trim();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayNetworkPage(
          title: episode.name,
          itemId: episode.id,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
          seriesId:
              episodeSeriesId.isNotEmpty ? episodeSeriesId : widget.seriesId,
          startPosition: start,
          resumeImmediately: true,
          audioStreamIndex: _selectedAudioStreamIndex,
          subtitleStreamIndex: _selectedSubtitleStreamIndex,
        ),
      ),
    );
  }

  Widget _buildEpisodePickerOverlay({required bool enableBlur}) {
    return EpisodePickerOverlay(
      controller: _episodePicker,
      enableBlur: enableBlur,
      showCover: widget.appState.episodePickerShowCover,
      onToggleShowCover: () {
        final next = !widget.appState.episodePickerShowCover;
        // ignore: unawaited_futures
        widget.appState.setEpisodePickerShowCover(next);
      },
      currentItemId: widget.itemId,
      onPlayEpisode: _playEpisodeFromPicker,
      baseUrl: _baseUrl,
      token: _token,
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
    );
    /*
    final size = MediaQuery.sizeOf(context);
    final drawerWidth = math.min(
      420.0,
      size.width * (size.width > size.height ? 0.50 : 0.78),
    );

    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;
    final showCover = widget.appState.episodePickerShowCover;

    final baseUrl = _baseUrl;
    final token = _token;
    final apiPrefix = widget.server?.apiPrefix ?? widget.appState.apiPrefix;

    final seasons = _episodeSeasons;
    final selectedSeasonId = _episodeSelectedSeasonId;
    MediaItem? selectedSeason;
    if (selectedSeasonId != null && selectedSeasonId.isNotEmpty) {
      for (final s in seasons) {
        if (s.id == selectedSeasonId) {
          selectedSeason = s;
          break;
        }
      }
    }
    selectedSeason ??= seasons.isNotEmpty ? seasons.first : null;

    return Positioned.fill(
      child: Stack(
        children: [
          IgnorePointer(
            ignoring: !_episodePickerVisible,
            child: AnimatedOpacity(
              opacity: _episodePickerVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _episodePickerVisible = false),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.25),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            right: _episodePickerVisible ? 0 : -drawerWidth,
            width: drawerWidth,
            child: IgnorePointer(
              ignoring: !_episodePickerVisible,
              child: SafeArea(
                left: false,
                child: GlassCard(
                  enableBlur: enableBlur,
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  color: Colors.black.withValues(alpha: 0.35),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(16),
                    ),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.format_list_numbered,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              '选集',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (selectedSeason != null)
                              Expanded(
                                child: Container(
                                  height: 36,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color:
                                          Colors.white.withValues(alpha: 0.12),
                                    ),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: selectedSeason.id,
                                      isExpanded: true,
                                      isDense: true,
                                      dropdownColor: const Color(0xFF202020),
                                      iconEnabledColor: Colors.white70,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                      items: [
                                        for (final entry
                                            in seasons.asMap().entries)
                                          DropdownMenuItem(
                                            value: entry.value.id,
                                            child: Text(
                                              _seasonLabel(
                                                entry.value,
                                                entry.key,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                      onChanged: (v) {
                                        if (v == null || v.isEmpty) return;
                                        if (v == _episodeSelectedSeasonId) {
                                          return;
                                        }
                                        setState(() {
                                          _episodeSelectedSeasonId = v;
                                        });
                                      },
                                    ),
                                  ),
                                ),
                              )
                            else
                              const Spacer(),
                            IconButton(
                              tooltip: showCover ? '隐藏封面' : '显示封面',
                              icon: Icon(
                                showCover
                                    ? Icons.image_outlined
                                    : Icons.format_list_bulleted,
                              ),
                              color: Colors.white,
                              onPressed: () {
                                final next =
                                    !widget.appState.episodePickerShowCover;
                                // ignore: unawaited_futures
                                widget.appState.setEpisodePickerShowCover(next);
                                setState(() {});
                              },
                            ),
                            IconButton(
                              tooltip: '关闭',
                              icon: const Icon(Icons.close),
                              color: Colors.white,
                              onPressed: () =>
                                  setState(() => _episodePickerVisible = false),
                            ),
                          ],
                        ),
                      ),
                      if (_episodePickerLoading)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_episodePickerError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _episodePickerError!,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                onPressed: _ensureEpisodePickerLoaded,
                                icon: const Icon(Icons.refresh),
                                label: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      else if (selectedSeason == null)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            '暂无剧集信息',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      else ...[
                        Expanded(
                          child: FutureBuilder<List<MediaItem>>(
                            future:
                                _episodesFutureForSeasonId(selectedSeason.id),
                            builder: (ctx, snapshot) {
                              if (snapshot.connectionState !=
                                  ConnectionState.done) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }
                              if (snapshot.hasError) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        '加载失败：${snapshot.error}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      OutlinedButton.icon(
                                        onPressed: () => setState(() {
                                          final season = selectedSeason;
                                          if (season == null) return;
                                          _episodeEpisodesCache
                                              .remove(season.id);
                                          _episodeEpisodesFutureCache
                                              .remove(season.id);
                                        }),
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('重试'),
                                      ),
                                    ],
                                  ),
                                );
                              }

                              final eps = snapshot.data ?? const <MediaItem>[];
                              if (eps.isEmpty) {
                                return const Center(
                                  child: Text(
                                    '暂无剧集',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                );
                              }

                              final columns = drawerWidth >= 360 ? 2 : 1;

                              if (!showCover) {
                                return ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    12,
                                  ),
                                  itemCount: eps.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (ctx, index) {
                                    final e = eps[index];
                                    final epNo = e.episodeNumber ?? (index + 1);
                                    final isCurrent = e.id == widget.itemId;
                                    final borderColor = isCurrent
                                        ? accent.withValues(alpha: 0.85)
                                        : Colors.white.withValues(alpha: 0.10);
                                    final title = e.name.trim().isNotEmpty
                                        ? e.name.trim()
                                        : '第$epNo集';
                                    return Material(
                                      color:
                                          Colors.black.withValues(alpha: 0.18),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        side: BorderSide(color: borderColor),
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: () => _playEpisodeFromPicker(e),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 10,
                                          ),
                                          child: Row(
                                            children: [
                                              DecoratedBox(
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xAA000000),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 6,
                                                    vertical: 3,
                                                  ),
                                                  child: Text(
                                                    'E$epNo',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  title,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              if (isCurrent)
                                                const Icon(
                                                  Icons.play_circle,
                                                  color: Colors.white,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                );
                              }

                              return GridView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  12,
                                ),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  childAspectRatio: columns == 1 ? 1.55 : 1.18,
                                ),
                                itemCount: eps.length,
                                itemBuilder: (ctx, index) {
                                  final e = eps[index];
                                  final epNo = e.episodeNumber ?? (index + 1);
                                  final isCurrent = e.id == widget.itemId;
                                  final img = (baseUrl == null || token == null)
                                      ? null
                                      : EmbyApi.imageUrl(
                                          baseUrl: baseUrl,
                                          itemId: e.hasImage
                                              ? e.id
                                              : selectedSeason!.id,
                                          token: token,
                                          apiPrefix: apiPrefix,
                                          maxWidth: 520,
                                        );

                                  final borderColor = isCurrent
                                      ? accent.withValues(alpha: 0.85)
                                      : Colors.white.withValues(alpha: 0.10);

                                  return Material(
                                    color: Colors.black.withValues(alpha: 0.18),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(color: borderColor),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: () => _playEpisodeFromPicker(e),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          AspectRatio(
                                            aspectRatio: 16 / 9,
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                if (img != null)
                                                  Image.network(
                                                    img,
                                                    fit: BoxFit.cover,
                                                    errorBuilder: (_, __, ___) {
                                                      return const ColoredBox(
                                                        color:
                                                            Color(0x22000000),
                                                        child: Center(
                                                          child: Icon(
                                                            Icons
                                                                .image_not_supported_outlined,
                                                            color:
                                                                Colors.white54,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  )
                                                else
                                                  const ColoredBox(
                                                    color: Color(0x22000000),
                                                    child: Center(
                                                      child: Icon(
                                                        Icons.image_outlined,
                                                        color: Colors.white54,
                                                      ),
                                                    ),
                                                  ),
                                                Positioned(
                                                  left: 6,
                                                  bottom: 6,
                                                  child: DecoratedBox(
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xAA000000,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        6,
                                                      ),
                                                    ),
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 6,
                                                        vertical: 3,
                                                      ),
                                                      child: Text(
                                                        'E$epNo',
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                if (isCurrent)
                                                  const Positioned(
                                                    right: 6,
                                                    top: 6,
                                                    child: Icon(
                                                      Icons.play_circle,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              8,
                                              6,
                                              8,
                                              8,
                                            ),
                                            child: Text(
                                              e.name.trim().isNotEmpty
                                                  ? e.name.trim()
                                                  : '第$epNo集',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    */
  }

  void _syncDanmakuCursor(Duration position) {
    if (_danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      _nextDanmakuIndex = 0;
      return;
    }
    final items = _danmakuSources[_danmakuSourceIndex].items;
    _nextDanmakuIndex = DanmakuParser.lowerBoundByTime(items, position);
    _danmakuKey.currentState?.clear();
  }

  void _rebuildDanmakuHeatmap() {
    if (!_danmakuShowHeatmap) {
      _danmakuHeatmap = const [];
      return;
    }
    final duration = _playerService.duration;
    if (duration <= Duration.zero ||
        _danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      _danmakuHeatmap = const [];
      return;
    }
    _danmakuHeatmap = buildDanmakuHeatmap(
      _danmakuSources[_danmakuSourceIndex].items,
      duration: duration,
    );
  }

  void _drainDanmaku(Duration position) {
    if (!_danmakuEnabled) return;
    if (_danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      return;
    }
    final stage = _danmakuKey.currentState;
    if (stage == null) return;

    final items = _danmakuSources[_danmakuSourceIndex].items;
    while (_nextDanmakuIndex < items.length &&
        items[_nextDanmakuIndex].time <= position) {
      stage.emit(items[_nextDanmakuIndex]);
      _nextDanmakuIndex++;
    }
  }

  Future<void> _pickDanmakuFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xml'],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;

    String content = '';
    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) return;
      content = DanmakuParser.decodeBytes(bytes);
    } else {
      final path = file.path;
      if (path == null || path.trim().isEmpty) return;
      final bytes = await File(path).readAsBytes();
      content = DanmakuParser.decodeBytes(bytes);
    }

    var items = DanmakuParser.parseBilibiliXml(content);
    items = processDanmakuItems(
      items,
      blockWords: widget.appState.danmakuBlockWords,
      mergeDuplicates: widget.appState.danmakuMergeDuplicates,
    );
    if (!mounted) return;
    setState(() {
      _danmakuSources.add(DanmakuSource(name: file.name, items: items));
      final desiredName = widget.appState.danmakuRememberSelectedSource
          ? widget.appState.danmakuLastSelectedSourceName
          : '';
      final idx = desiredName.isEmpty
          ? -1
          : _danmakuSources.indexWhere((s) => s.name == desiredName);
      _danmakuSourceIndex = idx >= 0 ? idx : (_danmakuSources.length - 1);
      _danmakuEnabled = true;
      _rebuildDanmakuHeatmap();
      _syncDanmakuCursor(_lastPosition);
    });
  }

  Future<void> _showDanmakuSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        var onlineLoading = false;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final hasSources = _danmakuSources.isNotEmpty;
            final selectedName = (_danmakuSourceIndex >= 0 &&
                    _danmakuSourceIndex < _danmakuSources.length)
                ? _danmakuSources[_danmakuSourceIndex].name
                : '未选择';

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('弹幕',
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await _pickDanmakuFile();
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.upload_file),
                        label: const Text('加载'),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: onlineLoading
                          ? null
                          : () async {
                              onlineLoading = true;
                              setSheetState(() {});
                              try {
                                await _loadOnlineDanmakuForNetwork(
                                  showToast: true,
                                );
                              } finally {
                                onlineLoading = false;
                                setSheetState(() {});
                              }
                            },
                      icon: onlineLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined),
                      label: const Text('在线加载'),
                    ),
                  ),
                  SwitchListTile(
                    value: _danmakuEnabled,
                    onChanged: (v) {
                      setState(() => _danmakuEnabled = v);
                      if (!v) {
                        _danmakuKey.currentState?.clear();
                      }
                      setSheetState(() {});
                    },
                    title: const Text('启用弹幕'),
                    subtitle:
                        Text(hasSources ? '当前：$selectedName' : '尚未加载弹幕文件'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.layers_outlined),
                    title: const Text('弹幕源'),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: _danmakuSourceIndex >= 0
                            ? _danmakuSourceIndex
                            : null,
                        hint: const Text('请选择'),
                        items: [
                          for (var i = 0; i < _danmakuSources.length; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                _danmakuSources[i].name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: !hasSources
                            ? null
                            : (v) {
                                if (v == null) return;
                                setState(() {
                                  _danmakuSourceIndex = v;
                                  _danmakuEnabled = true;
                                  _rebuildDanmakuHeatmap();
                                  _syncDanmakuCursor(_lastPosition);
                                });
                                if (widget.appState
                                        .danmakuRememberSelectedSource &&
                                    v >= 0 &&
                                    v < _danmakuSources.length) {
                                  // ignore: unawaited_futures
                                  widget.appState
                                      .setDanmakuLastSelectedSourceName(
                                          _danmakuSources[v].name);
                                }
                                setSheetState(() {});
                              },
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.opacity_outlined),
                    title: const Text('不透明度'),
                    subtitle: Slider(
                      value: _danmakuOpacity,
                      min: 0.2,
                      max: 1.0,
                      onChanged: (v) {
                        setState(() => _danmakuOpacity = v);
                        setSheetState(() {});
                      },
                    ),
                  ),
                  if (hasSources)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _danmakuSources.clear();
                            _danmakuSourceIndex = -1;
                            _danmakuEnabled = false;
                            _danmakuHeatmap = const [];
                            _danmakuKey.currentState?.clear();
                          });
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('清空弹幕'),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<NetworkStreamResolution> _buildStream() async {
    _playSessionId = null;
    _mediaSourceId = null;
    _resolvedStreamSizeBytes = null;

    final sid = (widget.seriesId ?? '').trim();
    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    final seriesMediaSourceIndex =
        (serverId != null && serverId.isNotEmpty && sid.isNotEmpty)
            ? widget.appState
                .seriesMediaSourceIndex(serverId: serverId, seriesId: sid)
            : null;

    final res = await _playbackBackend.resolveStream(
      itemId: widget.itemId,
      selectedMediaSourceId: _selectedMediaSourceId,
      seriesMediaSourceIndex: seriesMediaSourceIndex,
      audioStreamIndex: _selectedAudioStreamIndex,
      subtitleStreamIndex: _selectedSubtitleStreamIndex,
      preferredVideoVersion: widget.appState.preferredVideoVersion,
      allowTranscoding: false,
      exoPlayer: false,
    );
    _availableMediaSources = res.mediaSources;
    _selectedMediaSourceId = res.selectedMediaSourceId;
    _playSessionId = res.playSessionId;
    _mediaSourceId = res.mediaSourceId;
    _resolvedStreamSizeBytes = res.streamSizeBytes;
    return res;
  }

  static String _fmtClock(Duration d) {
    return formatClock(d);
  }

  static String _mediaSourceTitle(Map<String, dynamic> ms) {
    return embyMediaSourceTitle(ms);
  }

  static String _mediaSourceSubtitle(Map<String, dynamic> ms) {
    return embyMediaSourceSubtitle(ms);
  }

  Duration _safeSeekTarget(Duration target, Duration total) {
    return safeSeekTarget(target, total);
  }

  void _startResumeHintTimer() {
    _resumeHintTimer?.cancel();
    _resumeHintTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (!_showResumeHint) return;
      _showResumeHint = false;
      final shouldStartReporting = _deferProgressReporting;
      _deferProgressReporting = false;
      if (shouldStartReporting) {
        // ignore: unawaited_futures
        _reportPlaybackStartBestEffort();
        _maybeReportPlaybackProgress(_lastPosition, force: true);
      }
      setState(() {});
    });
  }

  void _startStartOverHintTimer() {
    _startOverHintTimer?.cancel();
    _startOverHintTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (!_showStartOverHint) return;
      _showStartOverHint = false;
      setState(() {});
    });
  }

  Future<void> _restartFromBeginning() async {
    if (!_playerService.isInitialized) return;
    _showControls(scheduleHide: false);

    try {
      await _playerService.seek(
        Duration.zero,
        flushBuffer: _flushBufferOnSeek,
      );
    } catch (_) {}

    _lastPosition = Duration.zero;
    _syncDanmakuCursor(Duration.zero);
    _maybeReportPlaybackProgress(_lastPosition, force: true);

    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _showStartOverHint = false;
    if (mounted) setState(() {});
  }

  Future<void> _resumeToHistoryPosition() async {
    final target = _resumeHintPosition;
    if (target == null || target <= Duration.zero) return;
    if (!_playerService.isInitialized) return;

    final safeTarget = _safeSeekTarget(target, _playerService.duration);
    try {
      final seekFuture =
          _playerService.seek(safeTarget, flushBuffer: _flushBufferOnSeek);
      await seekFuture.timeout(const Duration(seconds: 3));
      _lastPosition = safeTarget;
      _syncDanmakuCursor(safeTarget);
    } catch (_) {}

    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _showResumeHint = false;
    final shouldStartReporting = _deferProgressReporting;
    _deferProgressReporting = false;
    if (shouldStartReporting) {
      // ignore: unawaited_futures
      _reportPlaybackStartBestEffort();
      _maybeReportPlaybackProgress(_lastPosition, force: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _reportPlaybackStartBestEffort() async {
    await _playbackReporter.reportPlaybackStartBestEffort(
      access: _serverAccess,
      playSessionId: _playSessionId,
      mediaSourceId: _mediaSourceId,
      position: _lastPosition,
      paused: !_playerService.isPlaying,
    );
  }

  void _maybeReportPlaybackProgress(Duration position, {bool force = false}) {
    if (_deferProgressReporting) return;
    _playbackReporter.maybeReportPlaybackProgressBestEffort(
      access: _serverAccess,
      playSessionId: _playSessionId,
      mediaSourceId: _mediaSourceId,
      position: position,
      paused: !_playerService.isPlaying,
      force: force,
    );
  }

  Future<void> _reportPlaybackStoppedBestEffort(
      {bool completed = false}) async {
    final pos =
        _playerService.isInitialized ? _playerService.position : _lastPosition;
    final dur = _playerService.duration;

    await _playbackReporter.reportPlaybackStoppedBestEffort(
      access: _serverAccess,
      playSessionId: _playSessionId,
      mediaSourceId: _mediaSourceId,
      position: pos,
      duration: dur,
      completed: completed,
    );
  }

  Future<void> _enterImmersiveMode() => enterImmersiveMode(isTv: widget.isTv);

  Future<void> _exitImmersiveMode({bool resetOrientations = false}) =>
      exitImmersiveMode(
        isTv: widget.isTv,
        resetOrientations: resetOrientations,
      );

  double? _displayAspect(VideoParams p) {
    var aspect = p.aspect;
    if (aspect == null || aspect <= 0) {
      final w = (p.dw ?? p.w)?.toDouble();
      final h = (p.dh ?? p.h)?.toDouble();
      if (w != null && h != null && w > 0 && h > 0) {
        aspect = w / h;
      }
    }
    final rotate = (p.rotate ?? 0) % 180;
    if (rotate != 0 && aspect != null && aspect != 0) {
      aspect = 1 / aspect;
    }
    if (aspect == null || aspect <= 0) return null;
    return aspect;
  }

  Future<void> _applyOrientationForMode({VideoParams? videoParams}) async {
    if (!canControlSystemUi(isTv: widget.isTv)) return;

    List<DeviceOrientation>? orientations;
    switch (_orientationMode) {
      case _OrientationMode.landscape:
        orientations = const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
        break;
      case _OrientationMode.portrait:
        orientations = const [DeviceOrientation.portraitUp];
        break;
      case _OrientationMode.auto:
        final p = videoParams;
        if (p == null) return;
        final aspect = _displayAspect(p);
        if (aspect == null) return;
        orientations = aspect < 1.0
            ? const [DeviceOrientation.portraitUp]
            : const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ];
        break;
    }

    final key = orientations.map((o) => o.name).join(',');
    if (_lastOrientationKey == key) return;
    _lastOrientationKey = key;
    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } catch (_) {}
  }

  String get _orientationTooltip => switch (_orientationMode) {
        _OrientationMode.auto => 'Orientation: Auto',
        _OrientationMode.landscape => 'Orientation: Landscape',
        _OrientationMode.portrait => 'Orientation: Portrait',
      };

  IconData get _orientationIcon => switch (_orientationMode) {
        _OrientationMode.auto => Icons.screen_rotation,
        _OrientationMode.landscape => Icons.stay_current_landscape,
        _OrientationMode.portrait => Icons.stay_current_portrait,
      };

  Future<void> _cycleOrientationMode() async {
    final next = switch (_orientationMode) {
      _OrientationMode.auto => _OrientationMode.landscape,
      _OrientationMode.landscape => _OrientationMode.portrait,
      _OrientationMode.portrait => _OrientationMode.auto,
    };
    if (mounted) {
      setState(() => _orientationMode = next);
    } else {
      _orientationMode = next;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_orientationTooltip),
            duration: const Duration(milliseconds: 800),
          ),
        );
    }
    await _applyOrientationForMode(videoParams: _lastVideoParams);
  }

  void _scheduleNetSpeedTick() {
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;

    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      if (_netSpeedBytesPerSecond != null && mounted) {
        setState(() => _netSpeedBytesPerSecond = null);
      }
      return;
    }

    final refreshSeconds =
        widget.appState.bufferSpeedRefreshSeconds.clamp(0.2, 3.0).toDouble();
    final refreshMs = (refreshSeconds * 1000).round();

    _netSpeedTimer = Timer(Duration(milliseconds: refreshMs), () async {
      if (!mounted) return;
      await _pollNetSpeed();
      if (!mounted) return;
      _scheduleNetSpeedTick();
    });
  }

  Future<void> _pollNetSpeed() async {
    if (_netSpeedPollInFlight) return;
    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      if (_netSpeedBytesPerSecond != null && mounted) {
        setState(() => _netSpeedBytesPerSecond = null);
      }
      return;
    }

    _netSpeedPollInFlight = true;
    try {
      final rate = await _playerService.queryNetworkInputRateBytesPerSecond();
      if (!mounted) return;
      final next = (rate != null && rate.isFinite) ? rate : null;
      if (next == null) {
        if (_netSpeedBytesPerSecond != null) {
          setState(() => _netSpeedBytesPerSecond = null);
        }
        return;
      }

      final prev = _netSpeedBytesPerSecond;
      final smoothed = prev == null ? next : (prev * 0.7 + next * 0.3);
      setState(() => _netSpeedBytesPerSecond = smoothed);
    } finally {
      _netSpeedPollInFlight = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // ignore: unawaited_futures
    _reportPlaybackStoppedBestEffort();
    // ignore: unawaited_futures
    _exitImmersiveMode(resetOrientations: true);
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _gestureController.dispose();
    _episodePicker.dispose();
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
    _errorSub?.cancel();
    _bufferingSub?.cancel();
    _bufferingPctSub?.cancel();
    _bufferSub?.cancel();
    _posSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();
    final thumb = _thumbnailer;
    _thumbnailer = null;
    if (thumb != null) {
      // ignore: unawaited_futures
      thumb.dispose();
    }
    _tvSurfaceFocusNode.dispose();
    _tvPlayPauseFocusNode.dispose();
    _playerService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (widget.appState.returnHomeBehavior != ReturnHomeBehavior.pause) return;

    if (!_playerService.isInitialized) return;
    if (!_playerService.isPlaying) return;
    // ignore: unawaited_futures
    _playerService.pause();
    _applyDanmakuPauseState(true);
  }

  void _showControls({bool scheduleHide = true}) {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    // ignore: unawaited_futures
    _exitImmersiveMode();
    if (scheduleHide && !_remoteEnabled) {
      _scheduleControlsHide();
    } else {
      _controlsHideTimer?.cancel();
      _controlsHideTimer = null;
    }
  }

  void _toggleControls() {
    if (!_controlsVisible) {
      _showControls();
      return;
    }
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    setState(() => _controlsVisible = false);
    // ignore: unawaited_futures
    _enterImmersiveMode();
    if (_remoteEnabled) _focusTvSurface();
  }

  void _focusTvSurface() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_tvSurfaceFocusNode);
    });
  }

  void _focusTvPlayPause() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_controlsVisible) return;
      FocusScope.of(context).requestFocus(_tvPlayPauseFocusNode);
    });
  }

  void _hideControlsForRemote() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (_controlsVisible) {
      setState(() => _controlsVisible = false);
    }
    // ignore: unawaited_futures
    _enterImmersiveMode();
    _focusTvSurface();
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (_remoteEnabled) return;
    if (!_controlsVisible || _isScrubbing) return;
    _controlsHideTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isScrubbing || _remoteEnabled) return;
      setState(() => _controlsVisible = false);
      // ignore: unawaited_futures
      _enterImmersiveMode();
    });
  }

  void _onScrubStart() {
    _isScrubbing = true;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _showControls(scheduleHide: false);
  }

  void _onScrubEnd() {
    _isScrubbing = false;
    _scheduleControlsHide();
  }

  bool get _gesturesEnabled =>
      _playerService.isInitialized && !_loading && _playError == null;

  int get _seekBackSeconds => widget.appState.seekBackwardSeconds;
  int get _seekForwardSeconds => widget.appState.seekForwardSeconds;
  bool get _flushBufferOnSeek => widget.appState.flushBufferOnSeek;

  Future<void> _togglePlayPause({bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    _showControls();
    if (_playerService.isPlaying) {
      await _playerService.pause();
      _applyDanmakuPauseState(true);
      if (showOverlay) {
        _gestureController.showOverlay(icon: Icons.pause, text: '暂停');
      }
      return;
    }
    await _playerService.play();
    _applyDanmakuPauseState(false);
    if (showOverlay) {
      _gestureController.showOverlay(icon: Icons.play_arrow, text: '播放');
    }
  }

  Future<void> _seekRelative(Duration delta, {bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    final duration = _playerService.duration;
    final current = _lastPosition;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;

    await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
    _lastPosition = target;
    _syncDanmakuCursor(target);
    _maybeReportPlaybackProgress(target, force: true);
    if (mounted) setState(() {});

    if (showOverlay) {
      final absSeconds = delta.inSeconds.abs();
      _gestureController.showOverlay(
        icon: delta.isNegative ? Icons.fast_rewind : Icons.fast_forward,
        text: '${delta.isNegative ? '快退' : '快进'} ${absSeconds}s',
      );
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (!_gesturesEnabled) return;
    await _playerService.seek(target, flushBuffer: _flushBufferOnSeek);
    _lastPosition = target;
    _syncDanmakuCursor(target);
    _maybeReportPlaybackProgress(target, force: true);
    if (mounted) setState(() {});
  }

  Future<void> _switchCore() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exo 内核仅支持 Android')),
      );
      return;
    }

    final pos = _lastPosition;
    _maybeReportPlaybackProgress(pos, force: true);
    await widget.appState.setPlayerCore(PlayerCore.exo);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ExoPlayNetworkPage(
          title: widget.title,
          itemId: widget.itemId,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
          seriesId: widget.seriesId,
          startPosition: pos,
          resumeImmediately: true,
          mediaSourceId:
              _selectedMediaSourceId ?? _mediaSourceId ?? widget.mediaSourceId,
          audioStreamIndex: _selectedAudioStreamIndex,
          subtitleStreamIndex: _selectedSubtitleStreamIndex,
        ),
      ),
    );
  }

  Future<void> _switchVersion() async {
    final pos = _playerService.isInitialized ? _lastPosition : Duration.zero;
    _maybeReportPlaybackProgress(pos, force: true);

    var sources = _availableMediaSources;
    if (sources.isEmpty) {
      try {
        final access = _serverAccess;
        if (access == null) throw Exception('Not connected');
        final info = await access.adapter
            .fetchPlaybackInfo(access.auth, itemId: widget.itemId);
        sources = info.mediaSources.cast<Map<String, dynamic>>();
        _availableMediaSources = List<Map<String, dynamic>>.from(sources);
      } catch (_) {
        sources = const [];
      }
    }

    if (sources.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法获取版本列表')),
      );
      return;
    }

    final current = _mediaSourceId ?? _selectedMediaSourceId ?? '';
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('版本选择')),
              for (final ms in sources)
                ListTile(
                  leading: Icon(
                    (ms['Id']?.toString() ?? '') == current
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                  ),
                  title: Text(_mediaSourceTitle(ms)),
                  subtitle: Text(_mediaSourceSubtitle(ms)),
                  onTap: () =>
                      Navigator.of(ctx).pop(ms['Id']?.toString() ?? ''),
                ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.trim().isEmpty) return;
    if (selected.trim() == current) return;

    final sid = (widget.seriesId ?? '').trim();
    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    if (serverId != null && serverId.isNotEmpty && sid.isNotEmpty) {
      final idx = sources.indexWhere(
        (ms) => (ms['Id']?.toString() ?? '') == selected.trim(),
      );
      if (idx >= 0) {
        // ignore: unawaited_futures
        unawaited(
          widget.appState.setSeriesMediaSourceIndex(
            serverId: serverId,
            seriesId: sid,
            mediaSourceIndex: idx,
          ),
        );
      }
    }

    setState(() {
      _selectedMediaSourceId = selected.trim();
      _selectedAudioStreamIndex = null;
      _selectedSubtitleStreamIndex = null;
      _overrideStartPosition = pos;
      _overrideResumeImmediately = true;
      _loading = true;
      _playError = null;
    });
    await _init();
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _playerService.isInitialized;
    final controlsEnabled = initialized && !_loading && _playError == null;
    final duration = initialized ? _playerService.duration : Duration.zero;
    final isPlaying = initialized ? _playerService.isPlaying : false;
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    final remoteEnabled = widget.isTv || widget.appState.forceRemoteControlKeys;
    _remoteEnabled = remoteEnabled;

    return Focus(
      focusNode: _tvSurfaceFocusNode,
      autofocus: remoteEnabled,
      canRequestFocus: remoteEnabled,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (!remoteEnabled) return KeyEventResult.ignored;
        if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowUp) {
          _showControls(scheduleHide: false);
          _focusTvPlayPause();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          if (_controlsVisible) {
            _hideControlsForRemote();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        if (!controlsEnabled) return KeyEventResult.ignored;

        if (key == LogicalKeyboardKey.space ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select) {
          // ignore: unawaited_futures
          _togglePlayPause();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          // ignore: unawaited_futures
          _seekRelative(Duration(seconds: -_seekBackSeconds));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          // ignore: unawaited_futures
          _seekRelative(Duration(seconds: _seekForwardSeconds));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: _controlsVisible
              ? const Size.fromHeight(kToolbarHeight)
              : Size.zero,
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: SafeArea(
                top: false,
                bottom: false,
                child: GlassAppBar(
                  enableBlur: enableBlur,
                  child: AppBar(
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    shadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    forceMaterialTransparency: true,
                    title: Text(widget.title),
                    centerTitle: true,
                    actions: [
                      IconButton(
                        tooltip: '重新加载',
                        icon: const Icon(Icons.refresh),
                        onPressed: _loading
                            ? null
                            : () async {
                                setState(() {
                                  _loading = true;
                                  _playError = null;
                                });
                                await _init();
                              },
                      ),
                      if (_resolvedStream != null)
                        IconButton(
                          tooltip: '复制链接',
                          icon: const Icon(Icons.link),
                          onPressed: () async {
                            final text = _resolvedStream;
                            if (text == null || text.isEmpty) return;
                            await Clipboard.setData(ClipboardData(text: text));
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制播放链接')),
                            );
                          },
                        ),
                      IconButton(
                        tooltip: '音轨',
                        icon: const Icon(Icons.audiotrack),
                        onPressed: () => _showAudioTracks(context),
                      ),
                      IconButton(
                        tooltip: '字幕',
                        icon: const Icon(Icons.subtitles),
                        onPressed: () => _showSubtitleTracks(context),
                      ),
                      IconButton(
                        tooltip: '弹幕',
                        icon: const Icon(Icons.comment_outlined),
                        onPressed: _showDanmakuSheet,
                      ),
                      IconButton(
                        tooltip: '软硬解切换（当前：${_hwdecOn ? '硬解' : '软解'}）',
                        icon: const Icon(Icons.memory),
                        onPressed: () async {
                          setState(() {
                            _hwdecOn = !_hwdecOn;
                            _loading = true;
                            _playError = null;
                          });
                          await _init();
                        },
                      ),
                      IconButton(
                        tooltip: _orientationTooltip,
                        icon: Icon(_orientationIcon),
                        onPressed: _cycleOrientationMode,
                      ),
                      PopupMenuButton<_PlayerMenuAction>(
                        tooltip: '更多',
                        icon: const Icon(Icons.more_vert),
                        color: const Color(0xFF202020),
                        onSelected: (action) async {
                          switch (action) {
                            case _PlayerMenuAction.anime4k:
                              await _showAnime4kSheet();
                              break;
                            case _PlayerMenuAction.switchCore:
                              await _switchCore();
                              break;
                            case _PlayerMenuAction.switchVersion:
                              await _switchVersion();
                              break;
                          }
                        },
                        itemBuilder: (ctx) {
                          final scheme = Theme.of(ctx).colorScheme;
                          return [
                            PopupMenuItem(
                              value: _PlayerMenuAction.anime4k,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.auto_fix_high,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    'Anime4K：${_anime4kPreset.label}',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: _PlayerMenuAction.switchVersion,
                              child: Row(
                                children: [
                                  Icon(Icons.video_file_outlined,
                                      color: scheme.primary),
                                  const SizedBox(width: 10),
                                  const Text(
                                    '版本选择',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            if (!kIsWeb &&
                                defaultTargetPlatform == TargetPlatform.android)
                              PopupMenuItem(
                                value: _PlayerMenuAction.switchCore,
                                child: Row(
                                  children: [
                                    Icon(Icons.tune, color: scheme.secondary),
                                    const SizedBox(width: 10),
                                    const Text(
                                      '切换内核',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ],
                                ),
                              ),
                          ];
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: Container(
                color: Colors.black,
                child: initialized
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Video(
                            controller: _playerService.controller,
                            controls: NoVideoControls,
                            subtitleViewConfiguration:
                                _subtitleViewConfiguration,
                          ),
                          Positioned.fill(
                            child: DanmakuStage(
                              key: _danmakuKey,
                              enabled: _danmakuEnabled,
                              opacity: _danmakuOpacity,
                              scale: _danmakuScale,
                              speed: _danmakuSpeed,
                              timeScale: _playerService.player.state.rate,
                              bold: _danmakuBold,
                              scrollMaxLines: _danmakuMaxLines,
                              topMaxLines: _danmakuTopMaxLines,
                              bottomMaxLines: _danmakuBottomMaxLines,
                              preventOverlap: _danmakuPreventOverlap,
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: AnimatedBuilder(
                                animation: _gestureController,
                                builder: (context, _) {
                                  final alpha =
                                      (1.0 - _gestureController.brightness)
                                          .clamp(0.0, 0.8)
                                          .toDouble();
                                  if (alpha <= 0) {
                                    return const SizedBox.expand();
                                  }
                                  return ColoredBox(
                                    color: Colors.black.withValues(alpha: alpha),
                                  );
                                },
                              ),
                            ),
                          ),
                          if (_buffering)
                            Container(
                              color: Colors.black54,
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(),
                                  if (_bufferingPct != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(
                                        '缓冲中 ${(_bufferingPct! <= 1 ? _bufferingPct! * 100 : _bufferingPct!).clamp(0, 100).toStringAsFixed(0)}%',
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                                    ),
                                  if (widget.appState.showBufferSpeed)
                                    Padding(
                                      padding: EdgeInsets.only(
                                        top: _bufferingPct != null ? 6 : 12,
                                      ),
                                      child: Text(
                                        '网速：${_netSpeedBytesPerSecond == null ? '—' : formatBytesPerSecond(_netSpeedBytesPerSecond!)}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (widget.appState.showBufferSpeed)
                            Positioned(
                              left: 12,
                              bottom: _controlsVisible ? 88 : 12,
                              child: SafeArea(
                                top: false,
                                right: false,
                                child: NetSpeedBadge(
                                  text:
                                      '网速 ${_netSpeedBytesPerSecond == null ? '—' : formatBytesPerSecond(_netSpeedBytesPerSecond!)}',
                                ),
                              ),
                            ),
                          Positioned.fill(
                            child: PlayerGestureDetectorLayer(
                              controller: _gestureController,
                              enabled: controlsEnabled,
                              position: _lastPosition,
                              duration: duration,
                              onToggleControls: _toggleControls,
                              onTogglePlayPause: () => _togglePlayPause(),
                              onSeekRelative: (d) => _seekRelative(d),
                              onSeekTo: _seekTo,
                              doubleTapLeft: widget.appState.doubleTapLeft,
                              doubleTapCenter: widget.appState.doubleTapCenter,
                              doubleTapRight: widget.appState.doubleTapRight,
                              seekBackwardSeconds: _seekBackSeconds,
                              seekForwardSeconds: _seekForwardSeconds,
                              gestureSeekEnabled: widget.appState.gestureSeek,
                              gestureBrightnessEnabled:
                                  widget.appState.gestureBrightness,
                              gestureVolumeEnabled: widget.appState.gestureVolume,
                              gestureLongPressEnabled:
                                  widget.appState.gestureLongPressSpeed,
                              longPressSlideEnabled:
                                  widget.appState.longPressSlideSpeed,
                              longPressSpeedMultiplier:
                                  widget.appState.longPressSpeedMultiplier,
                              getPlaybackRate: controlsEnabled
                                  ? () => _playerService.player.state.rate
                                  : null,
                              onSetPlaybackRate: controlsEnabled
                                  ? (rate) async {
                                      await _playerService.player.setRate(rate);
                                      if (mounted) setState(() {});
                                    }
                                  : null,
                              onSetVolume: controlsEnabled
                                  ? (volume) => _playerService.player
                                      .setVolume(volume * 100)
                                  : null,
                              clampSeekTarget: (target, duration) =>
                                  safeSeekTarget(
                                    target,
                                    duration,
                                    rewind: Duration.zero,
                                  ),
                              onShowControls: _showControls,
                              onScheduleControlsHide: _scheduleControlsHide,
                            ),
                          ),
                          if (controlsEnabled &&
                              _showResumeHint &&
                              _resumeHintPosition != null)
                            Align(
                              alignment: Alignment.topCenter,
                              child: SafeArea(
                                bottom: false,
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Material(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(999),
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: _resumeToHistoryPosition,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.history,
                                              size: 18,
                                              color: Colors.white,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '跳转到 ${_fmtClock(_resumeHintPosition!)} 继续观看',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (controlsEnabled &&
                              _showStartOverHint &&
                              _startOverHintPosition != null)
                            Align(
                              alignment: Alignment.topCenter,
                              child: SafeArea(
                                bottom: false,
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  child: Material(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(999),
                                    clipBehavior: Clip.antiAlias,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.history,
                                            size: 18,
                                            color: Colors.white,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            '已从 ${_fmtClock(_startOverHintPosition!)} 继续播放',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          InkWell(
                                            onTap: _restartFromBeginning,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.white
                                                    .withValues(alpha: 0.18),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.replay,
                                                    size: 18,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 4),
                                                  Text(
                                                    '从头开始',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: SafeArea(
                              top: false,
                              minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                              child: AnimatedOpacity(
                                opacity: _controlsVisible ? 1 : 0,
                                duration: const Duration(milliseconds: 200),
                                child: IgnorePointer(
                                  ignoring: !_controlsVisible,
                                  child: Listener(
                                    onPointerDown: (_) => _showControls(),
                                    child: Focus(
                                      canRequestFocus: false,
                                      onKeyEvent: (node, event) {
                                        if (!_remoteEnabled) {
                                          return KeyEventResult.ignored;
                                        }
                                        if (event is! KeyDownEvent) {
                                          return KeyEventResult.ignored;
                                        }
                                        if (event.logicalKey ==
                                            LogicalKeyboardKey.arrowDown) {
                                          final moved = FocusScope.of(context)
                                              .focusInDirection(
                                            TraversalDirection.down,
                                          );
                                          if (moved) {
                                            return KeyEventResult.handled;
                                          }
                                          _hideControlsForRemote();
                                          return KeyEventResult.handled;
                                        }
                                        return KeyEventResult.ignored;
                                      },
                                      child: PlaybackControls(
                                        enabled: controlsEnabled,
                                        playPauseFocusNode:
                                            _tvPlayPauseFocusNode,
                                        position: _lastPosition,
                                        buffered: _lastBuffer,
                                        duration: duration,
                                        isPlaying: isPlaying,
                                        playbackRate:
                                            _playerService.player.state.rate,
                                        onSetPlaybackRate: (rate) async {
                                          _showControls();
                                          if (!_playerService.isInitialized) {
                                            return;
                                          }
                                          await _playerService.player
                                              .setRate(rate);
                                          if (mounted) setState(() {});
                                        },
                                        heatmap: _danmakuHeatmap,
                                        showHeatmap: _danmakuShowHeatmap &&
                                            _danmakuHeatmap.isNotEmpty,
                                        seekBackwardSeconds: _seekBackSeconds,
                                        seekForwardSeconds: _seekForwardSeconds,
                                        showSystemTime: widget
                                            .appState.showSystemTimeInControls,
                                        showBattery: widget
                                            .appState.showBatteryInControls,
                                        showBufferSpeed:
                                            widget.appState.showBufferSpeed,
                                        buffering: _buffering,
                                        bufferSpeedX: _bufferSpeedX,
                                        onRequestThumbnail: _thumbnailer == null
                                            ? null
                                            : (pos) =>
                                                _thumbnailer!.getThumbnail(
                                                  pos,
                                                ),
                                        onOpenEpisodePicker:
                                            _canShowEpisodePickerButton
                                                ? _toggleEpisodePicker
                                                : null,
                                        onScrubStart: _onScrubStart,
                                        onScrubEnd: _onScrubEnd,
                                        onSeek: (pos) async {
                                          await _playerService.seek(
                                            pos,
                                            flushBuffer: _flushBufferOnSeek,
                                          );
                                          _lastPosition = pos;
                                          _syncDanmakuCursor(pos);
                                          _maybeReportPlaybackProgress(
                                            pos,
                                            force: true,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                        onPlay: () {
                                          _showControls();
                                          return _playerService.play();
                                        },
                                        onPause: () {
                                          _showControls();
                                          return _playerService.pause();
                                        },
                                        onSeekBackward: () async {
                                          _showControls();
                                          final target = _lastPosition -
                                              Duration(
                                                  seconds: _seekBackSeconds);
                                          final pos = target < Duration.zero
                                              ? Duration.zero
                                              : target;
                                          await _playerService.seek(
                                            pos,
                                            flushBuffer: _flushBufferOnSeek,
                                          );
                                          _lastPosition = pos;
                                          _syncDanmakuCursor(pos);
                                          _maybeReportPlaybackProgress(
                                            pos,
                                            force: true,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                        onSeekForward: () async {
                                          _showControls();
                                          final d = duration;
                                          final target = _lastPosition +
                                              Duration(
                                                  seconds: _seekForwardSeconds);
                                          final pos =
                                              (d > Duration.zero && target > d)
                                                  ? d
                                                  : target;
                                          await _playerService.seek(
                                            pos,
                                            flushBuffer: _flushBufferOnSeek,
                                          );
                                          _lastPosition = pos;
                                          _syncDanmakuCursor(pos);
                                          _maybeReportPlaybackProgress(
                                            pos,
                                            force: true,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          _buildEpisodePickerOverlay(enableBlur: enableBlur),
                        ],
                      )
                    : _playError != null
                        ? Center(
                            child: Text(
                            '播放失败：$_playError',
                            style: const TextStyle(color: Colors.redAccent),
                          ))
                        : const Center(child: CircularProgressIndicator()),
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Future<void> _showAnime4kSheet() async {
    final selected = await showModalBottomSheet<Anime4kPreset>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final current = _anime4kPreset;
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('Anime4K（M）')),
              for (final preset in Anime4kPreset.values)
                ListTile(
                  leading: Icon(
                    preset == current
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                  ),
                  title: Text(preset.label),
                  subtitle: Text(preset.description),
                  onTap: () => Navigator.of(ctx).pop(preset),
                ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected == _anime4kPreset) return;

    setState(() => _anime4kPreset = selected);
    // ignore: unawaited_futures
    widget.appState.setAnime4kPreset(selected);

    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      await Anime4k.apply(_playerService.player, selected);
      if (!mounted) return;
      final text =
          selected.isOff ? '已关闭 Anime4K' : '已启用 Anime4K：${selected.label}';
      messenger.showSnackBar(
        SnackBar(content: Text(text)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _anime4kPreset = Anime4kPreset.off);
      // ignore: unawaited_futures
      widget.appState.setAnime4kPreset(Anime4kPreset.off);
      try {
        await Anime4k.clear(_playerService.player);
      } catch (_) {}
      messenger.showSnackBar(
        const SnackBar(content: Text('Anime4K 初始化失败')),
      );
    }
  }

  void _showAudioTracks(BuildContext context) {
    final audios = List<AudioTrack>.from(_tracks.audio);
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        if (audios.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无音轨'),
          );
        }
        final current = _playerService.player.state.track.audio;
        return ListView(
          children: audios
              .map(
                (a) => ListTile(
                  title: Text(a.title ?? a.language ?? '音轨 ${a.id}'),
                  subtitle: Text(a.codec ?? ''),
                  trailing: current == a ? const Icon(Icons.check) : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _playerService.player.setAudioTrack(a);
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }

  void _showSubtitleTracks(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        var tracksExpanded = true;
        final messenger = ScaffoldMessenger.of(context);

        IconButton miniIconButton({
          required VoidCallback? onPressed,
          required IconData icon,
          String? tooltip,
        }) {
          return IconButton(
            onPressed: onPressed,
            tooltip: tooltip,
            icon: Icon(icon),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          );
        }

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final subs = List<SubtitleTrack>.from(_tracks.subtitle);
            final current = _playerService.player.state.track.subtitle;

            Future<void> pickAndAddSubtitle() async {
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt', 'sub'],
              );
              if (result == null || result.files.isEmpty) return;
              final f = result.files.first;
              final path = (f.path ?? '').trim();
              if (path.isEmpty) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('无法读取字幕文件路径')),
                );
                return;
              }
              try {
                await _playerService.player.setSubtitleTrack(
                  SubtitleTrack.uri(path, title: f.name),
                );
                _selectedSubtitleStreamIndex = null;
                _tracks = _playerService.player.state.tracks;
                setSheetState(() {});
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('添加字幕失败：$e')));
              }
            }

            Future<void> editSubtitleDelay() async {
              final controller = TextEditingController(
                text: _subtitleDelaySeconds.toStringAsFixed(1),
              );
              final value = await showDialog<double>(
                context: ctx,
                builder: (dctx) => AlertDialog(
                  title: const Text('字幕同步'),
                  content: TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      hintText: '单位：秒，例如 0.5 或 -1.2',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dctx).pop(),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () {
                        final v = double.tryParse(controller.text.trim());
                        Navigator.of(dctx).pop(v);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              );
              if (value == null) return;
              _subtitleDelaySeconds = value.clamp(-60.0, 60.0).toDouble();
              await _applyMpvSubtitleOptions();
              setSheetState(() {});
            }

            Future<void> pickAssOverride() async {
              final next = await showDialog<bool>(
                context: ctx,
                builder: (dctx) => SimpleDialog(
                  title: const Text('强制覆盖 ASS/SSA 字幕'),
                  children: [
                    ListTile(
                      title: const Text('No'),
                      trailing: !_subtitleAssOverrideForce
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.of(dctx).pop(false),
                    ),
                    ListTile(
                      title: const Text('Force'),
                      trailing: _subtitleAssOverrideForce
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.of(dctx).pop(true),
                    ),
                  ],
                ),
              );
              if (next == null) return;
              _subtitleAssOverrideForce = next;
              await _applyMpvSubtitleOptions();
              setSheetState(() {});
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: ListView(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '字幕',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.closed_caption_outlined),
                      title: const Text('轨道'),
                      trailing: IconButton(
                        icon: Icon(
                          tracksExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                        onPressed: () {
                          tracksExpanded = !tracksExpanded;
                          setSheetState(() {});
                        },
                      ),
                    ),
                    if (tracksExpanded) ...[
                      RadioGroup<SubtitleTrack>(
                        groupValue: current,
                        onChanged: (value) {
                          if (value == null) return;
                          _selectedSubtitleStreamIndex =
                              value.id == 'no' ? -1 : int.tryParse(value.id);
                          _playerService.player.setSubtitleTrack(value);
                          setSheetState(() {});
                        },
                        child: Column(
                          children: [
                            RadioListTile<SubtitleTrack>(
                              value: SubtitleTrack.no(),
                              title: const Text('关闭'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                            for (final s in subs)
                              RadioListTile<SubtitleTrack>(
                                value: s,
                                title: Text(_subtitleTrackTitle(s)),
                                subtitle: Text(_subtitleTrackSubtitle(s)),
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                              ),
                          ],
                        ),
                      ),
                      if (subs.isEmpty)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(40, 0, 0, 8),
                          child: Text('暂无字幕'),
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.add),
                        title: const Text('添加字幕'),
                        onTap: pickAndAddSubtitle,
                      ),
                    ],
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字幕同步'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          miniIconButton(
                            onPressed: () async {
                              _subtitleDelaySeconds =
                                  (_subtitleDelaySeconds - 0.1)
                                      .clamp(-60.0, 60.0)
                                      .toDouble();
                              await _applyMpvSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.remove,
                            tooltip: '-0.1s',
                          ),
                          Text('${_subtitleDelaySeconds.toStringAsFixed(1)}s'),
                          miniIconButton(
                            onPressed: () async {
                              _subtitleDelaySeconds =
                                  (_subtitleDelaySeconds + 0.1)
                                      .clamp(-60.0, 60.0)
                                      .toDouble();
                              await _applyMpvSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.add,
                            tooltip: '+0.1s',
                          ),
                          const SizedBox(width: 6),
                          miniIconButton(
                            onPressed: editSubtitleDelay,
                            icon: Icons.edit_outlined,
                            tooltip: '输入',
                          ),
                          miniIconButton(
                            onPressed: () async {
                              _subtitleDelaySeconds = 0.0;
                              await _applyMpvSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.history,
                            tooltip: '重置',
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字幕大小'),
                      subtitle: Slider(
                        value: _subtitleFontSize.clamp(12.0, 60.0),
                        min: 12.0,
                        max: 60.0,
                        divisions: 48,
                        onChanged: (v) {
                          setState(() => _subtitleFontSize = v);
                          setSheetState(() {});
                        },
                      ),
                      trailing: Text('${_subtitleFontSize.round()}'),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字幕位置'),
                      subtitle: Slider(
                        value: _subtitlePositionStep.toDouble().clamp(0, 20),
                        min: 0,
                        max: 20,
                        divisions: 20,
                        onChanged: (v) {
                          setState(() => _subtitlePositionStep = v.round());
                          setSheetState(() {});
                        },
                      ),
                      trailing: Text('$_subtitlePositionStep'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('粗体'),
                      value: _subtitleBold,
                      onChanged: (v) {
                        setState(() => _subtitleBold = v);
                        setSheetState(() {});
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('强制覆盖 ASS/SSA 字幕'),
                      subtitle:
                          Text(_subtitleAssOverrideForce ? 'Force' : 'No'),
                      onTap: pickAssOverride,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static String _subtitleTrackTitle(SubtitleTrack s) {
    final t = (s.title ?? '').trim();
    if (t.isNotEmpty) return t;
    final lang = (s.language ?? '').trim();
    if (lang.isNotEmpty) return lang;
    return '字幕 ${s.id}';
  }

  static String _subtitleTrackSubtitle(SubtitleTrack s) {
    final parts = <String>[];
    final lang = (s.language ?? '').trim();
    final codec = (s.codec ?? '').trim();
    if (lang.isNotEmpty) parts.add(lang);
    if (codec.isNotEmpty) parts.add(codec);
    return parts.join('  ');
  }

  SubtitleViewConfiguration get _subtitleViewConfiguration {
    const base = SubtitleViewConfiguration();
    final bottom =
        (_subtitlePositionStep.clamp(0, 20) * 5.0).clamp(0.0, 200.0).toDouble();
    return SubtitleViewConfiguration(
      visible: base.visible,
      style: base.style.copyWith(
        fontSize: _subtitleFontSize.clamp(12.0, 60.0),
        fontWeight: _subtitleBold ? FontWeight.w600 : FontWeight.normal,
      ),
      textAlign: base.textAlign,
      textScaler: base.textScaler,
      padding: base.padding.copyWith(bottom: bottom),
    );
  }

  Future<void> _applyMpvSubtitleOptions() async {
    if (!_playerService.isInitialized || _playerService.isExternalPlayback) {
      return;
    }
    final platform = _playerService.player.platform as dynamic;
    try {
      await platform.setProperty(
        'sub-delay',
        _subtitleDelaySeconds.toStringAsFixed(3),
      );
    } catch (_) {}
    try {
      await platform.setProperty(
        'sub-ass-override',
        _subtitleAssOverrideForce ? 'force' : 'no',
      );
    } catch (_) {}
  }
}

enum _PlayerMenuAction { anime4k, switchCore, switchVersion }

typedef _OrientationMode = OrientationMode;
