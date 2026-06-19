/// 基于正则的「版本 / 字幕 / 音频」偏好匹配工具。
///
/// 用户可在设置页用正则表达式表达对片源版本、字幕轨、音频轨的偏好（如
/// 「4K」「中文|简|繁|chi」「jpn|日|flac」）。播放初始化时按这些正则自动挑选最
/// 符合的媒体源 / 轨道。正则统一大小写不敏感、开启 unicode（便于匹配中文）。
library;

import '../api/api_interfaces.dart';

/// 把正则字符串安全编译为大小写不敏感的 [RegExp]。
///
/// 空串或非法正则返回 null —— 调用方据此回退到默认（语言匹配/首个）行为，
/// 避免用户输错正则导致播放选轨异常。
RegExp? compilePreferenceRegex(String? pattern) {
  final p = pattern?.trim() ?? '';
  if (p.isEmpty) return null;
  try {
    return RegExp(p, caseSensitive: false, unicode: true);
  } catch (_) {
    return null;
  }
}

/// 媒体源（版本）的可匹配文本：名称 + 容器 + 视频分辨率/编码 + 显示名。
///
/// 用于「版本选择」正则反查，例如正则 `4K|2160` 命中 4K 片源。
String mediaSourceSearchText(MediaSource source) {
  final parts = <String?>[source.name, source.container];
  for (final s in source.mediaStreams) {
    if (s.isVideo) {
      parts
        ..add(s.resolution)
        ..add(s.codec)
        ..add(s.displayTitle);
    }
  }
  return parts.where((e) => e != null && e.isNotEmpty).join(' ');
}

/// 字幕 / 音频轨道的可匹配文本：显示名 + 标题 + 语言 + 编码（音频附带声道）。
///
/// 用于「字幕/音频选择」正则筛选，例如 `中文|简|繁|chi|zh` 命中各种中文字幕。
String mediaStreamSearchText(MediaStream stream) {
  final parts = <String?>[
    stream.displayTitle,
    stream.title,
    stream.language,
    stream.codec,
    if (stream.isAudio && stream.channels != null) '${stream.channels}ch',
  ];
  return parts.where((e) => e != null && e.isNotEmpty).join(' ');
}

/// 按版本正则挑选媒体源；正则为空/非法或无命中时返回 null。
MediaSource? matchPreferredMediaSource(
    List<MediaSource> sources, String? regex) {
  final re = compilePreferenceRegex(regex);
  if (re == null) return null;
  for (final s in sources) {
    if (re.hasMatch(mediaSourceSearchText(s))) return s;
  }
  return null;
}

/// 按正则挑选轨道（字幕/音频）；正则为空/非法或无命中时返回 null。
MediaStream? matchPreferredStream(List<MediaStream> streams, String? regex) {
  final re = compilePreferenceRegex(regex);
  if (re == null) return null;
  for (final s in streams) {
    if (re.hasMatch(mediaStreamSearchText(s))) return s;
  }
  return null;
}
