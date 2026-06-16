import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_logger.dart';
import '../video_player_service.dart';
import 'translation_engine.dart';

/// 流式字幕翻译器（用于内封等无法整文件下载的字幕轨）。
///
/// 订阅播放器「当前字幕 cue」回调，对每条原文实时翻译，结果通过 [displayText]
/// 暴露给播放器叠加层显示。译文逐条按文本缓存，回看/拖动可秒出。原文仍由 mpv
/// 渲染（叠加层只显示中文），不重新挂载字幕，避免取词反馈环。
class StreamingSubtitleTranslator {
  StreamingSubtitleTranslator({
    required this.engine,
    required this.sourceLang,
    required this.targetLang,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger();

  final TranslationEngine engine;
  final String sourceLang;
  final String targetLang;
  final AppLogger _logger;
  static const _tag = 'StreamTranslate';

  /// 当前应显示的译文（空字符串表示不显示）。
  final ValueNotifier<String> displayText = ValueNotifier<String>('');

  /// 翻译引擎错误（如未开通服务），供 UI 提示一次。
  final ValueNotifier<String?> errorMessage = ValueNotifier<String?>(null);

  VideoPlayerService? _service;
  final Map<String, String> _cache = <String, String>{};
  String _currentKey = '';
  bool _running = false;
  int _seq = 0;

  bool get isRunning => _running;

  void start(VideoPlayerService service) {
    if (_running) return;
    _running = true;
    _service = service;
    service.subtitleCueHandler = _onCue;
    _logger.i(_tag,
        '流式字幕翻译已启动: 引擎=${engine.id}, $sourceLang→$targetLang');
  }

  void _onCue(String text, Duration? start, Duration? end) {
    if (!_running) return;
    final key = text.trim();
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
    // 先清空，等翻译结果回来再显示（避免显示上一条的译文）。
    displayText.value = '';
    final mySeq = ++_seq;
    unawaited(_translate(key, mySeq));
  }

  Future<void> _translate(String text, int seq) async {
    try {
      final flat = text.replaceAll('\n', ' ');
      final out = await engine.translate(
        [flat],
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
      final translated = out.isNotEmpty ? out.first : text;
      _cache[text] = translated;
      // 仅当仍停在这条 cue 时才更新显示，避免过期译文覆盖新 cue。
      if (_running && _currentKey == text) {
        displayText.value = translated;
      }
    } catch (e) {
      _logger.w(_tag, '流式翻译失败: $e');
      errorMessage.value = e.toString();
    }
  }

  void stop() {
    _running = false;
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
