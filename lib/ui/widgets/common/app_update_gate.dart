import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/update_providers.dart';
import '../../../core/services/update/app_update_service.dart';

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
    final includePre = ref.read(updateIncludePrereleaseProvider);
    final info = await ref
        .read(appUpdateServiceProvider)
        .checkForUpdate(includePrerelease: includePre);
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
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('发现新版本 ${info.tag}${info.isPrerelease ? '（预览）' : ''}'),
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
        FilledButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await _openDownload(context, info);
          },
          child: const Text('前往下载'),
        ),
      ],
    ),
  );
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
