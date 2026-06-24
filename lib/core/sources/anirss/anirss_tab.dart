import 'package:flutter/material.dart';

/// Ani-rss 迷你应用的三个 Tab（三端共用文案/图标，保持一致）。
enum AniRssTab { home, subscriptions, settings }

extension AniRssTabMeta on AniRssTab {
  String get label {
    switch (this) {
      case AniRssTab.home:
        return '首页';
      case AniRssTab.subscriptions:
        return '订阅';
      case AniRssTab.settings:
        return '设置';
    }
  }

  IconData get icon {
    switch (this) {
      case AniRssTab.home:
        return Icons.grid_view_rounded;
      case AniRssTab.subscriptions:
        return Icons.download_rounded;
      case AniRssTab.settings:
        return Icons.settings_rounded;
    }
  }

  IconData get outlinedIcon {
    switch (this) {
      case AniRssTab.home:
        return Icons.grid_view_outlined;
      case AniRssTab.subscriptions:
        return Icons.download_outlined;
      case AniRssTab.settings:
        return Icons.settings_outlined;
    }
  }
}
