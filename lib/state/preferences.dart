import 'package:flutter/material.dart';

enum UiTemplate {
  candyGlass,
  stickerJournal,
  neonHud,
  minimalCovers,
  washiWatercolor,
  pixelArcade,
  mangaStoryboard,
  proTool,
}

UiTemplate uiTemplateFromId(String? id) {
  switch (id) {
    // Legacy ids (<= early versions).
    case 'default':
      return UiTemplate.minimalCovers;
    case 'warm':
      return UiTemplate.washiWatercolor;
    case 'cool':
      return UiTemplate.neonHud;
    case 'kawaii':
      return UiTemplate.candyGlass;

    // New ids.
    case 'candy':
      return UiTemplate.candyGlass;
    case 'sticker':
      return UiTemplate.stickerJournal;
    case 'hud':
      return UiTemplate.neonHud;
    case 'minimal':
      return UiTemplate.minimalCovers;
    case 'washi':
      return UiTemplate.washiWatercolor;
    case 'pixel':
      return UiTemplate.pixelArcade;
    case 'manga':
      return UiTemplate.mangaStoryboard;
    case 'pro':
      return UiTemplate.proTool;
    default:
      return UiTemplate.candyGlass;
  }
}

extension UiTemplateX on UiTemplate {
  String get id {
    switch (this) {
      case UiTemplate.candyGlass:
        return 'candy';
      case UiTemplate.stickerJournal:
        return 'sticker';
      case UiTemplate.neonHud:
        return 'hud';
      case UiTemplate.minimalCovers:
        return 'minimal';
      case UiTemplate.washiWatercolor:
        return 'washi';
      case UiTemplate.pixelArcade:
        return 'pixel';
      case UiTemplate.mangaStoryboard:
        return 'manga';
      case UiTemplate.proTool:
        return 'pro';
    }
  }

  String get label {
    switch (this) {
      case UiTemplate.candyGlass:
        return '可爱二次元｜糖果玻璃';
      case UiTemplate.stickerJournal:
        return '可爱二次元｜贴纸手帐';
      case UiTemplate.neonHud:
        return '赛博霓虹｜HUD 控制台';
      case UiTemplate.minimalCovers:
        return '极简高级｜纯净封面墙';
      case UiTemplate.washiWatercolor:
        return '日系清淡｜和纸水彩';
      case UiTemplate.pixelArcade:
        return '复古像素｜街机风';
      case UiTemplate.mangaStoryboard:
        return '漫画分镜｜黑白网点';
      case UiTemplate.proTool:
        return '专业工具｜桌面优先';
    }
  }

  Color get seed {
    switch (this) {
      case UiTemplate.candyGlass:
        return const Color(0xFFFF6FB1);
      case UiTemplate.stickerJournal:
        return const Color(0xFFB69CFF);
      case UiTemplate.neonHud:
        return const Color(0xFF00E5FF);
      case UiTemplate.minimalCovers:
        return const Color(0xFF8CB4FF);
      case UiTemplate.washiWatercolor:
        return const Color(0xFF7CC8A7);
      case UiTemplate.pixelArcade:
        return const Color(0xFF4ADE80);
      case UiTemplate.mangaStoryboard:
        return const Color(0xFF111827);
      case UiTemplate.proTool:
        return const Color(0xFF64748B);
    }
  }

  Color get secondarySeed {
    switch (this) {
      case UiTemplate.candyGlass:
        return const Color(0xFF7DD9FF);
      case UiTemplate.stickerJournal:
        return const Color(0xFFFFC7A5);
      case UiTemplate.neonHud:
        return const Color(0xFFFF2DAA);
      case UiTemplate.minimalCovers:
        return const Color(0xFFFFC27A);
      case UiTemplate.washiWatercolor:
        return const Color(0xFFFFD6A5);
      case UiTemplate.pixelArcade:
        return const Color(0xFFFDE047);
      case UiTemplate.mangaStoryboard:
        return const Color(0xFFF9FAFB);
      case UiTemplate.proTool:
        return const Color(0xFF60A5FA);
    }
  }
}

enum VideoVersionPreference {
  defaultVersion,
  highestResolution,
  lowestBitrate,
  preferHevc,
  preferAvc,
}

enum PlayerCore {
  mpv,
  exo,
}

enum PlaybackBufferPreset {
  seekFast,
  balanced,
  stable,
  custom,
}

PlayerCore playerCoreFromId(String? id) {
  switch (id) {
    case 'exo':
      return PlayerCore.exo;
    default:
      return PlayerCore.mpv;
  }
}

