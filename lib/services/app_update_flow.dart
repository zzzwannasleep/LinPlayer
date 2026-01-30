import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../app_config/app_config.dart';
import '../state/app_state.dart';
import 'app_update_service.dart';

class AppUpdateAutoChecker extends StatefulWidget {
  const AppUpdateAutoChecker({
    super.key,
    required this.appState,
    required this.child,
  });

  final AppState appState;
  final Widget child;

  @override
  State<AppUpdateAutoChecker> createState() => _AppUpdateAutoCheckerState();
}

class _AppUpdateAutoCheckerState extends State<AppUpdateAutoChecker> {
  bool _scheduled = false;
  bool _lastEnabled = false;

  @override
  void initState() {
    super.initState();
    _lastEnabled = widget.appState.autoUpdateEnabled;
    _scheduleIfNeeded(force: false);
  }

  @override
  void didUpdateWidget(covariant AppUpdateAutoChecker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final enabled = widget.appState.autoUpdateEnabled;
    if (enabled && !_lastEnabled) {
      _scheduled = false;
      _scheduleIfNeeded(force: true);
    }
    _lastEnabled = enabled;
  }

  void _scheduleIfNeeded({required bool force}) {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        AppUpdateFlow.maybeAutoCheck(
          context,
          appState: widget.appState,
          force: force,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AppUpdateFlow {
  static String get repoUrl => AppConfig.current.repoUrl;
  static const Duration _autoCheckInterval = Duration(hours: 24);
  static bool _inProgress = false;

  static Future<void> manualCheck(
    BuildContext context, {
    required AppState appState,
  }) async {
    await _check(
      context,
      appState: appState,
      interactive: true,
      force: true,
    );
  }

  static Future<void> maybeAutoCheck(
    BuildContext context, {
    required AppState appState,
    bool force = false,
  }) async {
    if (!appState.autoUpdateEnabled) return;
    await _check(
      context,
      appState: appState,
      interactive: false,
      force: force,
    );
  }

  static Future<void> _check(
    BuildContext context, {
    required AppState appState,
    required bool interactive,
    required bool force,
  }) async {
    if (_inProgress) return;

    if (!force) {
      final last = appState.autoUpdateLastCheckedAt;
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        if (elapsed < _autoCheckInterval) return;
      }
    }

    _inProgress = true;
    try {
      final svc = AppUpdateService();
      final result = await svc.checkForUpdate();
      if (!context.mounted) return;
      await appState.setAutoUpdateLastCheckedAt(DateTime.now());
      if (!context.mounted) return;

      final latest = (result.latestVersionFull ?? '').trim();
      if (latest.isEmpty) {
        if (!interactive) return;
        final open = await showDialog<bool>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('检查更新'),
            content: const Text(
              '已获取到版本信息，但无法解析版本号。是否打开下载页面？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dctx).pop(true),
                child: const Text('打开'),
              ),
            ],
          ),
        );
        if (open == true && context.mounted) {
          final url = result.release.htmlUrl.trim().isNotEmpty
              ? result.release.htmlUrl.trim()
              : repoUrl;
          await _openUrlOrSnack(context, url);
        }
        return;
      }

      if (!result.hasUpdate) {
        if (!interactive) return;
        final current = result.currentVersionFull.trim();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              current.isEmpty ? '已经是最新版本' : '已经是最新版本（$current）',
            ),
          ),
        );
        return;
      }

      final platform = AppUpdateService.currentPlatform;
      final candidates = AppUpdateService.candidateAssetsForPlatform(
        platform: platform,
        assets: result.release.assets,
      );

      final confirmed = await _confirmUpdate(
        context,
        current: result.currentVersionFull.trim(),
        latest: latest,
        notes: result.release.body.trim(),
        platform: platform,
      );
      if (confirmed != true || !context.mounted) return;

      await _performUpdate(
        context,
        appState: appState,
        platform: platform,
        release: result.release,
        candidates: candidates,
        interactive: interactive,
      );
    } catch (e) {
      if (!context.mounted) return;
      if (interactive) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查更新失败：$e')),
        );
      }
    } finally {
      _inProgress = false;
    }
  }

  static Future<bool?> _confirmUpdate(
    BuildContext context, {
    required String current,
    required String latest,
    required String notes,
    required AppUpdatePlatform platform,
  }) {
    final actionText = switch (platform) {
      AppUpdatePlatform.windows => '下载并安装',
      AppUpdatePlatform.android => '下载并安装',
      AppUpdatePlatform.macos => '下载并打开',
      AppUpdatePlatform.linux => '下载并打开',
      AppUpdatePlatform.ios => '打开下载页',
      AppUpdatePlatform.other => '打开下载页',
    };

    final hint = _platformHint(platform);

    return showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  current.isEmpty
                      ? '最新版本：$latest'
                      : '当前：$current  →  最新：$latest',
                ),
                if (hint != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    hint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(notes),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(actionText),
          ),
        ],
      ),
    );
  }

  static String? _platformHint(AppUpdatePlatform platform) {
    return switch (platform) {
      AppUpdatePlatform.android => '下载完成后会打开系统安装界面。如提示无法安装，请允许“安装未知应用”。',
      AppUpdatePlatform.macos => '下载完成后会打开 DMG，请将应用拖入 Applications 覆盖旧版本。',
      AppUpdatePlatform.linux => '下载完成后会打开压缩包，请解压并用新文件覆盖旧目录。',
      AppUpdatePlatform.ios => 'iOS 无法在应用内直接覆盖安装更新，将打开下载页面。',
      _ => null,
    };
  }

  static Future<void> _performUpdate(
    BuildContext context, {
    required AppState appState,
    required AppUpdatePlatform platform,
    required GitHubReleaseInfo release,
    required List<GitHubReleaseAsset> candidates,
    required bool interactive,
  }) async {
    final fallbackUrl =
        release.htmlUrl.trim().isNotEmpty ? release.htmlUrl.trim() : repoUrl;

    if (platform == AppUpdatePlatform.ios ||
        platform == AppUpdatePlatform.other) {
      await _openUrlOrSnack(context, fallbackUrl);
      return;
    }

    final asset = await _selectAsset(
      context,
      platform: platform,
      candidates: candidates,
      interactive: interactive,
    );
    if (!context.mounted) return;
    if (asset == null) {
      await _openUrlOrSnack(context, fallbackUrl);
      return;
    }

    final error = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateProgressDialog(platform: platform, asset: asset),
    );
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败：$error')),
      );
    }
  }

  static Future<GitHubReleaseAsset?> _selectAsset(
    BuildContext context, {
    required AppUpdatePlatform platform,
    required List<GitHubReleaseAsset> candidates,
    required bool interactive,
  }) async {
    if (candidates.isEmpty) return null;

    if (interactive &&
        candidates.length > 1 &&
        platform != AppUpdatePlatform.windows) {
      return _pickAssetIfNeeded(context, candidates);
    }

    return switch (platform) {
      AppUpdatePlatform.android => _pickAndroidAsset(candidates),
      AppUpdatePlatform.macos => await _pickMacAsset(candidates),
      AppUpdatePlatform.linux => _pickLinuxAsset(candidates),
      _ => candidates.first,
    };
  }

  static GitHubReleaseAsset _pickAndroidAsset(
      List<GitHubReleaseAsset> candidates) {
    GitHubReleaseAsset? universal;
    for (final a in candidates) {
      final name = a.name.trim().toLowerCase();
      if (name == 'linplayer-android.apk' ||
          name.endsWith('/linplayer-android.apk')) {
        universal = a;
        break;
      }
    }
    return universal ?? candidates.first;
  }

  static GitHubReleaseAsset _pickLinuxAsset(
      List<GitHubReleaseAsset> candidates) {
    for (final a in candidates) {
      if (a.name.toLowerCase().endsWith('.appimage')) return a;
    }
    for (final a in candidates) {
      if (a.name.toLowerCase().endsWith('.tar.gz')) return a;
    }
    return candidates.first;
  }

  static Future<GitHubReleaseAsset> _pickMacAsset(
    List<GitHubReleaseAsset> candidates,
  ) async {
    final machine = await _unameMachine();
    final isArm = machine != null &&
        (machine.contains('arm64') || machine.contains('aarch64'));
    GitHubReleaseAsset? preferred;
    for (final a in candidates) {
      final name = a.name.toLowerCase();
      if (isArm && name.contains('arm64')) {
        preferred = a;
        break;
      }
      if (!isArm &&
          (name.contains('x86_64') ||
              name.contains('x64') ||
              name.contains('intel'))) {
        preferred = a;
        break;
      }
    }
    return preferred ?? candidates.first;
  }

  static Future<String?> _unameMachine() async {
    if (!Platform.isMacOS && !Platform.isLinux) return null;
    try {
      final result = await Process.run('uname', const ['-m']);
      if (result.exitCode != 0) return null;
      return (result.stdout ?? '').toString().trim().toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static Future<GitHubReleaseAsset?> _pickAssetIfNeeded(
    BuildContext context,
    List<GitHubReleaseAsset> candidates,
  ) async {
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    String sizeLabel(int size) {
      if (size <= 0) return '';
      final mb = size / (1024 * 1024);
      return '${mb.toStringAsFixed(1)} MB';
    }

    return showDialog<GitHubReleaseAsset>(
      context: context,
      builder: (dctx) => SimpleDialog(
        title: const Text('选择下载包'),
        children: [
          ...candidates.map(
            (a) => SimpleDialogOption(
              onPressed: () => Navigator.of(dctx).pop(a),
              child: Row(
                children: [
                  Expanded(child: Text(a.name)),
                  const SizedBox(width: 8),
                  Text(
                    sizeLabel(a.size),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  static Future<void> _openUrlOrSnack(BuildContext context, String url) async {
    final ok = await launchUrlString(url);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接，请检查系统浏览器/网络设置')),
      );
    }
  }
}

class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.platform, required this.asset});

  final AppUpdatePlatform platform;
  final GitHubReleaseAsset asset;

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  double? _progress;
  String _status = '正在下载更新...';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final svc = AppUpdateService();
    try {
      final file = await svc.downloadAssetToTemp(
        widget.asset,
        onProgress: (received, total) {
          if (!mounted) return;
          if (total <= 0) {
            setState(() => _progress = null);
            return;
          }
          setState(() => _progress = received / total);
        },
      );
      if (!mounted) return;

      if (widget.platform == AppUpdatePlatform.windows) {
        setState(
          () => _status = '正在启动安装程序（如弹出权限提示请允许）...',
        );
        await svc.startWindowsInstaller(file);
        exit(0);
      }

      setState(() => _status = '正在打开安装程序...');
      String? type;
      if (widget.platform == AppUpdatePlatform.android &&
          widget.asset.name.toLowerCase().endsWith('.apk')) {
        type = 'application/vnd.android.package-archive';
      }
      final result = await OpenFilex.open(file.path, type: type);
      if (result.type != ResultType.done) {
        throw Exception(result.message);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    var progress = _progress;
    if (progress != null) {
      if (progress < 0) progress = 0;
      if (progress > 1) progress = 1;
    }

    return AlertDialog(
      title: const Text('正在更新'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_status),
          const SizedBox(height: 16),
          if (progress == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text('${(progress * 100).toStringAsFixed(0)}%'),
          ],
        ],
      ),
    );
  }
}
