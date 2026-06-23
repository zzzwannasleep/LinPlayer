import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

import '../../core/theme/app_colors.dart';
import '../../ui/widgets/common/app_toast.dart';
import '../platform/desktop_ui_style.dart';

/// 跨平台原生确认弹窗。
///
/// - Windows -> fluent [fluent.ContentDialog]
/// - macOS   -> [macos.MacosAlertDialog]
/// - Linux   -> Material [AlertDialog]
Future<bool> showDesktopConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '确定',
  String cancelText = '取消',
  bool destructive = false,
}) async {
  switch (desktopUiStyle) {
    case DesktopUiStyle.fluent:
      final result = await fluent.showDialog<bool>(
        context: context,
        builder: (ctx) => fluent.ContentDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            fluent.Button(
              child: Text(cancelText),
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            fluent.FilledButton(
              style: destructive
                  ? fluent.ButtonStyle(
                      backgroundColor:
                          fluent.WidgetStateProperty.all(AppColors.error),
                    )
                  : null,
              child: Text(confirmText),
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      return result ?? false;

    case DesktopUiStyle.macos:
      final result = await macos.showMacosAlertDialog<bool>(
        context: context,
        builder: (ctx) => macos.MacosAlertDialog(
          appIcon: const Icon(
            Icons.live_tv_rounded,
            size: 56,
            color: AppColors.brand,
          ),
          title: Text(title),
          message: Text(message),
          primaryButton: macos.PushButton(
            controlSize: macos.ControlSize.large,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText),
          ),
          secondaryButton: macos.PushButton(
            controlSize: macos.ControlSize.large,
            secondary: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(cancelText),
          ),
        ),
      );
      return result ?? false;

    case DesktopUiStyle.material:
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(cancelText),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: AppColors.error)
                  : null,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmText),
            ),
          ],
        ),
      );
      return result ?? false;
  }
}

/// 跨平台轻量提示（成功/普通消息）。
///
/// 三端统一走 [AppToast] 顶部圆角气泡，取代以往各平台不一致的 InfoBar / 黑底
/// SnackBar，视觉统一且更好看。
void showDesktopMessage(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  AppToast.show(
    context,
    message,
    kind: isError ? AppToastKind.error : AppToastKind.info,
  );
}
