import 'package:flutter/material.dart';

enum ThemeTemplate {
  defaultBlue,
  warm,
  cool,
}

ThemeTemplate themeTemplateFromId(String? id) {
  switch (id) {
    case 'warm':
      return ThemeTemplate.warm;
    case 'cool':
      return ThemeTemplate.cool;
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

