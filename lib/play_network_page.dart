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
import 'state/app_state.dart';
import 'state/anime4k_preferences.dart';
import 'state/danmaku_preferences.dart';
import 'state/preferences.dart';
import 'state/server_profile.dart';
import 'src/player/anime4k.dart';
import 'src/player/danmaku.dart';
import 'src/player/danmaku_processing.dart';
import 'src/player/playback_controls.dart';
import 'src/player/danmaku_stage.dart';
import 'src/player/thumbnail_generator.dart';
import 'src/player/track_preferences.dart';
import 'src/ui/glass_blur.dart';

class PlayNetworkPage extends StatefulWidget {
  const PlayNetworkPage({
    super.key,
    required this.title,
    required this.itemId,
    required this.appState,
    this.server,
    this.isTv = false,
    this.startPosition,
    this.resumeImmediately = false,
    this.mediaSourceId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
  });

  final String title;
  final String itemId;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;
  final Duration? startPosition;
  final bool resumeImmediately;
  final String? mediaSourceId;
  final int? audioStreamIndex; // Emby MediaStream Index
  final int? subtitleStreamIndex; // Emby MediaStream Index, -1 = off

  @override
  State<PlayNetworkPage> createState() => _PlayNetworkPageState();
}

class _PlayNetworkPageState extends State<PlayNetworkPage> {
  final PlayerService _playerService = getPlayerService();
  MediaKitThumbnailGenerator? _thumbnailer;
  EmbyApi? _embyApi;
  bool _loading = true;
  String? _playError;
  late bool _hwdecOn;
  late Anime4kPreset _anime4kPreset;
  Tracks _tracks = const Tracks();
  StreamSubscription<String>? _errorSub;
  String? _resolvedStream;
  int? _resolvedStreamSizeBytes;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<double>? _bufferingPctSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  bool _buffering = false;
  double? _bufferingPct;
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
  DateTime? _lastProgressReportAt;
  bool _lastProgressReportPaused = false;
  bool _reportedStart = false;
  bool _reportedStop = false;
  bool _progressReportInFlight = false;
  StreamSubscription<VideoParams>? _videoParamsSub;
  VideoParams? _lastVideoParams;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  String? _lastOrientationKey;
  Duration? _resumeHintPosition;
  bool _showResumeHint = false;
  Timer? _resumeHintTimer;
  bool _deferProgressReporting = false;

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
  int _nextDanmakuIndex = 0;
  Duration _lastPosition = Duration.zero;
  bool _danmakuPaused = false;
  DateTime? _lastUiTickAt;

  @override
  void initState() {
    super.initState();
    final baseUrl = _baseUrl;
    if (baseUrl != null && baseUrl.trim().isNotEmpty) {
      _embyApi = EmbyApi(
        hostOrUrl: baseUrl,
        preferredScheme: 'https',
        apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      );
    }
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
    _selectedMediaSourceId = widget.mediaSourceId;
    _selectedAudioStreamIndex = widget.audioStreamIndex;
    _selectedSubtitleStreamIndex = widget.subtitleStreamIndex;
    // ignore: unawaited_futures
    _exitImmersiveMode();
    _init();
  }

