import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_android/exo_tracks.dart' as vp_android;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'play_network_page.dart';
import 'services/dandanplay_api.dart';
import 'services/emby_api.dart';
import 'server_adapters/server_access.dart';
import 'state/app_state.dart';
import 'state/danmaku_preferences.dart';
import 'state/interaction_preferences.dart';
import 'state/preferences.dart';
import 'state/server_profile.dart';
import 'src/player/danmaku.dart';
import 'src/player/danmaku_processing.dart';
import 'src/player/danmaku_stage.dart';
import 'src/player/playback_controls.dart';
import 'src/player/features/core_switch_flow.dart';
import 'src/player/features/episode_picker.dart';
import 'src/player/features/player_gestures.dart';
import 'src/player/features/subtitle_style.dart';
import 'src/player/net_speed.dart';
import 'src/player/network/emby_media_source_utils.dart';
import 'src/player/network/network_playback_backend.dart';
import 'src/player/network/network_playback_reporter.dart';
import 'src/player/shared/player_types.dart';
import 'src/player/shared/system_ui.dart';
import 'src/ui/glass_blur.dart';

class ExoPlayNetworkPage extends StatefulWidget {
  const ExoPlayNetworkPage({
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
  final int? audioStreamIndex;
  final int? subtitleStreamIndex; // Emby MediaStream Index, -1 = off

  @override
  State<ExoPlayNetworkPage> createState() => _ExoPlayNetworkPageState();
}

class _ExoPlayNetworkPageState extends State<ExoPlayNetworkPage>
    with WidgetsBindingObserver {
  ServerAccess? _serverAccess;
  late final NetworkPlaybackBackend _playbackBackend;
  Map<String, String> _httpHeaders = const {};
  VideoPlayerController? _controller;
  Timer? _uiTimer;

  bool _loading = true;
  String? _playError;
  String? _resolvedStream;
  bool _buffering = false;
  Duration _lastBufferedEnd = Duration.zero;
  DateTime? _lastBufferedAt;
  Duration _bufferSpeedSampleEnd = Duration.zero;
  double? _bufferSpeedX;
  double? _netSpeedBytesPerSecond;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime? _lastUiTickAt;
  _OrientationMode _orientationMode = _OrientationMode.auto;
  Duration? _resumeHintPosition;
  bool _showResumeHint = false;
  Timer? _resumeHintTimer;
  Duration? _startOverHintPosition;
  bool _showStartOverHint = false;
  Timer? _startOverHintTimer;
  bool _deferProgressReporting = false;

  late final PlayerGestureController _gestureController;

  static const Duration _controlsAutoHideDelay = Duration(seconds: 3);
  Timer? _controlsHideTimer;
  bool _controlsVisible = true;
  bool _isScrubbing = false;
  bool _remoteEnabled = false;
  final FocusNode _tvSurfaceFocusNode =
      FocusNode(debugLabel: 'network_exo_player_tv_surface');
  final FocusNode _tvPlayPauseFocusNode =
      FocusNode(debugLabel: 'network_exo_player_tv_play_pause');

  VideoViewType _viewType = VideoViewType.platformView;
  bool _switchingViewType = false;

  // Subtitle options (EXO).
  double _subtitleDelaySeconds = 0.0;
  double _subtitleFontSize = 18.0;
  int _subtitlePositionStep = 5; // 0..20, maps to padding-bottom in 5px steps.
  bool _subtitleBold = false;
  String _subtitleText = '';
  bool _subtitlePollInFlight = false;

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
  bool _danmakuPaused = false;

  String? _playSessionId;
  String? _mediaSourceId;
  List<Map<String, dynamic>> _availableMediaSources = const [];
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex;
  int? _selectedSubtitleStreamIndex;
  Duration? _overrideStartPosition;
  bool _overrideResumeImmediately = false;
  late final NetworkPlaybackReporter _playbackReporter;

  late final EpisodePickerController _episodePicker;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isPlaying => _controller?.value.isPlaying ?? false;

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gestureController = PlayerGestureController();
    _serverAccess =
        resolveServerAccess(appState: widget.appState, server: widget.server);
    _playbackReporter = NetworkPlaybackReporter(itemId: widget.itemId);
    _playbackBackend = widget.playbackBackend ??
        EmbyLikeNetworkPlaybackBackend(
          access: _serverAccess,
          baseUrl: _baseUrl!,
          token: _token!,
          userId: _userId!,
          deviceId: widget.appState.deviceId,
          serverType: widget.server?.serverType ?? widget.appState.serverType,
        );
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
        final eps =
            await access.adapter.fetchEpisodes(access.auth, seasonId: seasonId);
        return eps.items;
      },
    )..addListener(() {
        if (mounted) setState(() {});
      });
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    _resumeHintTimer?.cancel();
    _resumeHintTimer = null;
    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _gestureController.dispose();
    _episodePicker.dispose();
    // ignore: unawaited_futures
    _reportPlaybackStoppedBestEffort();
    // ignore: unawaited_futures
    _exitImmersiveMode(resetOrientations: true);
    // ignore: unawaited_futures
    _controller?.dispose();
    _controller = null;
    _tvSurfaceFocusNode.dispose();
    _tvPlayPauseFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (widget.appState.returnHomeBehavior != ReturnHomeBehavior.pause) return;

