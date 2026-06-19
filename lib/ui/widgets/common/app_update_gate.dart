import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/update_providers.dart';
import '../../../core/services/update/app_update_service.dart';
import '../../../core/services/update/update_installer.dart';

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
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  // 当前平台是否能应用内落地（Android/TV 安装、桌面下载揭示），且有匹配安装包。
  final canApply =
      UpdateInstaller.isSupported && UpdateInstaller.pickAsset(info) != null;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('发现新版本 ${info.tag}'
          '${info.isPrerelease ? '（预览版）' : '（稳定版）'}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360, maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('当前版本：$kCurrentAppVersion',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 12),
              Text(info.notes.isEmpty ? '（无更新说明）' : info.notes,
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('稍后'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await _openDownload(context, info);
          },
          child: const Text('前往发布页'),
        ),
        if (canApply)
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _startInAppUpdate(context, info);
            },
            child: const Text('下载并更新'),
          ),
      ],
    ),
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // 在 pop 之前抓住底层页面的 messenger，避免对话框关闭后 context 失效。
    final messenger = ScaffoldMessenger.maybeOf(context);
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
      case ApplyResult.desktopRevealed:
        Navigator.of(context).pop();
        messenger?.showSnackBar(const SnackBar(
            content: Text('安装包已下载到「下载」目录并定位，解压后覆盖原文件夹即可完成更新')));
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载链接已复制，请在浏览器中打开')),
      );
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
