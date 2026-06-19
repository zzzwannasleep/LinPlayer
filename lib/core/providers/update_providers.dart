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

/// 更新渠道：稳定版（GitHub latest 正式发布）/ 预览版（含 *-pre 预发布）。
enum UpdateChannel { stable, prerelease }

UpdateChannel parseUpdateChannel(String? value) =>
    value == 'prerelease' ? UpdateChannel.prerelease : UpdateChannel.stable;

String updateChannelLabel(UpdateChannel c) =>
    c == UpdateChannel.prerelease ? '预览版（pre-release）' : '稳定版（latest）';

/// 当前更新渠道偏好。默认稳定版；兼容迁移旧的 include_pre 布尔开关。
final updateChannelProvider =
    StateNotifierProvider<PreferenceNotifier<UpdateChannel>, UpdateChannel>(
        (ref) {
  return PreferenceNotifier<UpdateChannel>(
    defaultValue: UpdateChannel.stable,
    readValue: (prefs) {
      final raw = prefs.getString('linplayer_update_channel');
      if (raw != null) return parseUpdateChannel(raw);
      // 迁移：旧版本用 bool 记录是否含预发布。
      if (prefs.getBool('linplayer_update_include_pre') == true) {
        return UpdateChannel.prerelease;
      }
      return null; // 走 defaultValue（稳定版）
    },
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_update_channel', value.name);
    },
  );
});

final appUpdateServiceProvider =
    Provider<AppUpdateService>((ref) => AppUpdateService());

/// 已检测到的可用更新（null 表示无）。UI 监听它弹窗/标记。
final availableUpdateProvider = StateProvider<UpdateInfo?>((ref) => null);