  Future<void> _init() async {
    await _errorSub?.cancel();
    _errorSub = null;
    await _bufferingSub?.cancel();
    _bufferingSub = null;
    await _bufferingPctSub?.cancel();
    _bufferingPctSub = null;
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
    _appliedAudioPref = false;
    _appliedSubtitlePref = false;
    _playSessionId = null;
    _mediaSourceId = null;
    _lastProgressReportAt = null;
    _lastProgressReportPaused = false;
    _reportedStart = false;
    _reportedStop = false;
    _progressReportInFlight = false;
    _nextDanmakuIndex = 0;
    _danmakuKey.currentState?.clear();
    _lastUiTickAt = null;
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _resumeHintPosition = null;
    _showResumeHint = false;
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
      final streamUrl = await _buildStreamUrl();
      _resolvedStream = streamUrl;
      final embyHeaders = {
        'X-Emby-Token': _token!,
        'X-Emby-Authorization':
            'MediaBrowser Client="LinPlayer", Device="Flutter", DeviceId="${widget.appState.deviceId}", Version="1.0.0"',
      };
      if (!kIsWeb && streamUrl.isNotEmpty) {
        _thumbnailer = MediaKitThumbnailGenerator(
          media: Media(streamUrl, httpHeaders: embyHeaders),
        );
      }
      await _playerService.initialize(
        null,
        networkUrl: streamUrl,
        httpHeaders: embyHeaders,
        isTv: widget.isTv,
        hardwareDecode: _hwdecOn,
        mpvCacheSizeMb: widget.appState.mpvCacheSizeMb,
        unlimitedStreamCache: widget.appState.unlimitedStreamCache,
        networkStreamSizeBytes: _resolvedStreamSizeBytes,
        externalMpvPath: widget.appState.externalMpvPath,
      );
      if (_playerService.isExternalPlayback) {
        _playError = _playerService.externalPlaybackMessage ?? '已使用外部播放器播放';
        return;
      }

      try {
        await Anime4k.apply(_playerService.player, _anime4kPreset);
      } catch (_) {
        _anime4kPreset = Anime4kPreset.off;
        // ignore: unawaited_futures
        widget.appState.setAnime4kPreset(Anime4kPreset.off);
      }
      final start = _overrideStartPosition ?? widget.startPosition;
      final resumeImmediately =
          _overrideResumeImmediately || widget.resumeImmediately;
      _overrideStartPosition = null;
      _overrideResumeImmediately = false;
      if (start != null && start > Duration.zero) {
        final target = _safeSeekTarget(start, _playerService.duration);
        if (resumeImmediately) {
          await _playerService.seek(target);
          _lastPosition = target;
          _syncDanmakuCursor(target);
        } else {
          _resumeHintPosition = target;
          _showResumeHint = true;
          _deferProgressReporting = true;
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
        _applyDanmakuPauseState(_buffering || !_playerService.isPlaying);
        setState(() {});
      });
      _bufferingPctSub =
          _playerService.player.stream.bufferingPercentage.listen((value) {
        if (!mounted) return;
        setState(() => _bufferingPct = value);
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
      _deferProgressReporting = false;
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_showResumeHint && _resumeHintPosition != null) {
          _startResumeHintTimer();
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
      final api = EmbyApi(
        hostOrUrl: appState.baseUrl!,
        preferredScheme: 'https',
        apiPrefix: appState.apiPrefix,
      );
      final item = await api.fetchItemDetail(
        token: appState.token!,
        baseUrl: appState.baseUrl!,
        userId: appState.userId!,
        itemId: widget.itemId,
      );
      fileName = _buildDanmakuMatchName(item);
      fileSizeBytes = item.sizeBytes ?? 0;
      final ticks = item.runTimeTicks ?? 0;
      if (ticks > 0) {
        videoDurationSeconds = (ticks / 10000000).round().clamp(0, 1 << 31);
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

  Future<String> _buildStreamUrl() async {
    final base = _baseUrl!;
    final token = _token!;
    final userId = _userId!;
    _playSessionId = null;
    _mediaSourceId = null;
    _resolvedStreamSizeBytes = null;
    String applyQueryPrefs(String url) {
      final uri = Uri.parse(url);
      final params = Map<String, String>.from(uri.queryParameters);
      if (!params.containsKey('api_key')) params['api_key'] = token;
      if (_selectedAudioStreamIndex != null) {
        params['AudioStreamIndex'] = _selectedAudioStreamIndex.toString();
      }
      if (_selectedSubtitleStreamIndex != null &&
          _selectedSubtitleStreamIndex! >= 0) {
        params['SubtitleStreamIndex'] = _selectedSubtitleStreamIndex.toString();
      }
      return uri.replace(queryParameters: params).toString();
    }

    String resolve(String candidate) {
      final resolved = Uri.parse(base).resolve(candidate).toString();
      return applyQueryPrefs(resolved);
    }

    try {
      final api = _embyApi ??
          EmbyApi(
            hostOrUrl: base,
            preferredScheme: 'https',
            apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
          );
      final info = await api.fetchPlaybackInfo(
        token: token,
        baseUrl: base,
        userId: userId,
        deviceId: widget.appState.deviceId,
        itemId: widget.itemId,
      );
      final sources = info.mediaSources.cast<Map<String, dynamic>>();
      _availableMediaSources = List<Map<String, dynamic>>.from(sources);
      Map<String, dynamic>? ms;
      if (sources.isNotEmpty) {
        final selectedId = _selectedMediaSourceId;
        if (selectedId != null && selectedId.isNotEmpty) {
          ms = sources.firstWhere(
            (s) => (s['Id'] as String? ?? '') == selectedId,
            orElse: () => sources.first,
          );
        } else {
          ms = sources.first;
        }
      }
      _playSessionId = info.playSessionId;
      _mediaSourceId = (ms?['Id'] as String?) ?? info.mediaSourceId;
      _resolvedStreamSizeBytes = _asInt(ms?['Size']);
      final directStreamUrl = ms?['DirectStreamUrl'] as String?;
      if (directStreamUrl != null && directStreamUrl.isNotEmpty) {
        return resolve(directStreamUrl);
      }
      // Prefer direct stream (no transcoding). Even if server reports unsupported direct play/stream,
      // the static stream endpoint may still work with mpv's broader codec/container support.
      final mediaSourceId = (ms?['Id'] as String?) ?? info.mediaSourceId;
      return applyQueryPrefs(
        '$base/emby/Videos/${widget.itemId}/stream?static=true&MediaSourceId=$mediaSourceId'
        '&PlaySessionId=${info.playSessionId}&UserId=$userId&DeviceId=${widget.appState.deviceId}'
        '&api_key=$token',
      );
    } catch (_) {
      return applyQueryPrefs(
        '$base/emby/Videos/${widget.itemId}/stream?static=true&UserId=$userId'
        '&DeviceId=${widget.appState.deviceId}&api_key=$token',
      );
      // 回退：无需 playbackInfo 的直链（部分服务器禁用该接口）
    }
  }

  int _toTicks(Duration d) => d.inMicroseconds * 10;

  static String _fmtClock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static List<Map<String, dynamic>> _streamsOfType(
      Map<String, dynamic> ms, String type) {
    final streams = (ms['MediaStreams'] as List?) ?? const [];
    return streams
        .where((e) => (e as Map)['Type'] == type)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  static String _mediaSourceTitle(Map<String, dynamic> ms) {
    return (ms['Name'] as String?) ?? (ms['Container'] as String?) ?? '默认版本';
  }

  static String _mediaSourceSubtitle(Map<String, dynamic> ms) {
    final size = ms['Size'];
    final sizeGb =
        size is num ? (size / (1024 * 1024 * 1024)).toStringAsFixed(1) : null;
    final bitrate = _asInt(ms['Bitrate']);
    final bitrateMbps =
        bitrate != null ? (bitrate / 1000000).toStringAsFixed(1) : null;

    final videoStreams = _streamsOfType(ms, 'Video');
    final video = videoStreams.isNotEmpty ? videoStreams.first : null;
    final height = _asInt(video?['Height']);
    final vCodec =
        (ms['VideoCodec'] as String?) ?? (video?['Codec'] as String?);

    final parts = <String>[];
    if (height != null) parts.add('${height}p');
    if (vCodec != null && vCodec.isNotEmpty) parts.add(vCodec.toUpperCase());
    if (sizeGb != null) parts.add('$sizeGb GB');
    if (bitrateMbps != null) parts.add('$bitrateMbps Mbps');
    return parts.isEmpty ? '直连播放' : parts.join(' / ');
  }

  Duration _safeSeekTarget(Duration target, Duration total) {
    if (target <= Duration.zero) return Duration.zero;
    if (total <= Duration.zero) return target;
    if (target < total) return target;
    final rewind = total - const Duration(seconds: 5);
    return rewind > Duration.zero ? rewind : Duration.zero;
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

  Future<void> _resumeToHistoryPosition() async {
    final target = _resumeHintPosition;
    if (target == null || target <= Duration.zero) return;
    if (!_playerService.isInitialized) return;

    final safeTarget = _safeSeekTarget(target, _playerService.duration);
    try {
      final seekFuture = _playerService.seek(safeTarget);
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
    if (_reportedStart || _reportedStop) return;
    final api = _embyApi;
    if (api == null) return;
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return;
    }

    _reportedStart = true;
    final posTicks = _toTicks(_lastPosition);
    final paused = !_playerService.isPlaying;
    try {
      final ps = _playSessionId;
      final ms = _mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await api.reportPlaybackStart(
          token: token,
          baseUrl: baseUrl,
          deviceId: widget.appState.deviceId,
          itemId: widget.itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: posTicks,
          isPaused: paused,
          userId: userId,
        );
      }
    } catch (_) {}
  }

  void _maybeReportPlaybackProgress(Duration position, {bool force = false}) {
    if (_reportedStop) return;
    if (_deferProgressReporting) return;
    if (_progressReportInFlight) return;
    final api = _embyApi;
    if (api == null) return;
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final paused = !_playerService.isPlaying;

    final due = _lastProgressReportAt == null ||
        now.difference(_lastProgressReportAt!) >= const Duration(seconds: 15);
    final pausedChanged = paused != _lastProgressReportPaused &&
        (_lastProgressReportAt == null ||
            now.difference(_lastProgressReportAt!) >=
                const Duration(seconds: 1));
    final shouldReport = force || due || pausedChanged;
    if (!shouldReport) return;

    _lastProgressReportAt = now;
    _lastProgressReportPaused = paused;
    _progressReportInFlight = true;

    final ticks = _toTicks(position);

    // ignore: unawaited_futures
    () async {
      try {
        final ps = _playSessionId;
        final ms = _mediaSourceId;
        if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
          await api.reportPlaybackProgress(
            token: token,
            baseUrl: baseUrl,
            deviceId: widget.appState.deviceId,
            itemId: widget.itemId,
            mediaSourceId: ms,
            playSessionId: ps,
            positionTicks: ticks,
            isPaused: paused,
            userId: userId,
          );
        } else if (userId != null && userId.isNotEmpty) {
          await api.updatePlaybackPosition(
            token: token,
            baseUrl: baseUrl,
            userId: userId,
            itemId: widget.itemId,
            positionTicks: ticks,
          );
        }
      } finally {
        _progressReportInFlight = false;
      }
    }();
  }

  Future<void> _reportPlaybackStoppedBestEffort(
      {bool completed = false}) async {
    if (_reportedStop) return;
    _reportedStop = true;

    final api = _embyApi;
    if (api == null) return;
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return;
    }

    final pos =
        _playerService.isInitialized ? _playerService.position : _lastPosition;
    final dur = _playerService.duration;
    final played = completed ||
        (dur > Duration.zero && pos >= dur - const Duration(seconds: 20));
    final ticks = _toTicks(pos);

    try {
      final ps = _playSessionId;
      final ms = _mediaSourceId;
      if (ps != null && ps.isNotEmpty && ms != null && ms.isNotEmpty) {
        await api.reportPlaybackStopped(
          token: token,
          baseUrl: baseUrl,
          deviceId: widget.appState.deviceId,
          itemId: widget.itemId,
          mediaSourceId: ms,
          playSessionId: ps,
          positionTicks: ticks,
          userId: userId,
        );
      }
    } catch (_) {}

    try {
      if (userId != null && userId.isNotEmpty) {
        await api.updatePlaybackPosition(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          itemId: widget.itemId,
          positionTicks: ticks,
          played: played,
        );
      }
    } catch (_) {}
  }

  bool get _shouldControlSystemUi {
    if (kIsWeb) return false;
    if (widget.isTv) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> _enterImmersiveMode() async {
    if (!_shouldControlSystemUi) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: const [],
      );
    } catch (_) {}
  }

  Future<void> _exitImmersiveMode({bool resetOrientations = false}) async {
    if (!_shouldControlSystemUi) return;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    } catch (_) {}
    if (!resetOrientations) return;
    try {
      await SystemChrome.setPreferredOrientations(const []);
    } catch (_) {}
  }

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
    if (!_shouldControlSystemUi) return;

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

  @override
  void dispose() {
    // ignore: unawaited_futures
    _reportPlaybackStoppedBestEffort();
    // ignore: unawaited_futures
    _exitImmersiveMode(resetOrientations: true);
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _errorSub?.cancel();
    _bufferingSub?.cancel();
    _bufferingPctSub?.cancel();
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
    _playerService.dispose();
    super.dispose();
  }

  void _showControls({bool scheduleHide = true}) {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    // ignore: unawaited_futures
    _exitImmersiveMode();
    if (scheduleHide) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (!_controlsVisible || _isScrubbing) return;
    _controlsHideTimer = Timer(_controlsAutoHideDelay, () {
      if (!mounted || _isScrubbing) return;
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
        final base = _baseUrl!;
        final token = _token!;
        final userId = _userId!;
        final api = _embyApi ??
            EmbyApi(
              hostOrUrl: base,
              preferredScheme: 'https',
              apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
            );
        final info = await api.fetchPlaybackInfo(
          token: token,
          baseUrl: base,
          userId: userId,
          deviceId: widget.appState.deviceId,
          itemId: widget.itemId,
        );
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
    return Scaffold(
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
            child: GlassAppBar(
              enableBlur: enableBlur,
              child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          title: Text(widget.title),
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
                      try {
                        await _playerService.dispose();
                      } catch (_) {}
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
              tooltip: _anime4kPreset.isOff
                  ? 'Anime4K'
                  : 'Anime4K: ${_anime4kPreset.label}',
              icon: Icon(
                _anime4kPreset.isOff
                    ? Icons.auto_fix_high_outlined
                    : Icons.auto_fix_high,
              ),
              onPressed: _showAnime4kSheet,
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
              tooltip: _hwdecOn ? '切换软解' : '切换硬解',
              icon:
                  Icon(_hwdecOn ? Icons.memory : Icons.settings_backup_restore),
              onPressed: () async {
                setState(() {
                  _hwdecOn = !_hwdecOn;
                  _loading = true;
                  _playError = null;
                });
                try {
                  await _playerService.dispose();
                } catch (_) {}
                await _init();
              },
            ),
            IconButton(
              tooltip: _orientationTooltip,
              icon: Icon(_orientationIcon),
              onPressed: _cycleOrientationMode,
            ),
          ],
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
                        ),
                        Positioned.fill(
                          child: DanmakuStage(
                            key: _danmakuKey,
                            enabled: _danmakuEnabled,
                            opacity: _danmakuOpacity,
                            scale: _danmakuScale,
                            speed: _danmakuSpeed,
                            bold: _danmakuBold,
                            scrollMaxLines: _danmakuMaxLines,
                            topMaxLines: _danmakuTopMaxLines,
                            bottomMaxLines: _danmakuBottomMaxLines,
                            preventOverlap: _danmakuPreventOverlap,
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
                                      style:
                                          const TextStyle(color: Colors.white),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTapDown: (_) => _showControls(),
                            child: const SizedBox.expand(),
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
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: SafeArea(
                            top: false,
                            left: false,
                            right: false,
                            minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                            child: AnimatedOpacity(
                              opacity: _controlsVisible ? 1 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: IgnorePointer(
                                ignoring: !_controlsVisible,
                                child: Listener(
                                  onPointerDown: (_) => _showControls(),
                                  child: PlaybackControls(
                                    enabled: controlsEnabled,
                                    position: _lastPosition,
                                    duration: duration,
                                    isPlaying: isPlaying,
                                    onRequestThumbnail: _thumbnailer == null
                                        ? null
                                        : (pos) => _thumbnailer!.getThumbnail(
                                              pos,
                                            ),
                                    onSwitchCore: (!kIsWeb &&
                                            defaultTargetPlatform ==
                                                TargetPlatform.android)
                                        ? _switchCore
                                        : null,
                                    onSwitchVersion: _switchVersion,
                                    onScrubStart: _onScrubStart,
                                    onScrubEnd: _onScrubEnd,
                                    onSeek: (pos) async {
                                      await _playerService.seek(pos);
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
                                          const Duration(seconds: 10);
                                      final pos = target < Duration.zero
                                          ? Duration.zero
                                          : target;
                                      await _playerService.seek(pos);
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
                                          const Duration(seconds: 10);
                                      final pos =
                                          (d > Duration.zero && target > d)
                                              ? d
                                              : target;
                                      await _playerService.seek(pos);
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
    final subs = List<SubtitleTrack>.from(_tracks.subtitle);
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        if (subs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无字幕'),
          );
        }
        final current = _playerService.player.state.track.subtitle;
        return ListView(
          children: subs
              .map(
                (s) => ListTile(
                  title: Text(s.title ?? s.language ?? '字幕 ${s.id}'),
                  trailing: current == s ? const Icon(Icons.check) : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _playerService.player.setSubtitleTrack(s);
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }
}

enum _OrientationMode { auto, landscape, portrait }