PlaybackBufferPreset playbackBufferPresetFromId(String? id) {
  switch ((id ?? '').trim()) {
    case 'seekFast':
      return PlaybackBufferPreset.seekFast;
    case 'balanced':
      return PlaybackBufferPreset.balanced;
    case 'stable':
      return PlaybackBufferPreset.stable;
    case 'custom':
      return PlaybackBufferPreset.custom;
    default:
      return PlaybackBufferPreset.seekFast;
  }
}

extension PlayerCoreX on PlayerCore {
  String get id {
    switch (this) {
      case PlayerCore.mpv:
        return 'mpv';
      case PlayerCore.exo:
        return 'exo';
    }
  }

  String get label {
    switch (this) {
      case PlayerCore.mpv:
        return 'MPV';
      case PlayerCore.exo:
        return 'Exo';
    }
  }
}

extension PlaybackBufferPresetX on PlaybackBufferPreset {
  String get id {
    switch (this) {
      case PlaybackBufferPreset.seekFast:
        return 'seekFast';
      case PlaybackBufferPreset.balanced:
        return 'balanced';
      case PlaybackBufferPreset.stable:
        return 'stable';
      case PlaybackBufferPreset.custom:
        return 'custom';
    }
  }

  String get label {
    switch (this) {
      case PlaybackBufferPreset.seekFast:
        return '拖动秒开';
      case PlaybackBufferPreset.balanced:
        return '均衡';
      case PlaybackBufferPreset.stable:
        return '稳定优先';
      case PlaybackBufferPreset.custom:
        return '自定义';
    }
  }

  double? get suggestedBackRatio {
    switch (this) {
      case PlaybackBufferPreset.seekFast:
        return 0.05;
      case PlaybackBufferPreset.balanced:
        return 0.15;
      case PlaybackBufferPreset.stable:
        return 0.25;
      case PlaybackBufferPreset.custom:
        return null;
    }
  }
}

@immutable
class PlaybackBufferSplit {
  final int totalBytes;
  final int backBytes;
  final int forwardBytes;
  final double backRatio;

  const PlaybackBufferSplit._({
    required this.totalBytes,
    required this.backBytes,
    required this.forwardBytes,
    required this.backRatio,
  });

  static const int _mb = 1024 * 1024;

  int get totalMb => (totalBytes / _mb).round();
  int get backMb => (backBytes / _mb).round();
  int get forwardMb => (forwardBytes / _mb).round();

  static PlaybackBufferSplit from({
    required int totalMb,
    required double backRatio,
    double maxBackRatio = 0.30,
  }) {
    final tMb = totalMb.clamp(200, 2048);
    final r = backRatio.clamp(0.0, maxBackRatio).toDouble();
    final backMb = (tMb * r).round().clamp(0, tMb);
    final totalBytes = tMb * _mb;
    final backBytes = backMb * _mb;
    final forwardBytes = totalBytes - backBytes;
    return PlaybackBufferSplit._(
      totalBytes: totalBytes,
      backBytes: backBytes,
      forwardBytes: forwardBytes,
      backRatio: r,
    );
  }
}

enum ServerListLayout {
  grid,
  list,
}

ServerListLayout serverListLayoutFromId(String? id) {
  switch (id) {
    case 'list':
      return ServerListLayout.list;
    default:
      return ServerListLayout.grid;
  }
}

extension ServerListLayoutX on ServerListLayout {
  String get id {
    switch (this) {
      case ServerListLayout.grid:
        return 'grid';
      case ServerListLayout.list:
        return 'list';
    }
  }
}

VideoVersionPreference videoVersionPreferenceFromId(String? id) {
  switch (id) {
    case 'highestResolution':
      return VideoVersionPreference.highestResolution;
    case 'lowestBitrate':
      return VideoVersionPreference.lowestBitrate;
    case 'preferHevc':
      return VideoVersionPreference.preferHevc;
    case 'preferAvc':
      return VideoVersionPreference.preferAvc;
    default:
      return VideoVersionPreference.defaultVersion;
  }
}

extension VideoVersionPreferenceX on VideoVersionPreference {
  String get id {
    switch (this) {
      case VideoVersionPreference.defaultVersion:
        return 'default';
      case VideoVersionPreference.highestResolution:
        return 'highestResolution';
      case VideoVersionPreference.lowestBitrate:
        return 'lowestBitrate';
      case VideoVersionPreference.preferHevc:
        return 'preferHevc';
      case VideoVersionPreference.preferAvc:
        return 'preferAvc';
    }
  }

  String get label {
    switch (this) {
      case VideoVersionPreference.defaultVersion:
        return '默认';
      case VideoVersionPreference.highestResolution:
        return '最高分辨率';
      case VideoVersionPreference.lowestBitrate:
        return '最低码率';
      case VideoVersionPreference.preferHevc:
        return '优先 HEVC';
      case VideoVersionPreference.preferAvc:
        return '优先 AVC';
    }
  }
}
