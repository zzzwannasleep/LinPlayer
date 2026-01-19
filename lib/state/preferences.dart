import 'package:flutter/material.dart';

enum ThemeTemplate {
  defaultBlue,
  warm,
  cool,
  kawaii,
}

ThemeTemplate themeTemplateFromId(String? id) {
  switch (id) {
    case 'warm':
      return ThemeTemplate.warm;
    case 'cool':
      return ThemeTemplate.cool;
    case 'kawaii':
      return ThemeTemplate.kawaii;
    default:
      return ThemeTemplate.defaultBlue;
  }
}

extension ThemeTemplateX on ThemeTemplate {
  String get id {
    switch (this) {
      case ThemeTemplate.defaultBlue:
        return 'default';
      case ThemeTemplate.warm:
        return 'warm';
      case ThemeTemplate.cool:
        return 'cool';
      case ThemeTemplate.kawaii:
        return 'kawaii';
    }
  }

  String get label {
    switch (this) {
      case ThemeTemplate.defaultBlue:
        return '默认';
      case ThemeTemplate.warm:
        return '暖色调';
      case ThemeTemplate.cool:
        return '冷色调';
      case ThemeTemplate.kawaii:
        return '可爱二次元';
    }
  }

  Color get seed {
    switch (this) {
      case ThemeTemplate.defaultBlue:
        return const Color(0xFF8CB4FF);
      case ThemeTemplate.warm:
        return const Color(0xFFFFA36C);
      case ThemeTemplate.cool:
        return const Color(0xFF63D2FF);
      case ThemeTemplate.kawaii:
        return const Color(0xFFFF6FB1);
    }
  }

  Color get secondarySeed {
    switch (this) {
      case ThemeTemplate.defaultBlue:
        return const Color(0xFFFFC27A);
      case ThemeTemplate.warm:
        return const Color(0xFFFFE08A);
      case ThemeTemplate.cool:
        return const Color(0xFFB0E6FF);
      case ThemeTemplate.kawaii:
        return const Color(0xFF7DD9FF);
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

PlayerCore playerCoreFromId(String? id) {
  switch (id) {
    case 'exo':
      return PlayerCore.exo;
    default:
      return PlayerCore.mpv;
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
