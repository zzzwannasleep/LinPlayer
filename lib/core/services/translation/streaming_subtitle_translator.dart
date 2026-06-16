import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_logger.dart';
import '../video_player_service.dart';
import 'translation_engine.dart';

/// 流式字幕翻译器（用于内封等无法整文件下载的字幕轨）。
///
/// 显示走「反应式」：订阅播放器当前 cue → 命中缓存即显示，未命中先空、译好再补。
/// 为消除首见延迟，后台用 mpv `sub-step` 从**已缓冲区**偷看后续 cue 的文本，提前
/// 翻译进缓存——播放到时即缓存命中、秒出中文。偷看零额外带宽（纯用缓冲），且不
/// 重新挂载字幕。原文由 mpv 渲染，中文走叠加层（[displayText]）。
class StreamingSubtitleTranslator {
  StreamingSubtitleTranslator({
    required this.engine,
    required this.sourceLang,
    required this.targetLang,
    AppLogger? logger,
    this.lookaheadCount = 6,
    this.lookaheadInterval = const Duration(seconds: 4),
  }) : _logger = logger ?? AppLogger();

  final TranslationEngine engine;
  final String sourceLang;
  final String targetLang;
  final AppLogger _logger;

  /// 每轮向前偷看的 cue 条数。
  final int lookaheadCount;

  /// 偷看轮询间隔。
  final Duration lookaheadInterval;

  static const _tag = 'StreamTranslate';

  /// 当前应显示的译文（空字符串表示不显示）。
  final ValueNotifier<String> displayText = ValueNotifier<String>('');

  /// 翻译引擎错误（如未开通服务），供 UI 提示一次。
  final ValueNotifier<String?> errorMessage = ValueNotifier<String?>(null);

  VideoPlayerService? _service;
  final Map<String, String> _cache = <String, String>{};
  String _currentKey = '';
  bool _running = false;
  bool _peeking = false; // sub-step 偷看期间，屏蔽反应式显示跳动
  int _seq = 0;
  Timer? _lookaheadTimer;

  bool get isRunning => _running;

  void start(VideoPlayerService service) {
    if (_running) return;
    _running = true;
    _service = service;
    service.subtitleCueHandler = _onCue;
    if (service.isMpvCore) {
      _lookaheadTimer =
          Timer.periodic(lookaheadInterval, (_) => unawaited(_lookaheadTick()));
    }
    _logger.i(_tag,
        '流式字幕翻译已启动: 引擎=${engine.id}, $sourceLang→$targetLang, '
        'sub-step 预读=${service.isMpvCore ? '开' : '关(非 mpv 内核)'}');
  }

  String _norm(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  void _onCue(String text, Duration? start, Duration? end) {
    if (!_running || _peeking) return; // 偷看期间不更新显示
    final key = _norm(text);
    _currentKey = key;
    if (key.isEmpty) {
      displayText.value = '';
      return;
    }
    final cached = _cache[key];
    if (cached != null) {
      displayText.value = cached;
      return;
    }
    displayText.value = ''; // 先清空，译好再补
    unawaited(_translate(key, ++_seq, display: true));
  }

  Future<void> _translate(String key, int seq,
      {required bool display}) async {
    if (_cache.containsKey(key)) {
      if (display && _running && _currentKey == key) {
        displayText.value = _cache[key]!;
      }
      return;
    }
    try {
      final out = await engine.translate(
        [key],
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
      final translated = out.isNotEmpty ? out.first : key;
      _cache[key] = translated;
      if (display && _running && _currentKey == key) {
        displayText.value = translated;
      }
    } catch (e) {
      _logger.w(_tag, '流式翻译失败: $e');
      errorMessage.value = e.toString();
    }
  }

  /// 用 sub-step 向前偷看若干 cue 的文本并预翻译进缓存（不改变实际显示）。
  Future<void> _lookaheadTick() async {
    final svc = _service;
    if (svc == null || !_running || _peeking || !svc.isMpvCore) return;
    _peeking = true;

    final savedDelay =
        double.tryParse(await svc.mpvGetProperty('sub-delay') ?? '') ?? 0.0;
    String savedVis = 'yes';
    final peeked = <String>[];
    try {
      savedVis = (await svc.mpvGetProperty('sub-visibility') ?? 'yes');
      // 偷看期间隐藏原生字幕，避免步进时画面闪烁。
      await svc.mpvSetProperty('sub-visibility', 'no');
      for (var i = 0; i < lookaheadCount; i++) {
        await svc.mpvCommand(['sub-step', '1']);
        final t = _norm(await svc.mpvGetProperty('sub-text') ?? '');
        if (t.isNotEmpty && !peeked.contains(t)) peeked.add(t);
      }
    } catch (e) {
      _logger.w(_tag, 'sub-step 预读异常: $e');
    } finally {
      // 精确还原时间轴与可见性。
      await svc.mpvSetProperty('sub-delay', savedDelay.toString());
      await svc.mpvSetProperty(
          'sub-visibility', savedVis.isEmpty ? 'yes' : savedVis);
      _peeking = false;
    }

    var warmed = 0;
    for (final key in peeked) {
      if (_cache.containsKey(key)) continue;
      warmed++;
      unawaited(_translate(key, ++_seq, display: false));
    }
    if (peeked.isNotEmpty) {
      _logger.i(_tag, 'sub-step 预读 ${peeked.length} 条 / 新译 $warmed 条');
    }
  }

  void stop() {
    _running = false;
    _lookaheadTimer?.cancel();
    _lookaheadTimer = null;
    if (_service?.subtitleCueHandler == _onCue) {
      _service?.subtitleCueHandler = null;
    }
    _service = null;
    displayText.value = '';
    _logger.i(_tag, '流式字幕翻译已停止');
  }

  void dispose() {
    stop();
    displayText.dispose();
    errorMessage.dispose();
  }
}
