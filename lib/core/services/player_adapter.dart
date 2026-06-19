import 'dart:typed_data';
import 'package:flutter/material.dart';

/// 播放器适配器接口
///
/// 抽象所有播放器内核的通用操作。
/// 视频渲染可通过 [buildVideo] 获取渲染 Widget，
/// 旧版本通过 [textureId] 获取 Texture ID（ExoPlayer 等）。
abstract class PlayerAdapter {
  /// 是否已初始化
  bool get isInitialized;

  /// 是否正在播放
  bool get isPlaying;

  /// 是否缓冲中
  bool get isBuffering;

  /// 是否播放完成
  bool get isCompleted;

  /// 当前位置
  Duration get position;

  /// 总时长
  Duration get duration;

  /// 当前播放速度
  double get speed;

  /// 当前音量
  double get volume;

  /// 播放进度 0.0-1.0
  double get progress;

  /// 是否有错误
  bool get hasError;

  /// 错误信息
  String? get errorMessage;

  /// libass 是否已就绪
  bool get libassReady => false;

  /// Flutter Texture ID（渲染视频用，旧架构）
  int? get textureId;

  /// 构建视频渲染 Widget
  ///
  /// media_kit 等封装库返回自己的 Video Widget，
  /// ExoPlayer 等返回 Texture widget。
  Widget buildVideo();

  /// 初始化播放器
  Future<void> initialize({
    required String videoUrl,
    Duration? startPosition,
    bool dolbyVisionFix = false,
    bool useLibass = false,
    bool hardwareDecoding = true,
    String? preferredSubtitleLanguage,
    int? surfaceViewId,  // Optional: for gpu-next rendering on Android
    bool useGpuNext = false,  // Optional: gpu-next rendering mode
  });

  /// 加载外部字幕文件（通过 libass）
  Future<void> loadLibassSubtitle(String path) async {}

  /// 加载字幕数据到内存（通过 libass）
  Future<void> loadLibassSubtitleMemory(Uint8List data, {String codec = 'ass'}) async {}

  /// 为下一次字幕选择提供类型/标题提示。
  void setSubtitleSelectionHint(String? codec, {String? title}) {}

  /// 播放
  Future<void> play();

  /// 暂停
  Future<void> pause();

  /// 跳转到指定位置
  Future<void> seekTo(Duration position);

  /// 设置播放速度
  Future<void> setSpeed(double speed);

  /// 设置音量
  Future<void> setVolume(double volume);

  /// 设置状态回调
  void setCallbacks(PlayerStateCallbacks callbacks);

  /// 截图（返回图片字节数据）
  Future<Uint8List?> screenshot() async => null;

  /// 选择字幕轨道（通过轨道ID选择内封字幕）
  Future<void> selectSubtitleTrack(String trackId) async {}

  /// 取消选择字幕轨道（关闭字幕）
  Future<void> deselectSubtitleTrack() async {}

  /// 选择音频轨道
  Future<void> selectAudioTrack(String trackId) async {}

  /// 加载次字幕文件
  Future<void> loadSecondarySubtitle(String path) async {}

  /// 通过轨道ID选择内封字幕作为次字幕
  Future<void> selectSecondarySubtitleTrack(String trackId) async {}

  /// 取消次字幕
  Future<void> deselectSecondarySubtitle() async {}

  /// 获取当前可用轨道列表
  List<Map<String, dynamic>> getTracksInfo();

  /// 设置字幕同步偏移（秒）
  Future<void> setSubtitleDelay(double seconds) async {}

  /// 设置音频同步偏移（秒）
  Future<void> setAudioDelay(double seconds) async {}

  /// 设置字幕字体
  Future<void> setSubtitleFont(String fontName) async {}

  /// 设置字幕大小（0.0 - 1.0）
  Future<void> setSubtitleSize(double size) async {}

  /// 设置字幕位置（0.0 - 1.0）
  Future<void> setSubtitlePosition(double position) async {}

  /// 设置字幕黑色背景
  Future<void> setSubtitleBackground(bool enabled) async {}

  /// 设置图形字幕(PGS/SUP)混合渲染模式：'no'/'video'/'yes'。
  /// 仅桌面 libmpv 实现，其余适配器空操作。用于排查图形字幕闪现。
  Future<void> setSubtitleBlendMode(String mode) async {}

  /// 设置画面比例
  Future<void> setAspectRatio(String ratio) async {}

  /// 应用超分辨率（Anime4K）
  Future<void> applySuperResolution(bool enable) async {}

  /// 应用超分辨率档位（Anime4K）
  /// level: 'off', 'modeA', 'modeB', 'modeC'
  Future<void> applySuperResolutionLevel(String level) async {}

  /// 获取播放统计信息（MPV原生属性）
  /// 返回属性名到属性值的映射
  Future<Map<String, String>> getPlaybackStats() async => {};

  /// 释放资源
  Future<void> dispose();
}

/// 当前字幕 cue 回调：[text] 正在显示的原文，[start]/[end] 该 cue 的起止时间。
typedef SubtitleCueCallback = void Function(
    String text, Duration? start, Duration? end);

/// 播放器状态回调
class PlayerStateCallbacks {
  final VoidCallback? onPositionChanged;
  final VoidCallback? onDurationChanged;
  final VoidCallback? onPlayingStateChanged;
  final VoidCallback? onBufferingStateChanged;
  final VoidCallback? onCompleted;
  final VoidCallback? onError;

  /// 当前字幕 cue 变化（用于流式翻译实时取词）。仅 mpv 内核会触发。
  final SubtitleCueCallback? onSubtitleCue;

  const PlayerStateCallbacks({
    this.onPositionChanged,
    this.onDurationChanged,
    this.onPlayingStateChanged,
    this.onBufferingStateChanged,
    this.onCompleted,
    this.onError,
    this.onSubtitleCue,
  });
}

typedef VoidCallback = void Function();
