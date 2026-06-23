import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/playback_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_registry.dart';

/// 直链播放页的导航参数（经 go_router 的 `extra` 传递，因含 headers 不走 path）。
class SourcePlayArgs {
  final ServerConfig server;
  final SourceEntry entry;
  const SourcePlayArgs({required this.server, required this.entry});
}

/// 网盘 / 聚合源「直链播放页」（三端共用的初版播放器）。
///
/// 与 Emby 的 [PlayerScreen] 不同：不抓 Emby PlaybackInfo，而是直接用
/// [MediaSourceBackend.resolvePlay] 得到的 URL + 逐流 headers 喂给
/// [VideoPlayerService]。短效直链（夸克 302）由 streamUrlResolver 在过期后
/// 重解析续播。初版只提供最基本的播放/暂停/进度控制。
class SourcePlayerScreen extends ConsumerStatefulWidget {
  final ServerConfig server;
  final SourceEntry entry;

  const SourcePlayerScreen({
    super.key,
    required this.server,
    required this.entry,
  });

  @override
  ConsumerState<SourcePlayerScreen> createState() => _SourcePlayerScreenState();
}

class _SourcePlayerScreenState extends ConsumerState<SourcePlayerScreen> {
  late final VideoPlayerService _player;
  late final MediaSourceBackend _backend;

  String? _error;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerService();
    _player.addListener(_onPlayerChanged);
    _backend = mediaSourceBackendFor(widget.server.sourceKind);
    _enterImmersive();
    _resolveAndPlay();
  }

  Future<void> _enterImmersive() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _exitImmersive() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  void _onPlayerChanged() {
    if (!_disposed && mounted) setState(() {});
  }

  Future<void> _resolveAndPlay() async {
    try {
      final play = await _backend.resolvePlay(widget.server, widget.entry);
      if (_disposed) return;

      final coreString = normalizePlayerCore(ref.read(playerCoreProvider));
      final coreType = switch (coreString) {
        'mpv' => PlayerCoreType.mpv,
        'nativeMpv' => PlayerCoreType.nativeMpv,
        _ => PlayerCoreType.exoPlayer,
      };
      final hardwareDecoding = ref.read(hardwareDecodingProvider);
      final useLibass = coreType == PlayerCoreType.exoPlayer
          ? ref.read(exoLibassProvider)
          : false;
      final gpuNext = coreType == PlayerCoreType.nativeMpv &&
          ref.read(gpuNextEnabledProvider);
      final surfaceViewId = coreType == PlayerCoreType.nativeMpv
          ? DateTime.now().microsecondsSinceEpoch
          : null;

      await _player.initialize(
        videoUrl: play.url,
        // 网盘源无 Emby itemId：用源服务器 id + 文件 id 拼一个稳定的合成标识，
        // 仅用于服务内部记账，不参与 Emby 上报。
        itemId: 'src:${widget.server.id}:${widget.entry.id}',
        coreType: coreType,
        hardwareDecoding: hardwareDecoding,
        useLibass: useLibass,
        useGpuNext: gpuNext,
        surfaceViewId: surfaceViewId,
        httpHeaders: play.httpHeaders.isEmpty ? null : play.httpHeaders,
        userAgentOverride: play.userAgentOverride,
        // 网盘直链按 302 短效处理：过期后回调本方法重解析（headers 不变，仅换 URL）。
        streamUrlResolver: () async {
          final fresh = await _backend.resolvePlay(widget.server, widget.entry);
          return (url: fresh.url, fallbackUrl: null);
        },
        streamUrlTtl: const Duration(minutes: 3),
      );
      if (_disposed) return;
      await _player.play();
      _scheduleHideControls();
    } on SourceException catch (e) {
      if (!_disposed) setState(() => _error = e.message);
    } catch (e) {
      if (!_disposed) setState(() => _error = '播放失败: $e');
    }
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!_disposed && mounted && _player.isPlaying) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  Future<void> _togglePlay() async {
    if (_player.isPlaying) {
      await _player.pause();
      _hideTimer?.cancel();
      setState(() => _controlsVisible = true);
    } else {
      await _player.play();
      _scheduleHideControls();
    }
  }

  void _seekBy(int seconds) {
    final target = _player.position + Duration(seconds: seconds);
    final dur = _player.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    _player.seekTo(clamped);
    setState(() => _controlsVisible = true);
    _scheduleHideControls();
  }

  /// D-pad / 键盘遥控（TV 必需，桌面亦可用）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _toggleControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _disposed = true;
    _hideTimer?.cancel();
    _player.removeListener(_onPlayerChanged);
    _player.dispose();
    _exitImmersive();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_error == null && _player.isInitialized)
              Center(child: _player.buildVideo())
            else
              const SizedBox.shrink(),
            if (_error != null) _buildError() else if (!_player.isInitialized) _buildLoading(),
            if (_player.hasError && _error == null) _buildPlayerError(),
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _buildControls(),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text('正在解析播放地址…', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 24),
            FilledButton.tonal(
              onPressed: () {
                setState(() => _error = null);
                _resolveAndPlay();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerError() {
    return Center(
      child: Text(_player.errorMessage ?? '播放出错',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70)),
    );
  }

  Widget _buildControls() {
    final pos = _player.position;
    final dur = _player.duration;
    return Column(
      children: [
        // 顶栏：返回 + 标题
        Container(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            right: 16,
            bottom: 8,
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  widget.entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        // 中部：播放/暂停 + 缓冲
        if (_player.isBuffering)
          const CircularProgressIndicator(color: Colors.white)
        else
          IconButton(
            iconSize: 64,
            icon: Icon(
              _player.isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_filled,
              color: Colors.white,
            ),
            onPressed: _togglePlay,
          ),
        const Spacer(),
        // 底栏：进度条
        Container(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 12,
            top: 8,
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black54, Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              Text(_fmt(pos), style: const TextStyle(color: Colors.white70)),
              Expanded(
                child: Slider(
                  value: dur.inMilliseconds == 0
                      ? 0
                      : pos.inMilliseconds
                          .clamp(0, dur.inMilliseconds)
                          .toDouble(),
                  max: dur.inMilliseconds == 0
                      ? 1
                      : dur.inMilliseconds.toDouble(),
                  onChanged: (v) {
                    _player.seekTo(Duration(milliseconds: v.round()));
                  },
                  onChangeStart: (_) => _hideTimer?.cancel(),
                  onChangeEnd: (_) => _scheduleHideControls(),
                ),
              ),
              Text(_fmt(dur), style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
