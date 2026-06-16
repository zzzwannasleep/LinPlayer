import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/update/app_update_service.dart';
import 'app_preferences.dart';

/// 是否启用自动检查更新（每 24h + 启动时）。
final updateAutoCheckProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_update_auto_check'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_update_auto_check', value);
    },
  );
});

/// 是否把预发布(pre)也纳入更新检查（默认仅稳定版）。
final updateIncludePrereleaseProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_update_include_pre'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_update_include_pre', value);
    },
  );
});

final appUpdateServiceProvider =
    Provider<AppUpdateService>((ref) => AppUpdateService());

/// 已检测到的可用更新（null 表示无）。UI 监听它弹窗/标记。
final availableUpdateProvider = StateProvider<UpdateInfo?>((ref) => null);