    final controller = _controller;
    if (controller == null) return;
    if (!controller.value.isInitialized) return;
    if (!controller.value.isPlaying) return;
    // ignore: unawaited_futures
    controller.pause();
    _applyDanmakuPauseState(true);
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
        builder: (_) => ExoPlayNetworkPage(
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
      final access = _serverAccess;
      if (access != null) {
        final item = await access.adapter.fetchItemDetail(
          access.auth,
          itemId: widget.itemId,
        );
        fileName = _buildDanmakuMatchName(item);
        fileSizeBytes = item.sizeBytes ?? 0;
        final ticks = item.runTimeTicks ?? 0;
        if (ticks > 0) {
          videoDurationSeconds = (ticks / 10000000).round().clamp(0, 1 << 31);
        }
      }
    } catch (_) {}

    if (videoDurationSeconds <= 0) {
      videoDurationSeconds = _duration.inSeconds;
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
        _syncDanmakuCursor(_position);
      });

      await _ensureDanmakuVisible();

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
    if (_duration <= Duration.zero ||
        _danmakuSourceIndex < 0 ||
        _danmakuSourceIndex >= _danmakuSources.length) {
      _danmakuHeatmap = const [];
      return;
    }
    _danmakuHeatmap = buildDanmakuHeatmap(
      _danmakuSources[_danmakuSourceIndex].items,
      duration: _duration,
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
      _syncDanmakuCursor(_position);
    });

    await _ensureDanmakuVisible();
  }

  Future<void> _ensureDanmakuVisible() async {
    if (!_isAndroid) return;
    if (_viewType == VideoViewType.textureView) return;
    if (_switchingViewType) return;

    final stream = _resolvedStream;
    if (stream == null || stream.trim().isEmpty) {
      setState(() => _viewType = VideoViewType.textureView);
      return;
    }

    _switchingViewType = true;
    try {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('为显示弹幕已切换到纹理渲染（部分 HDR/DV 片源可能偏色）'),
              duration: Duration(milliseconds: 1200),
            ),
          );
      }
      await _reopenStreamWithViewType(VideoViewType.textureView);
    } finally {
      _switchingViewType = false;
    }
  }

  Future<void> _reopenStreamWithViewType(VideoViewType next) async {
    if (!_isAndroid) return;
    final stream = _resolvedStream;
    if (stream == null || stream.trim().isEmpty) return;
    if (_viewType == next && _controller != null) return;

    final wasPlaying = _isPlaying;
    final pos = _position;

    _uiTimer?.cancel();
    _uiTimer = null;

    final prev = _controller;
    _controller = null;
    if (prev != null) {
      await prev.dispose();
    }

    setState(() {
      _viewType = next;
      _buffering = false;
      _playError = null;
      _subtitleText = '';
      _subtitlePollInFlight = false;
    });

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(stream),
      httpHeaders: _httpHeaders,
      viewType: next,
    );
    _controller = controller;
    await controller.initialize();
    await _applyExoSubtitleOptions();

    final target = _safeSeekTarget(pos, controller.value.duration);
    if (target > Duration.zero) {
      try {
        await controller.seekTo(target).timeout(const Duration(seconds: 3));
        _position = target;
        _syncDanmakuCursor(target);
      } catch (_) {}
    }

    if (wasPlaying) {
      await controller.play();
    } else {
      await controller.pause();
    }

    _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final c = _controller;
      if (!mounted || c == null) return;
      final v = c.value;
      _buffering = v.isBuffering;
      _position = v.position;
      _duration = v.duration;

      _applyDanmakuPauseState(_buffering || !_isPlaying);
      _drainDanmaku(_position);
      if (!_isAndroid || _viewType == VideoViewType.textureView) {
        // ignore: unawaited_futures
        _pollSubtitleText();
      }

      _maybeReportPlaybackProgress(_position);

      if (!_playbackReporter.isStopped &&
          _duration > Duration.zero &&
          !_buffering &&
          !v.isPlaying &&
          _position >= _duration - const Duration(milliseconds: 200)) {
        // ignore: unawaited_futures
        _reportPlaybackStoppedBestEffort(completed: true);
      }

      final now = DateTime.now();
      final shouldRebuild = _lastUiTickAt == null ||
          now.difference(_lastUiTickAt!) >= const Duration(milliseconds: 250);
      if (shouldRebuild) {
        _lastUiTickAt = now;
        setState(() {});
      }
    });

    _scheduleControlsHide();
    if (mounted) setState(() {});
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
                        child: Text(
                          '弹幕',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          await _pickDanmakuFile();
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.upload_file),
                        label: const Text('本地'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: onlineLoading || _loading
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.cloud_download_outlined),
                        label: const Text('在线'),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    value: _danmakuEnabled,
                    onChanged: (v) async {
                      setState(() => _danmakuEnabled = v);
                      if (!v) {
                        _danmakuKey.currentState?.clear();
                      } else if (hasSources) {
                        await _ensureDanmakuVisible();
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
                            : (v) async {
                                if (v == null) return;
                                setState(() {
                                  _danmakuSourceIndex = v;
                                  _danmakuEnabled = true;
                                  _rebuildDanmakuHeatmap();
                                  _syncDanmakuCursor(_position);
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
                                await _ensureDanmakuVisible();
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

  bool get _gesturesEnabled {
    final controller = _controller;
    return controller != null &&
        controller.value.isInitialized &&
        !_loading &&
        _playError == null;
  }

  int get _seekBackSeconds => widget.appState.seekBackwardSeconds;
  int get _seekForwardSeconds => widget.appState.seekForwardSeconds;

  Future<void> _togglePlayPause({bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    final controller = _controller!;
    _showControls();
    if (controller.value.isPlaying) {
      await controller.pause();
      _applyDanmakuPauseState(true);
      _maybeReportPlaybackProgress(controller.value.position, force: true);
      if (showOverlay) {
        _gestureController.showOverlay(icon: Icons.pause, text: '暂停');
      }
      if (mounted) setState(() {});
      return;
    }
    await controller.play();
    _applyDanmakuPauseState(false);
    _maybeReportPlaybackProgress(controller.value.position, force: true);
    if (showOverlay) {
      _gestureController.showOverlay(icon: Icons.play_arrow, text: '播放');
    }
    if (mounted) setState(() {});
  }

  Future<void> _seekRelative(Duration delta, {bool showOverlay = true}) async {
    if (!_gesturesEnabled) return;
    final controller = _controller!;
    final duration = controller.value.duration;
    final current = _position;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;

    await controller.seekTo(target);
    _position = target;
    _maybeReportPlaybackProgress(controller.value.position, force: true);
    _syncDanmakuCursor(target);
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
    final controller = _controller!;
    await controller.seekTo(target);
    _position = target;
    _maybeReportPlaybackProgress(controller.value.position, force: true);
    _syncDanmakuCursor(target);
    if (mounted) setState(() {});
  }

  Future<void> _switchCore() async {
    final pos = _position;
    _maybeReportPlaybackProgress(pos, force: true);
    final ok = await switchPlayerCoreOrToast(
      context: context,
      appState: widget.appState,
      target: PlayerCore.mpv,
    );
    if (!ok) return;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayNetworkPage(
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
    final pos = _position;
    _maybeReportPlaybackProgress(pos, force: true);

    var sources = _availableMediaSources;
    if (sources.isEmpty) {
      try {
        final access = _serverAccess;
        if (access == null) {
          sources = const [];
        } else {
          final info = await access.adapter.fetchPlaybackInfo(
            access.auth,
            itemId: widget.itemId,
            exoPlayer: true,
          );
          sources = info.mediaSources.cast<Map<String, dynamic>>();
          _availableMediaSources = List<Map<String, dynamic>>.from(sources);
        }
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
    });
    await _init();
  }

  Future<void> _init() async {
    _uiTimer?.cancel();
    _uiTimer = null;
    _playError = null;
    _loading = true;
    _buffering = false;
    _lastBufferedEnd = Duration.zero;
    _lastBufferedAt = null;
    _bufferSpeedSampleEnd = Duration.zero;
    _bufferSpeedX = null;
    _netSpeedBytesPerSecond = null;
    _nextDanmakuIndex = 0;
    _danmakuKey.currentState?.clear();
    _danmakuSources.clear();
    _danmakuSourceIndex = -1;
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
    _danmakuHeatmap = const [];
    _danmakuPaused = false;

    _playbackReporter.reset();

    _playSessionId = null;
    _mediaSourceId = null;
    _resolvedStream = null;
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
    _subtitleText = '';
    _subtitlePollInFlight = false;
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;

    final prev = _controller;
    _controller = null;
    if (prev != null) {
      await prev.dispose();
    }

    if (!mounted) return;
    setState(() {});

    try {
      if (!_isAndroid) {
        throw Exception('Exo 内核仅支持 Android');
      }
      final resolved = await _buildStream();
      _resolvedStream = resolved.streamUrl;
      _httpHeaders = resolved.httpHeaders;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(_resolvedStream!),
        httpHeaders: _httpHeaders,
        // Use platform view on Android to avoid color issues with some HDR/Dolby Vision sources.
        // (Texture-based rendering may show green/purple tint on certain P8 files.)
        viewType: _viewType,
      );
      _controller = controller;
      await controller.initialize();
      await _applyExoSubtitleOptions();
      final start = _overrideStartPosition ?? widget.startPosition;
      final resumeImmediately =
          _overrideResumeImmediately || widget.resumeImmediately;
      _overrideStartPosition = null;
      _overrideResumeImmediately = false;
      if (start != null && start > Duration.zero) {
        final target = _safeSeekTarget(start, controller.value.duration);
        _deferProgressReporting = true;
        if (resumeImmediately) {
          final ok = await _seekToPositionBestEffort(controller, target);
          final applied = controller.value.position;
          _position = applied;
          _syncDanmakuCursor(applied);
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
      await controller.play();

      _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final c = _controller;
        if (!mounted || c == null) return;
        final v = c.value;
        final now = DateTime.now();
        _buffering = v.isBuffering;
        _position = v.position;
        _duration = v.duration;

        var bufferedEnd = Duration.zero;
        for (final r in v.buffered) {
          if (r.end > bufferedEnd) bufferedEnd = r.end;
        }
        _lastBufferedEnd = bufferedEnd;

        if (widget.appState.showBufferSpeed) {
          final refreshSeconds = widget.appState.bufferSpeedRefreshSeconds
              .clamp(0.2, 3.0)
              .toDouble();
          final refreshMs = (refreshSeconds * 1000).round();

          final prevAt = _lastBufferedAt;
          if (prevAt == null) {
            _bufferSpeedX = null;
            _netSpeedBytesPerSecond = null;
            _lastBufferedAt = now;
            _bufferSpeedSampleEnd = bufferedEnd;
          } else {
            final dtMs = now.difference(prevAt).inMilliseconds;
            if (dtMs >= refreshMs) {
              final deltaMs =
                  (bufferedEnd - _bufferSpeedSampleEnd).inMilliseconds;
              _lastBufferedAt = now;
              _bufferSpeedSampleEnd = bufferedEnd;
              _bufferSpeedX =
                  (dtMs > 0 && deltaMs >= 0) ? (deltaMs / dtMs) : null;

              final bitrate = _currentMediaSourceBitrateBitsPerSecond();
              final x = _bufferSpeedX;
              if (bitrate != null && bitrate > 0 && x != null) {
                final speed = x * bitrate / 8.0;
                final prev = _netSpeedBytesPerSecond;
                _netSpeedBytesPerSecond =
                    prev == null ? speed : (prev * 0.7 + speed * 0.3);
              } else {
                _netSpeedBytesPerSecond = null;
              }
            }
          }
        } else {
          _bufferSpeedX = null;
          _netSpeedBytesPerSecond = null;
          _lastBufferedAt = null;
          _bufferSpeedSampleEnd = bufferedEnd;
        }

        _applyDanmakuPauseState(_buffering || !_isPlaying);
        _drainDanmaku(_position);
        if (!_isAndroid || _viewType == VideoViewType.textureView) {
          // ignore: unawaited_futures
          _pollSubtitleText();
        }

        _maybeReportPlaybackProgress(_position);

        if (!_playbackReporter.isStopped &&
            _duration > Duration.zero &&
            !_buffering &&
            !v.isPlaying &&
            _position >= _duration - const Duration(milliseconds: 200)) {
          // ignore: unawaited_futures
          _reportPlaybackStoppedBestEffort(completed: true);
        }
        final shouldRebuild = _lastUiTickAt == null ||
            now.difference(_lastUiTickAt!) >= const Duration(milliseconds: 250);
        if (shouldRebuild) {
          _lastUiTickAt = now;
          setState(() {});
        }
      });

      _maybeAutoLoadOnlineDanmaku();

      if (!_deferProgressReporting) {
        // ignore: unawaited_futures
        _reportPlaybackStartBestEffort();
      }
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

  Future<NetworkStreamResolution> _buildStream() async {
    _playSessionId = null;
    _mediaSourceId = null;
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
      allowTranscoding: true,
      exoPlayer: true,
    );
    _availableMediaSources = res.mediaSources;
    _selectedMediaSourceId = res.selectedMediaSourceId;
    _playSessionId = res.playSessionId;
    _mediaSourceId = res.mediaSourceId;
    return res;
  }

  static String _fmtClock(Duration d) {
    return formatClock(d);
  }

  static int? _asInt(dynamic value) {
    return embyAsInt(value);
  }

  int? _currentMediaSourceBitrateBitsPerSecond() {
    final sources = _availableMediaSources;
    if (sources.isEmpty) return null;

    final id = (_mediaSourceId ?? _selectedMediaSourceId ?? '').trim();
    final ms = id.isEmpty
        ? sources.first
        : sources.firstWhere(
            (s) => (s['Id']?.toString() ?? '').trim() == id,
            orElse: () => sources.first,
          );

    final bitrate = _asInt(ms['Bitrate']);
    if (bitrate == null || bitrate <= 0) return null;
    return bitrate;
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

  static const Duration _kResumeSeekTolerance = Duration(seconds: 1);

  bool _seekCloseEnough(Duration position, Duration target) {
    return (position - target).inMilliseconds.abs() <=
        _kResumeSeekTolerance.inMilliseconds;
  }

  Future<bool> _seekToPositionBestEffort(
      VideoPlayerController controller, Duration target) async {
    if (!controller.value.isInitialized) return false;
    if (target <= Duration.zero) return true;

    Future<void> attemptSeek() async {
      try {
        final seekFuture = controller.seekTo(target);
        await seekFuture.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    await attemptSeek();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (_seekCloseEnough(controller.value.position, target)) return true;

    // Some streams (e.g., certain HLS transcodes) only allow seeking after playback starts.
    if (!controller.value.isPlaying) {
      try {
        await controller.play();
      } catch (_) {}
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await attemptSeek();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (_seekCloseEnough(controller.value.position, target)) return true;
    }

    return _seekCloseEnough(controller.value.position, target);
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
        _maybeReportPlaybackProgress(_position, force: true);
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
    final controller = _controller;
    if (controller == null) return;
    if (!controller.value.isInitialized) return;
    _showControls(scheduleHide: false);

    try {
      final seekFuture = controller.seekTo(Duration.zero);
      await seekFuture.timeout(const Duration(seconds: 3));
    } catch (_) {}

    _position = Duration.zero;
    _syncDanmakuCursor(Duration.zero);
    _maybeReportPlaybackProgress(_position, force: true);

    _startOverHintTimer?.cancel();
    _startOverHintTimer = null;
    _showStartOverHint = false;
    if (mounted) setState(() {});
  }

  Future<void> _resumeToHistoryPosition() async {
    final controller = _controller;
    final target = _resumeHintPosition;
    if (controller == null) return;
    if (target == null || target <= Duration.zero) return;
    if (!controller.value.isInitialized) return;

    final safeTarget = _safeSeekTarget(target, controller.value.duration);
    try {
      final seekFuture = controller.seekTo(safeTarget);
      await seekFuture.timeout(const Duration(seconds: 3));
      _position = safeTarget;
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
      _maybeReportPlaybackProgress(_position, force: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _reportPlaybackStartBestEffort() async {
    await _playbackReporter.reportPlaybackStartBestEffort(
      access: _serverAccess,
      playSessionId: _playSessionId,
      mediaSourceId: _mediaSourceId,
      position: _position,
      paused: !_isPlaying,
    );
  }

  void _maybeReportPlaybackProgress(Duration position, {bool force = false}) {
    if (_deferProgressReporting) return;
    _playbackReporter.maybeReportPlaybackProgressBestEffort(
      access: _serverAccess,
      playSessionId: _playSessionId,
      mediaSourceId: _mediaSourceId,
      position: position,
      paused: !_isPlaying,
      force: force,
    );
  }

  Future<void> _reportPlaybackStoppedBestEffort(
      {bool completed = false}) async {
    await _playbackReporter.reportPlaybackStoppedBestEffort(
      access: _serverAccess,
      playSessionId: _playSessionId,
      mediaSourceId: _mediaSourceId,
      position: _position,
      duration: _duration,
      completed: completed,
    );
  }

  Future<void> _enterImmersiveMode() => enterImmersiveMode(isTv: widget.isTv);

  Future<void> _exitImmersiveMode({bool resetOrientations = false}) =>
      exitImmersiveMode(
        isTv: widget.isTv,
        resetOrientations: resetOrientations,
      );

  void _showNotSupported(String feature) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Exo 内核暂不支持：$feature')),
      );
  }

  String _audioTrackTitle(VideoAudioTrack t) {
    final label = (t.label ?? '').trim();
    if (label.isNotEmpty) return label;
    final lang = (t.language ?? '').trim();
    if (lang.isNotEmpty) return lang;
    return '音轨 ${t.id}';
  }

  String _audioTrackSubtitle(VideoAudioTrack t) {
    final parts = <String>[];
    final codec = (t.codec ?? '').trim();
    if (codec.isNotEmpty) parts.add(codec);
    if (t.channelCount != null && t.channelCount! > 0) {
      parts.add('${t.channelCount}ch');
    }
    if (t.sampleRate != null && t.sampleRate! > 0) {
      parts.add('${t.sampleRate}Hz');
    }
    if (t.bitrate != null && t.bitrate! > 0) {
      parts.add('${(t.bitrate! / 1000).round()} kbps');
    }
    return parts.join('  ');
  }

  Future<void> _showAudioTracks(BuildContext context) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;

    final platform = VideoPlayerPlatform.instance;
    if (!platform.isAudioTrackSupportAvailable()) {
      _showNotSupported('音轨切换');
      return;
    }

    late final List<VideoAudioTrack> tracks;
    try {
      tracks = await platform.getAudioTracks(playerId);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取音轨失败：$e')),
      );
      return;
    }

    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        if (tracks.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('暂无音轨'),
          );
        }
        return ListView(
          children: tracks
              .map(
                (t) => ListTile(
                  title: Text(_audioTrackTitle(t)),
                  subtitle: Text(_audioTrackSubtitle(t)),
                  trailing: t.isSelected ? const Icon(Icons.check) : null,
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    try {
                      await platform.selectAudioTrack(playerId, t.id);
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('切换音轨失败：$e')),
                      );
                    }
                  },
                ),
              )
              .toList(),
        );
      },
    );
  }

  String _subtitleTrackTitle(vp_android.ExoPlayerSubtitleTrackData t) {
    final label = (t.label ?? '').trim();
    if (label.isNotEmpty) return label;
    final lang = (t.language ?? '').trim();
    if (lang.isNotEmpty) return lang;
    return '字幕 ${t.groupIndex}_${t.trackIndex}';
  }

  String _subtitleTrackSubtitle(vp_android.ExoPlayerSubtitleTrackData t) {
    final parts = <String>[];
    final codec = (t.codec ?? '').trim();
    final mime = (t.mimeType ?? '').trim();
    if (codec.isNotEmpty) parts.add(codec);
    if (mime.isNotEmpty) parts.add(mime);
    return parts.join('  ');
  }

  double get _subtitleBottomPadding =>
      subtitleBottomPaddingPx(_subtitlePositionStep);

  Future<void> _applyExoSubtitleOptions() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;
    await applyExoSubtitleOptions(
      playerId: playerId,
      delaySeconds: _subtitleDelaySeconds,
      fontSize: _subtitleFontSize,
      positionStep: _subtitlePositionStep,
      bold: _subtitleBold,
    );
  }

  Future<void> _pollSubtitleText() async {
    if (_subtitlePollInFlight) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_isAndroid && _viewType != VideoViewType.textureView) return;

    _subtitlePollInFlight = true;
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final playerId = controller.playerId;
      final api = vp_android.VideoPlayerInstanceApi(
        messageChannelSuffix: playerId.toString(),
      );
      final text = await api.getSubtitleText();
      if (!mounted) return;
      if (text != _subtitleText) {
        setState(() => _subtitleText = text);
      }
    } catch (_) {
      // ignore
    } finally {
      _subtitlePollInFlight = false;
    }
  }

  Future<void> _showSubtitleTracks(BuildContext context) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;

    final api = vp_android.VideoPlayerInstanceApi(
      messageChannelSuffix: playerId.toString(),
    );

    Future<List<vp_android.ExoPlayerSubtitleTrackData>> fetchTracks() async {
      final data = await api.getSubtitleTracks();
      return data.exoPlayerTracks ??
          const <vp_android.ExoPlayerSubtitleTrackData>[];
    }

    late List<vp_android.ExoPlayerSubtitleTrackData> tracks;
    try {
      tracks = await fetchTracks();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('获取字幕失败：$e')),
      );
      return;
    }

    if (!context.mounted) return;
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
            String selectedKey = 'off';
            for (final t in tracks) {
              if (t.isSelected) {
                selectedKey = '${t.groupIndex}_${t.trackIndex}';
                break;
              }
            }

            Future<void> refreshTracks() async {
              try {
                tracks = await fetchTracks();
                setSheetState(() {});
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('获取字幕失败：$e')),
                );
              }
            }

            Future<void> selectTrackKey(String key) async {
              try {
                if (key == 'off') {
                  await api.deselectSubtitleTrack();
                } else {
                  final parts = key.split('_');
                  final g = int.parse(parts[0]);
                  final t = int.parse(parts[1]);
                  await api.selectSubtitleTrack(g, t);
                }
                await refreshTracks();
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('切换字幕失败：$e')),
                );
              }
            }

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
                await api.addSubtitleSource(path, null, null, f.name);
                await refreshTracks();
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text('添加字幕失败：$e')),
                );
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
                      signed: false,
                    ),
                    decoration: const InputDecoration(
                      hintText: '单位：秒，例如 0.5',
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
              setState(() => _subtitleDelaySeconds = value.clamp(0.0, 60.0));
              await _applyExoSubtitleOptions();
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
                      RadioGroup<String>(
                        groupValue: selectedKey,
                        onChanged: (value) {
                          if (value == null) return;
                          // ignore: unawaited_futures
                          selectTrackKey(value);
                        },
                        child: Column(
                          children: [
                            const RadioListTile<String>(
                              value: 'off',
                              title: Text('关闭'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                            ),
                            if (tracks.isEmpty)
                              const Padding(
                                padding: EdgeInsets.fromLTRB(40, 0, 0, 8),
                                child: Text('暂无字幕'),
                              ),
                            for (final t in tracks)
                              RadioListTile<String>(
                                value: '${t.groupIndex}_${t.trackIndex}',
                                title: Text(_subtitleTrackTitle(t)),
                                subtitle: Text(_subtitleTrackSubtitle(t)),
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                              ),
                          ],
                        ),
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
                              setState(() {
                                _subtitleDelaySeconds =
                                    (_subtitleDelaySeconds - 0.1)
                                        .clamp(0.0, 60.0)
                                        .toDouble();
                              });
                              await _applyExoSubtitleOptions();
                              setSheetState(() {});
                            },
                            icon: Icons.remove,
                            tooltip: '-0.1s',
                          ),
                          Text('${_subtitleDelaySeconds.toStringAsFixed(1)}s'),
                          miniIconButton(
                            onPressed: () async {
                              setState(() {
                                _subtitleDelaySeconds =
                                    (_subtitleDelaySeconds + 0.1)
                                        .clamp(0.0, 60.0)
                                        .toDouble();
                              });
                              await _applyExoSubtitleOptions();
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
                              setState(() => _subtitleDelaySeconds = 0.0);
                              await _applyExoSubtitleOptions();
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
                        onChangeEnd: (_) async {
                          await _applyExoSubtitleOptions();
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
                        onChangeEnd: (_) async {
                          await _applyExoSubtitleOptions();
                          setSheetState(() {});
                        },
                      ),
                      trailing: Text('$_subtitlePositionStep'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('粗体'),
                      value: _subtitleBold,
                      onChanged: (v) async {
                        setState(() => _subtitleBold = v);
                        await _applyExoSubtitleOptions();
                        setSheetState(() {});
                      },
                    ),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      enabled: false,
                      title: Text('强制覆盖 ASS/SSA 字幕'),
                      subtitle: Text('仅 MPV 支持'),
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

  String get _orientationTooltip {
    switch (_orientationMode) {
      case _OrientationMode.auto:
        return '自动旋转';
      case _OrientationMode.landscape:
        return '锁定横屏';
      case _OrientationMode.portrait:
        return '锁定竖屏';
    }
  }

  IconData get _orientationIcon {
    switch (_orientationMode) {
      case _OrientationMode.auto:
        return Icons.screen_rotation;
      case _OrientationMode.landscape:
        return Icons.screen_lock_landscape;
      case _OrientationMode.portrait:
        return Icons.screen_lock_portrait;
    }
  }

  Future<void> _cycleOrientationMode() async {
    final next = switch (_orientationMode) {
      _OrientationMode.auto => _OrientationMode.landscape,
      _OrientationMode.landscape => _OrientationMode.portrait,
      _OrientationMode.portrait => _OrientationMode.auto,
    };

    if (mounted) {
      setState(() => _orientationMode = next);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_orientationTooltip),
            duration: const Duration(milliseconds: 800),
          ),
        );
    } else {
      _orientationMode = next;
    }

    await _applyOrientationForMode();
  }

  Future<void> _applyOrientationForMode() async {
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
        orientations = const [];
        break;
    }

    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isReady = controller != null && controller.value.isInitialized;
    final controlsEnabled = isReady && !_loading && _playError == null;
    final stream = _resolvedStream;
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
                        onPressed: _loading ? null : _init,
                      ),
                      if (stream != null && stream.isNotEmpty)
                        IconButton(
                          tooltip: '复制链接',
                          icon: const Icon(Icons.link),
                          onPressed: () async {
                            await Clipboard.setData(
                                ClipboardData(text: stream));
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
                        tooltip: '软/硬解切换',
                        icon: const Icon(Icons.memory),
                        onPressed: () => _showNotSupported('软/硬解切换'),
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
                child: isReady
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: AspectRatio(
                              aspectRatio: controller.value.aspectRatio == 0
                                  ? 16 / 9
                                  : controller.value.aspectRatio,
                              child: VideoPlayer(controller),
                            ),
                          ),
                          Positioned.fill(
                            child: DanmakuStage(
                              key: _danmakuKey,
                              enabled: _danmakuEnabled,
                              opacity: _danmakuOpacity,
                              scale: _danmakuScale,
                              speed: _danmakuSpeed,
                              timeScale: controller.value.playbackSpeed,
                              bold: _danmakuBold,
                              scrollMaxLines: _danmakuMaxLines,
                              topMaxLines: _danmakuTopMaxLines,
                              bottomMaxLines: _danmakuBottomMaxLines,
                              preventOverlap: _danmakuPreventOverlap,
                            ),
                          ),
                          if ((!_isAndroid ||
                                  _viewType == VideoViewType.textureView) &&
                              _subtitleText.trim().isNotEmpty)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      _subtitleBottomPadding,
                                    ),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.55,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        child: Text(
                                          _subtitleText.trim(),
                                          textAlign: TextAlign.center,
                                          style: buildSubtitleOverlayTextStyle(
                                            fontSize: _subtitleFontSize,
                                            bold: _subtitleBold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
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
                                    color:
                                        Colors.black.withValues(alpha: alpha),
                                  );
                                },
                              ),
                            ),
                          ),
                          if (_buffering)
                            Positioned.fill(
                              child: ColoredBox(
                                color: Colors.black26,
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const CircularProgressIndicator(),
                                      if (widget.appState.showBufferSpeed)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 12),
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
                              position: _position,
                              duration: controller.value.duration,
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
                              gestureVolumeEnabled:
                                  widget.appState.gestureVolume,
                              gestureLongPressEnabled:
                                  widget.appState.gestureLongPressSpeed,
                              longPressSlideEnabled:
                                  widget.appState.longPressSlideSpeed,
                              longPressSpeedMultiplier:
                                  widget.appState.longPressSpeedMultiplier,
                              getPlaybackRate: controlsEnabled
                                  ? () => controller.value.playbackSpeed
                                  : null,
                              onSetPlaybackRate: controlsEnabled
                                  ? (rate) async {
                                      await controller.setPlaybackSpeed(rate);
                                      if (mounted) setState(() {});
                                    }
                                  : null,
                              onSetVolume: controlsEnabled
                                  ? (volume) => controller.setVolume(volume)
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
                                        position: _position,
                                        buffered: _lastBufferedEnd,
                                        duration: _duration,
                                        isPlaying: _isPlaying,
                                        playbackRate:
                                            controller.value.playbackSpeed,
                                        onSetPlaybackRate: (rate) async {
                                          _showControls();
                                          await controller.setPlaybackSpeed(
                                            rate,
                                          );
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
                                        onOpenEpisodePicker:
                                            _canShowEpisodePickerButton
                                                ? _toggleEpisodePicker
                                                : null,
                                        onScrubStart: _onScrubStart,
                                        onScrubEnd: _onScrubEnd,
                                        onSeek: (pos) async {
                                          await controller.seekTo(pos);
                                          _maybeReportPlaybackProgress(
                                            pos,
                                            force: true,
                                          );
                                          _syncDanmakuCursor(pos);
                                          if (mounted) setState(() {});
                                        },
                                        onPlay: () async {
                                          _showControls();
                                          await controller.play();
                                          _maybeReportPlaybackProgress(
                                            controller.value.position,
                                            force: true,
                                          );
                                          _applyDanmakuPauseState(false);
                                          if (mounted) setState(() {});
                                        },
                                        onPause: () async {
                                          _showControls();
                                          await controller.pause();
                                          _maybeReportPlaybackProgress(
                                            controller.value.position,
                                            force: true,
                                          );
                                          _applyDanmakuPauseState(true);
                                          if (mounted) setState(() {});
                                        },
                                        onSeekBackward: () async {
                                          _showControls();
                                          final target = _position -
                                              Duration(
                                                  seconds: _seekBackSeconds);
                                          final pos = target < Duration.zero
                                              ? Duration.zero
                                              : target;
                                          await controller.seekTo(pos);
                                          _maybeReportPlaybackProgress(
                                            controller.value.position,
                                            force: true,
                                          );
                                          _syncDanmakuCursor(pos);
                                          if (mounted) setState(() {});
                                        },
                                        onSeekForward: () async {
                                          _showControls();
                                          final d = _duration;
                                          final target = _position +
                                              Duration(
                                                  seconds: _seekForwardSeconds);
                                          final pos =
                                              (d > Duration.zero && target > d)
                                                  ? d
                                                  : target;
                                          await controller.seekTo(pos);
                                          _maybeReportPlaybackProgress(
                                            controller.value.position,
                                            force: true,
                                          );
                                          _syncDanmakuCursor(pos);
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
                              _playError!,
                              style: const TextStyle(color: Colors.redAccent),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : const Center(child: CircularProgressIndicator()),
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

enum _PlayerMenuAction { switchCore, switchVersion }

typedef _OrientationMode = OrientationMode;
