import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/update_providers.dart';
import '../../../core/services/update/app_update_service.dart';
import '../../../core/services/update/update_installer.dart';
import '../../../core/theme/app_colors.dart';
import 'app_toast.dart';

/// 挂在根 `MaterialApp.router` 的 builder 下，负责：启动时 + 每 24h 检查更新，
/// 发现新版本即弹窗。三端共用（桌面/移动/TV 均经此）。
class AppUpdateGate extends ConsumerStatefulWidget {
  const AppUpdateGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends ConsumerState<AppUpdateGate> {
  static const _interval = Duration(hours: 24);
  Timer? _timer;
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeCheck();
      _timer = Timer.periodic(_interval, (_) => _maybeCheck());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _maybeCheck() async {
    if (!mounted) return;
    if (!ref.read(updateAutoCheckProvider)) return;
    final channel = ref.read(updateChannelProvider);
    final info = await ref.read(appUpdateServiceProvider).checkForUpdate(
          includePrerelease: channel == UpdateChannel.prerelease,
        );
    if (!mounted || info == null) return;
    ref.read(availableUpdateProvider.notifier).state = info;
    if (!_dialogShown) {
      _dialogShown = true;
      await showUpdateDialog(context, info);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 弹出更新提示对话框。可被设置页「检查更新」复用。
///
/// 两个主选项：[立即更新]（应用内下载 → Windows 原地覆盖并自动重启 / 其他端
/// 落地安装）/ [暂不更新]；并保留「前往发布页」作为次要入口。更新日志直接展示
/// GitHub 自动生成的发布说明（含本次提交/PR 列表）。
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  // 当前平台是否能应用内落地（Android/TV 安装、Windows 原地覆盖、桌面揭示）。
  final canApply =
      UpdateInstaller.isSupported && UpdateInstaller.pickAsset(info) != null;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded,
                color: AppColors.brand, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Text('发现新版本 ${info.tag}'
                  '${info.isPrerelease ? '（预览版）' : '（稳定版）'}'),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380, maxWidth: 500),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('当前版本：$kCurrentAppVersion',
                  style: TextStyle(
                      color: theme.hintColor, fontSize: 13)),
              const SizedBox(height: 6),
              Text('更新内容',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Flexible(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      info.notes.trim().isEmpty ? '（无更新说明）' : info.notes.trim(),
                      style: const TextStyle(fontSize: 13, height: 1.45),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actionsPadding:
            const EdgeInsets.only(left: 12, right: 16, bottom: 12, top: 4),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _openDownload(context, info);
            },
            child: const Text('前往发布页'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('暂不更新'),
          ),
          if (canApply)
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _startInAppUpdate(context, info);
              },
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('立即更新'),
            )
          else
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _openDownload(context, info);
              },
              child: const Text('立即更新'),
            ),
        ],
      );
    },
  );
}

/// 启动应用内下载 + 落地（带进度对话框）。
Future<void> _startInAppUpdate(BuildContext context, UpdateInfo info) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDownloadDialog(info: info),
  );
}

/// 下载进度对话框：进入即开始下载，完成后按结果落地并给出提示。
class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  final CancelToken _cancel = CancelToken();
  double _progress = 0;
  bool _finished = false;
  bool _relaunching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final result = await UpdateInstaller.downloadAndApply(
      info: widget.info,
      cancelToken: _cancel,
      onProgress: (received, total) {
        if (mounted && total > 0) {
          setState(() => _progress = received / total);
        }
      },
    );
    if (!mounted) return;
    setState(() => _finished = true);

    switch (result) {
      case ApplyResult.androidInstalling:
        // 系统安装界面已弹出，关闭进度框即可。
        Navigator.of(context).pop();
        break;
      case ApplyResult.desktopRelaunching:
        // Windows：覆盖更新脚本已接管，提示后立即退出，让其覆盖并自动重启。
        setState(() => _relaunching = true);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        exit(0);
      case ApplyResult.desktopRevealed:
        Navigator.of(context).pop();
        AppToast.success(
            context, '安装包已下载到「下载」目录并定位，解压后覆盖原文件夹即可完成更新');
        break;
      case ApplyResult.canceled:
        Navigator.of(context).pop();
        break;
      case ApplyResult.noAsset:
        setState(() => _error = '未找到当前平台的安装包，请前往发布页手动下载');
        break;
      case ApplyResult.failed:
        setState(() => _error = '下载失败，请检查网络后重试，或前往发布页手动下载');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
    if (_relaunching) {
      return const AlertDialog(
        title: Text('更新完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('正在覆盖安装并自动重启，请稍候…（不会清除你的设置与数据）',
                style: TextStyle(fontSize: 13)),
            SizedBox(height: 14),
            LinearProgressIndicator(),
          ],
        ),
      );
    }
    return AlertDialog(
      title: Text(_error != null ? '更新失败' : '正在下载更新'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null)
            Text(_error!, style: const TextStyle(fontSize: 13))
          else ...[
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 12),
            Text('$percent%',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ],
      ),
      actions: [
        if (_error != null) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _openDownload(context, widget.info);
            },
            child: const Text('前往发布页'),
          ),
        ] else if (!_finished)
          TextButton(
            onPressed: () {
              if (!_cancel.isCancelled) _cancel.cancel();
            },
            child: const Text('取消'),
          ),
      ],
    );
  }
}

Future<void> _openDownload(BuildContext context, UpdateInfo info) async {
  final url = info.pageUrl;
  if (url.isEmpty) return;
  final opened = await _openInBrowser(url);
  if (!opened) {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      AppToast.show(context, '下载链接已复制，请在浏览器中打开');
    }
  }
}

/// 桌面端用系统命令打开浏览器；移动端不支持返回 false（改为复制链接）。
Future<bool> _openInBrowser(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', url]);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [url]);
      return true;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [url]);
      return true;
    }
  } catch (_) {}
  return false;
}
