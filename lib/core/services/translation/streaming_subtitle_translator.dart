import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_logger.dart';
import '../video_player_service.dart';
import 'subtitle_document.dart';
import 'translation_engine.dart';

/// 流式字幕翻译器（用于内封等无法整文件下载的字幕轨）。
///
/// 显示走「反应式」：订阅播放器当前 cue → 命中缓存即显示，未命中先显示原文（双语）
/// 或留空（仅译文），译好再补。为消除首见延迟，后台用 mpv `sub-step` 从**已缓冲区**
/// 偷看后续 cue 的文本，提前翻译进缓存——播放到时即缓存命中、秒出译文。
///
/// 关键：流式模式下译文与原文**全部由叠加层（[displayText]）渲染**，并按 [layout]
/// 组合排版；mpv 自带的原文字幕全程隐藏（`sub-visibility=no`），避免「叠加层译文 +
/// mpv 原文」双份显示（既可能是双原文，也可能在原文恰为中文时变成两行中文）。
/// [stop] 时恢复 `sub-visibility=yes`，保证停用翻译后原字幕复原。
class StreamingSubtitleTranslator {
  StreamingSubtitleTranslator({
    required this.engine,
    required this.sourceLang,
    required this.targetLang,
    this.layout = BilingualLayout.translatedFirst,
    AppLogger? logger,
    this.lookaheadCount = 6,
    this.lookaheadInterval = const Duration(seconds: 4),
  }) : _logger = logger ?? AppLogger();

  final TranslationEngine engine;
  final String sourceLang;
  final String targetLang;

  /// 双语排版：决定叠加层显示「仅译文 / 译文+原文 / 原文+译文」。
  final BilingualLayout layout;

  final AppLogger _logger;

  /// 每轮向前偷看的 cue 条数。
  final int lookaheadCount;

  /// 偷看轮询间隔。
  final Duration lookaheadInterval;

  static const _tag = 'StreamTranslate';

  /// 当前应显示的文本（空字符串表示不显示）。已按 [layout] 组合好。
  final ValueNotifier<String> displayText = ValueNotifier<String>('');

  /// 翻译引擎错误（如未开通服务），供 UI 提示一次。
  final ValueNotifier<String?> errorMessage = ValueNotifier<String?>(null);

  VideoPlayerService? _service;
  final Map<String, String> _cache = <String, String>{};
  String _currentKey = '';
  String _currentOriginal = '';
  bool _running = false;
  bool _peeking = false; // sub-step 偷看期间，屏蔽反应式显示跳动
  bool _hidOriginal = false; // 是否已隐藏 mpv 原生原文字幕
  int _seq = 0;
  Timer? _lookaheadTimer;

  bool get isRunning => _running;

  void start(VideoPlayerService service) {
    if (_running) return;
    _running = true;
    _service = service;
    service.subtitleCueHandler = _onCue;
    // Android 原生 mpv 通过轮询 sub-text 取词（media_kit / Exo 走原生事件推送）。
    service.setSubtitleCueObservation(true);
    // 隐藏播放器自带字幕：原文/译文统一由叠加层按排版渲染（mpv / 原生 mpv / Exo 均支持）。
    _hidOriginal = true;
    service.setNativeSubtitleHidden(true);
    if (service.supportsSubStep) {
      // libmpv 内核（media_kit / 原生 mpv）支持 sub-step 从已缓冲区预读，提前翻译进缓存（秒出）。
      _lookaheadTimer =
          Timer.periodic(lookaheadInterval, (_) => unawaited(_lookaheadTick()));
    }
    _logger.i(
        _tag,
        '流式字幕翻译已启动: 引擎=${engine.id}, $sourceLang→$targetLang, 排版=${layout.name}, '
        'sub-step 预读=${service.supportsSubStep ? '开' : '关(非 libmpv 内核)'}');
  }

  String _norm(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 按排版把原文与译文组合成叠加层文本。
  /// 译文为空（尚未译好）时：双语显示原文占位，仅译文显示空。
  String _compose(String original, String translated) {
    final o = original.trim();
    final t = translated.trim();
    switch (layout) {
      case BilingualLayout.translatedOnly:
        return t;
      case BilingualLayout.translatedFirst:
        if (t.isEmpty) return o;
        return '$t\n$o';
      case BilingualLayout.originalFirst:
        if (t.isEmpty) return o;
        return '$o\n$t';
    }
  }

  void _onCue(String text, Duration? start, Duration? end) {
    if (!_running || _peeking) return; // 偷看期间不更新显示
    final key = _norm(text);
    _currentKey = key;
    _currentOriginal = text;
    if (key.isEmpty) {
      displayText.value = '';
      return;
    }
    final cached = _cache[key];
    if (cached != null) {
      displayText.value = _compose(text, cached);
      return;
    }
    // 先显示原文占位（仅译文模式留空），译好再补。
    displayText.value = _compose(text, '');
    unawaited(_translate(key, ++_seq, display: true));
  }

  Future<void> _translate(String key, int seq, {required bool display}) async {
    if (_cache.containsKey(key)) {
      if (display && _running && _currentKey == key) {
        displayText.value = _compose(_currentOriginal, _cache[key]!);
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
        displayText.value = _compose(_currentOriginal, translated);
      }
    } catch (e) {
      _logger.w(_tag, '流式翻译失败: $e');
      errorMessage.value = e.toString();
    }
  }

  /// 用 sub-step 向前偷看若干 cue 的文本并预翻译进缓存（不改变实际显示）。
  Future<void> _lookaheadTick() async {
    final svc = _service;
    if (svc == null || !_running || _peeking || !svc.supportsSubStep) return;
    _peeking = true;

    final savedDelay =
        double.tryParse(await svc.mpvGetProperty('sub-delay') ?? '') ?? 0.0;
    final peeked = <String>[];
    try {
      for (var i = 0; i < lookaheadCount; i++) {
        await svc.mpvCommand(['sub-step', '1']);
        final t = _norm(await svc.mpvGetProperty('sub-text') ?? '');
        if (t.isNotEmpty && !peeked.contains(t)) peeked.add(t);
      }
    } catch (e) {
      _logger.w(_tag, 'sub-step 预读异常: $e');
    } finally {
      // 精确还原时间轴；原文字幕全程隐藏，可见性恒为 no。
      await svc.mpvSetProperty('sub-delay', savedDelay.toString());
      await svc.mpvSetProperty('sub-visibility', 'no');
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
    final svc = _service;
    if (svc != null) {
      // 关闭原生 mpv 的 sub-text 取词轮询。
      svc.setSubtitleCueObservation(false);
      // 恢复播放器自带字幕渲染，避免停用翻译后原字幕消失。
      if (_hidOriginal) {
        svc.setNativeSubtitleHidden(false);
      }
      if (svc.subtitleCueHandler == _onCue) {
        svc.subtitleCueHandler = null;
      }
    }
    _hidOriginal = false;
    _service = null;
    displayText.value = '';
    // 释放本集累积的翻译缓存——否则每播一集都往同一个 Map 堆字符串，长会话内存只增不减。
    _cache.clear();
    _logger.i(_tag, '流式字幕翻译已停止');
  }

  void dispose() {
    stop();
    displayText.dispose();
    errorMessage.dispose();
  }
}
