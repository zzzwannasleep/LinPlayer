import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'danmaku_settings_page.dart';
import 'server_text_import_sheet.dart';
import 'services/app_update_service.dart';
import 'services/cover_cache_manager.dart';
import 'services/stream_cache.dart';
import 'src/ui/app_icon_service.dart';
import 'src/ui/app_components.dart';
import 'src/ui/glass_blur.dart';
import 'state/app_state.dart';
import 'state/danmaku_preferences.dart';
import 'state/preferences.dart';
import 'state/server_profile.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

enum _BackupIoAction { file, clipboard }

class _SettingsPageState extends State<SettingsPage> {
  static const _donateUrl = 'https://afdian.com/a/zzzwannasleep';
  static const _repoUrl = 'https://github.com/zzzwannasleep/LinPlayer';
  static const _customSentinel = '__custom__';
  static const _subtitleOff = 'off';
  double? _mpvCacheDraftMb;
  double? _uiScaleDraft;
  bool _checkingUpdate = false;
  String _currentVersionFull = '';

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _currentVersionFull = AppUpdateService.packageVersionFull(info);
      });
    } catch (_) {}
  }

  Future<void> _openServerTextImport(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ServerTextImportSheet(appState: widget.appState),
    );
  }

  String _backupFileName() {
    final now = DateTime.now();
    String pad2(int v) => v.toString().padLeft(2, '0');
    final y = now.year.toString().padLeft(4, '0');
    final m = pad2(now.month);
    final d = pad2(now.day);
    final hh = pad2(now.hour);
    final mm = pad2(now.minute);
    final ss = pad2(now.second);
    return 'linplayer_backup_$y$m${d}_$hh$mm$ss.json';
  }

  Future<T> _runWithBlockingDialog<T>(
    BuildContext context,
    Future<T> Function() action, {
    required String title,
    String subtitle = '请稍候…',
  }) async {
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(subtitle)),
          ],
        ),
      ),
    );
    try {
      return await action();
    } finally {
      if (context.mounted) nav.pop();
    }
  }

  Future<BackupServerSecretMode?> _askBackupMode(BuildContext context) async {
    BackupServerSecretMode selected = BackupServerSecretMode.password;
    return showDialog<BackupServerSecretMode>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setState) => AlertDialog(
          title: const Text('导出方式'),
          content: RadioGroup<BackupServerSecretMode>(
            groupValue: selected,
            onChanged: (v) =>
                setState(() => selected = v ?? BackupServerSecretMode.password),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<BackupServerSecretMode>(
                  value: BackupServerSecretMode.password,
                  title: Text('账号迁移（不导出 token）'),
                  subtitle: Text('导入时会重新登录，需联网；需要输入账号密码'),
                ),
                RadioListTile<BackupServerSecretMode>(
                  value: BackupServerSecretMode.token,
                  title: Text('会话迁移（导出 token）'),
                  subtitle: Text('导入无需重新登录；适合离线迁移'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(selected),
              child: const Text('继续'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askBackupPassphrase(
    BuildContext context, {
    required String title,
    required bool confirm,
  }) async {
    final passCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool show = false;
    String? error;

    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => StatefulBuilder(
          builder: (dctx, setState) => AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passCtrl,
                  obscureText: !show,
                  decoration: InputDecoration(
                    labelText: '备份密码',
                    errorText: error,
                    suffixIcon: IconButton(
                      tooltip: show ? '隐藏' : '显示',
                      icon: Icon(
                        show
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                      onPressed: () => setState(() => show = !show),
                    ),
                  ),
                ),
                if (confirm) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmCtrl,
                    obscureText: !show,
                    decoration: const InputDecoration(labelText: '确认备份密码'),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  '提示：备份密码越强，越不容易被暴力破解。',
                  style: Theme.of(dctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(dctx).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final p = passCtrl.text;
                  if (p.trim().length < 6) {
                    setState(() => error = '备份密码至少 6 位');
                    return;
                  }
                  if (confirm && p != confirmCtrl.text) {
                    setState(() => error = '两次输入不一致');
                    return;
                  }
                  Navigator.of(dctx).pop(p);
                },
                child: const Text('确定'),
              ),
            ],
          ),
        ),
      );
    } finally {
      passCtrl.dispose();
      confirmCtrl.dispose();
    }
  }

  Future<BackupServerLogin?> _askServerLoginForBackup(
    BuildContext context,
    ServerProfile server,
  ) async {
    final userCtrl = TextEditingController(text: server.username.trim());
    final pwdCtrl = TextEditingController();
    bool show = false;
    String? error;

    try {
      return await showDialog<BackupServerLogin>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => StatefulBuilder(
          builder: (dctx, setState) => AlertDialog(
            title: Text('服务器：${server.name}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  server.baseUrl,
                  style: Theme.of(dctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(dctx).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: userCtrl,
                  decoration: InputDecoration(
                    labelText: '用户名',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: pwdCtrl,
                  obscureText: !show,
                  decoration: InputDecoration(
                    labelText: '密码（可为空）',
                    suffixIcon: IconButton(
                      tooltip: show ? '隐藏' : '显示',
                      icon: Icon(
                        show
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                      onPressed: () => setState(() => show = !show),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final u = userCtrl.text.trim();
                  if (u.isEmpty) {
                    setState(() => error = '请输入用户名');
                    return;
                  }
                  Navigator.of(dctx).pop(
                    BackupServerLogin(username: u, password: pwdCtrl.text),
                  );
                },
                child: const Text('确定'),
              ),
            ],
          ),
        ),
      );
    } finally {
      userCtrl.dispose();
      pwdCtrl.dispose();
    }
  }

  Future<Map<String, BackupServerLogin>?> _collectServerLogins(
    BuildContext context,
  ) async {
    final result = <String, BackupServerLogin>{};
    for (final server in widget.appState.servers) {
      final login = await _askServerLoginForBackup(context, server);
      if (login == null) return null;
      result[server.id] = login;
      if (login.username.trim() != server.username.trim()) {
        // ignore: unawaited_futures
        widget.appState.updateServerMeta(server.id, username: login.username);
      }
    }
    return result;
  }

  int? _peekBackupVersion(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final v = decoded['version'];
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v.trim());
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _importBackupRaw(BuildContext context, String raw) async {
    final version = _peekBackupVersion(raw);
    if (version == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导入失败：不是有效的备份文件')),
      );
      return;
    }

    String? passphrase;
    if (version == 2) {
      passphrase = await _askBackupPassphrase(
        context,
        title: '输入备份密码',
        confirm: false,
      );
      if (passphrase == null) return;
    } else if (version == 1) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('旧版备份'),
          content: const Text(
            '检测到旧版备份（未加密，包含 token）。\n建议在原设备重新导出加密备份再导入。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('继续导入'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：不支持的备份版本：$version')),
      );
      return;
    }

    if (!context.mounted) return;

    try {
      await _runWithBlockingDialog(
        context,
        () async {
          await widget.appState.importBackupJson(
            raw,
            passphrase: passphrase,
          );
          await _postImportApplySideEffects();
        },
        title: '正在导入备份',
        subtitle: '解密/登录中…',
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导入成功')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _exportPlainBackup(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('导出免密码备份'),
        content: const Text(
          '免密码备份不加密，文件会包含 token 等敏感信息。\n'
          '任何拿到备份文件的人都可能直接登录你的服务器。\n\n'
          '仅建议在自己设备之间离线传输（U 盘/局域网），不要上传网盘/聊天软件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final json = widget.appState.exportBackupJson(pretty: true);

    final action = await showDialog<_BackupIoAction>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('导出免密码备份'),
        content: const Text('选择导出方式：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(_BackupIoAction.clipboard),
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(_BackupIoAction.file),
            child: const Text('保存为文件'),
          ),
        ],
      ),
    );

    if (action == null) return;

    try {
      switch (action) {
        case _BackupIoAction.clipboard:
          await Clipboard.setData(ClipboardData(text: json));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制备份到剪贴板')),
          );
          return;
        case _BackupIoAction.file:
          final path = await FilePicker.platform.saveFile(
            dialogTitle: '保存备份文件',
            fileName: _backupFileName(),
            type: FileType.custom,
            allowedExtensions: const ['json'],
          );
          if (path == null || path.trim().isEmpty) return;
          final normalized =
              path.toLowerCase().endsWith('.json') ? path : '$path.json';
          await File(normalized).writeAsString(json, flush: true);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已导出备份文件')),
          );
          return;
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  Future<void> _exportEncryptedBackup(BuildContext context) async {
    final mode = await _askBackupMode(context);
    if (mode == null) return;
    if (!context.mounted) return;

    final passphrase = await _askBackupPassphrase(
      context,
      title: '设置备份密码',
      confirm: true,
    );
    if (passphrase == null) return;
    if (!context.mounted) return;

    Map<String, BackupServerLogin>? logins;
    if (mode == BackupServerSecretMode.password &&
        widget.appState.servers.isNotEmpty) {
      logins = await _collectServerLogins(context);
      if (logins == null) return;
      if (!context.mounted) return;
    }

    final action = await showDialog<_BackupIoAction>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('导出加密备份'),
        content: const Text(
          '将导出加密备份（包含全部设置与 Emby 服务器）。\n请妥善保存备份文件与备份密码。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(_BackupIoAction.clipboard),
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(_BackupIoAction.file),
            child: const Text('保存为文件'),
          ),
        ],
      ),
    );

    if (action == null) return;
    if (!context.mounted) return;

    try {
      final json = await _runWithBlockingDialog(
        context,
        () => widget.appState.exportEncryptedBackupJson(
          passphrase: passphrase,
          mode: mode,
          serverLogins: logins,
          pretty: true,
        ),
        title: '正在生成备份',
        subtitle: '加密中…',
      );

      switch (action) {
        case _BackupIoAction.clipboard:
          await Clipboard.setData(ClipboardData(text: json));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制备份到剪贴板')),
          );
          return;
        case _BackupIoAction.file:
          final path = await FilePicker.platform.saveFile(
            dialogTitle: '保存备份文件',
            fileName: _backupFileName(),
            type: FileType.custom,
            allowedExtensions: const ['json'],
          );
          if (path == null || path.trim().isEmpty) return;
          final normalized =
              path.toLowerCase().endsWith('.json') ? path : '$path.json';
          await File(normalized).writeAsString(json, flush: true);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已导出备份文件')),
          );
          return;
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }

  Future<void> _importBackup(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text(
          '将覆盖本机全部设置与 Emby 服务器列表。\n建议先导出备份再导入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final action = await showDialog<_BackupIoAction>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('选择导入方式'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(_BackupIoAction.clipboard),
            child: const Text('从文本导入'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(_BackupIoAction.file),
            child: const Text('从文件导入'),
          ),
        ],
      ),
    );
    if (action == null) return;
    if (!context.mounted) return;

    switch (action) {
      case _BackupIoAction.file:
        await _importBackupFromFile(context);
        return;
      case _BackupIoAction.clipboard:
        await _importBackupFromText(context);
        return;
    }
  }

  Future<void> _postImportApplySideEffects() async {
    if (AppIconService.isSupported) {
      await AppIconService.setIconId(widget.appState.appIconId);
    }
  }

  Future<void> _importBackupFromFile(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: '选择备份文件',
        allowMultiple: false,
        withData: false,
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = result?.files.single.path;
      if (path == null || path.trim().isEmpty) return;

      final raw = await File(path).readAsString();
      if (!context.mounted) return;
      await _importBackupRaw(context, raw);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _importBackupFromText(BuildContext context) async {
    final ctrl = TextEditingController();
    try {
      final raw = await showDialog<String>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('从文本导入'),
          content: TextField(
            controller: ctrl,
            maxLines: 12,
            minLines: 6,
            decoration: const InputDecoration(
              hintText: '粘贴导出的 JSON 文本',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(ctrl.text),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (raw == null || raw.trim().isEmpty) return;

      if (!context.mounted) return;
      await _importBackupRaw(context, raw);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    } finally {
      ctrl.dispose();
    }
  }

  bool _isTv(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android &&
      MediaQuery.of(context).orientation == Orientation.landscape &&
      MediaQuery.of(context).size.shortestSide >= 720;

  List<DropdownMenuItem<String>> _audioLangItems(String current) {
    final base = <MapEntry<String, String>>[
      const MapEntry('', '默认'),
      const MapEntry('chi', '中文'),
      const MapEntry('jpn', '日语'),
      const MapEntry('eng', '英语'),
      const MapEntry(_customSentinel, '自定义…'),
    ];

    final isKnown = base.any((e) => e.key == current);
    final items = <DropdownMenuItem<String>>[
      if (current.trim().isNotEmpty && !isKnown)
        DropdownMenuItem(
          value: current,
          child: Text('自定义：$current'),
        ),
      ...base.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
    ];
    return items;
  }

  List<DropdownMenuItem<String>> _subtitleLangItems(String current) {
    final base = <MapEntry<String, String>>[
      const MapEntry('', '默认'),
      const MapEntry(_subtitleOff, '关闭'),
      const MapEntry('chi', '中文'),
      const MapEntry('jpn', '日语'),
      const MapEntry('eng', '英语'),
      const MapEntry(_customSentinel, '自定义…'),
    ];

    final isKnown = base.any((e) => e.key == current);
    final items = <DropdownMenuItem<String>>[
      if (current.trim().isNotEmpty && !isKnown)
        DropdownMenuItem(
          value: current,
          child: Text('自定义：$current'),
        ),
      ...base.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
    ];
    return items;
  }

  Future<String?> _askCustomLang(BuildContext context,
      {required String title, String? initial}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: '例如：chi / zho / jpn / eng / zh / en / ja',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmEnableUnlimitedStreamCache(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _UnlimitedStreamCacheConfirmDialog(),
    );
    return ok == true;
  }

  Future<void> _checkUpdates(BuildContext context) async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);

    try {
      final svc = AppUpdateService();
      final result = await svc.checkForUpdate();
      if (!context.mounted) return;

      final latest = (result.latestVersionFull ?? '').trim();
      if (latest.isEmpty) {
        final open = await showDialog<bool>(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Text('检查更新'),
            content: const Text('已获取到版本信息，但无法解析版本号。是否打开下载页面？'),
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
              : _repoUrl;
          final ok = await launchUrlString(url);
          if (!ok && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('无法打开链接，请检查系统浏览器/网络设置')),
            );
          }
        }
        return;
      }

      if (!result.hasUpdate) {
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

      final current = result.currentVersionFull.trim();
      final notes = result.release.body.trim();
      final platform = AppUpdateService.currentPlatform;
      final candidates = AppUpdateService.candidateAssetsForPlatform(
        platform: platform,
        assets: result.release.assets,
      );

      final confirmed = await showDialog<bool>(
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
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: Text(
                platform == AppUpdatePlatform.windows ? '下载并安装' : '去下载',
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;

      if (platform == AppUpdatePlatform.windows) {
        final asset = candidates.isNotEmpty ? candidates.first : null;
        if (asset == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到 Windows 安装包资源')),
          );
          return;
        }

        final error = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _UpdateProgressDialog(asset: asset),
        );
        if (error != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('更新失败：$error')),
          );
        }
        return;
      }

      final asset = await _pickAssetIfNeeded(context, candidates);
      final url = asset?.browserDownloadUrl.trim().isNotEmpty == true
          ? asset!.browserDownloadUrl.trim()
          : (result.release.htmlUrl.trim().isNotEmpty
              ? result.release.htmlUrl.trim()
              : _repoUrl);
      final ok = await launchUrlString(url);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接，请检查系统浏览器/网络设置')),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  Future<GitHubReleaseAsset?> _pickAssetIfNeeded(
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

  @override
  Widget build(BuildContext context) {
    final isTv = _isTv(context);
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final appState = widget.appState;
        final blurAllowed = !isTv;
        final enableBlur = blurAllowed && appState.enableBlurEffects;

        return Scaffold(
          appBar: GlassAppBar(
            enableBlur: enableBlur,
            child: AppBar(
              title: const Text('设置'),
              centerTitle: true,
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _Section(
                title: '外观',
                subtitle: blurAllowed
                    ? (enableBlur ? '手机/桌面启用毛玻璃等特效' : '已关闭毛玻璃特效（更流畅）')
                    : 'TV 端自动关闭高开销特效',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                            value: ThemeMode.system, label: Text('系统')),
                        ButtonSegment(
                            value: ThemeMode.light, label: Text('浅色')),
                        ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                      ],
                      selected: {appState.themeMode},
                      onSelectionChanged: (s) => appState.setThemeMode(s.first),
                    ),
                    const SizedBox(height: 10),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.zoom_out_map),
                      title: const Text('UI 缩放'),
                      subtitle: Builder(
                        builder: (context) {
                          final value =
                              (_uiScaleDraft ?? appState.uiScaleFactor)
                                  .clamp(0.5, 2.0)
                                  .toDouble();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '当前：${value.toStringAsFixed(2)}x（0.5-2.0）',
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: appState.uiScaleFactor == 1.0
                                        ? null
                                        : () {
                                            // ignore: unawaited_futures
                                            appState.setUiScaleFactor(1.0);
                                          },
                                    child: const Text('重置'),
                                  ),
                                ],
                              ),
                              Slider(
                                value: value,
                                min: 0.5,
                                max: 2.0,
                                divisions: 15,
                                label: '${value.toStringAsFixed(2)}x',
                                onChanged: (v) =>
                                    setState(() => _uiScaleDraft = v),
                                onChangeEnd: (v) {
                                  setState(() => _uiScaleDraft = null);
                                  // ignore: unawaited_futures
                                  appState.setUiScaleFactor(v);
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.uiTemplate == UiTemplate.proTool
                          ? true
                          : appState.compactMode,
                      onChanged: appState.uiTemplate == UiTemplate.proTool
                          ? null
                          : (v) => appState.setCompactMode(v),
                      title: const Text('紧凑模式'),
                      subtitle: Text(
                        appState.uiTemplate == UiTemplate.proTool
                            ? '专业工具模板固定启用'
                            : '缩小控件间距与高度（手机开启会更小）',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.showHomeLibraryQuickAccess,
                      onChanged: (v) =>
                          appState.setShowHomeLibraryQuickAccess(v),
                      title: const Text('首页媒体库快捷栏'),
                      subtitle:
                          const Text('在首页“继续观看”下方显示媒体库快速访问栏'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.enableBlurEffects,
                      onChanged: blurAllowed
                          ? (v) => appState.setEnableBlurEffects(v)
                          : null,
                      title: const Text('毛玻璃特效'),
                      subtitle: Text(
                        blurAllowed
                            ? '关闭可提升滚动/动画流畅度（尤其是高刷屏）'
                            : 'TV 端强制关闭以提升流畅度',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.useDynamicColor,
                      onChanged: (v) => appState.setUseDynamicColor(v),
                      title: const Text('莫奈取色（Material You）'),
                      subtitle: const Text('Android 12+ 生效，其它平台自动回退'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.dashboard_customize_outlined),
                      title: const Text('UI 模板'),
                      subtitle: const Text('不同风格/布局（手机 + 桌面）'),
                      trailing: SizedBox(
                        width: 240,
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<UiTemplate>(
                            value: appState.uiTemplate,
                            isExpanded: true,
                            items: UiTemplate.values
                                .map(
                                  (t) => DropdownMenuItem(
                                    value: t,
                                    child: Text(t.label),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v == null) return;
                              appState.setUiTemplate(v);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: '播放',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    SwitchListTile(
                      value: appState.preferHardwareDecode,
                      onChanged: (v) => appState.setPreferHardwareDecode(v),
                      title: const Text('优先硬解'),
                      subtitle: const Text('TV/低端设备建议关闭以提升兼容性'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    if (isAndroid) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.memory_outlined),
                        title: const Text('播放器内核'),
                        subtitle: const Text('Exo 更适合部分杜比视界 P8 片源（偏紫/偏绿）'),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<PlayerCore>(
                            value: appState.playerCore,
                            items: [
                              DropdownMenuItem(
                                value: PlayerCore.mpv,
                                child: Text(PlayerCore.mpv.label),
                              ),
                              DropdownMenuItem(
                                value: PlayerCore.exo,
                                child: Text('${PlayerCore.exo.label}（Android）'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              // ignore: unawaited_futures
                              appState.setPlayerCore(v);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('切换内核将在下次开始播放时生效'),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                    ] else ...[
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.memory_outlined),
                        title: Text('播放器内核'),
                        subtitle: Text('当前平台仅支持 MPV（Exo 仅 Android）'),
                        trailing: Text('MPV'),
                      ),
                      const Divider(height: 1),
                    ],
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.storage_outlined),
                      title: const Text('MPV 缓存大小'),
                      subtitle: Builder(
                        builder: (context) {
                          final cacheMb = (_mpvCacheDraftMb ??
                                  appState.mpvCacheSizeMb.toDouble())
                              .round()
                              .clamp(200, 2048);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('当前：${cacheMb}MB（200-2048MB，默认500MB）'),
                              Slider(
                                value: cacheMb.toDouble(),
                                min: 200,
                                max: 2048,
                                divisions: 2048 - 200,
                                label: '${cacheMb}MB',
                                onChanged: (v) =>
                                    setState(() => _mpvCacheDraftMb = v),
                                onChangeEnd: (v) {
                                  final mb = v.round().clamp(200, 2048);
                                  setState(() => _mpvCacheDraftMb = null);
                                  // ignore: unawaited_futures
                                  appState.setMpvCacheSizeMb(mb);
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    if (isDesktop) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.open_in_new),
                        title: const Text('外部 MPV（PC）'),
                        subtitle: Text(
                          appState.externalMpvPath.trim().isEmpty
                              ? '未设置：将尝试调用系统 mpv（PATH 或同目录）'
                              : appState.externalMpvPath,
                        ),
                        trailing: const Icon(Icons.folder_open),
                        onTap: () async {
                          final result = await FilePicker.platform.pickFiles(
                            dialogTitle: '选择 mpv 可执行文件',
                            allowMultiple: false,
                            withData: false,
                            type: FileType.any,
                          );
                          final path = result?.files.single.path;
                          if (path == null || path.trim().isEmpty) return;
                          // ignore: unawaited_futures
                          appState.setExternalMpvPath(path);
                        },
                      ),
                      if (appState.externalMpvPath.trim().isNotEmpty) ...[
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.delete_outline),
                          title: const Text('清除外部 MPV 路径'),
                          onTap: () {
                            // ignore: unawaited_futures
                            appState.setExternalMpvPath('');
                          },
                        ),
                      ],
                      const Divider(height: 1),
                    ],
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.audiotrack),
                      title: const Text('优先音轨'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: appState.preferredAudioLang,
                          items: _audioLangItems(appState.preferredAudioLang),
                          onChanged: (v) async {
                            if (v == null) return;
                            if (v == _customSentinel) {
                              final code = await _askCustomLang(
                                context,
                                title: '自定义音轨语言',
                                initial: appState.preferredAudioLang,
                              );
                              if (code == null) return;
                              await appState.setPreferredAudioLang(code);
                              return;
                            }
                            await appState.setPreferredAudioLang(v);
                          },
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.subtitles_outlined),
                      title: const Text('优先字幕'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: appState.preferredSubtitleLang,
                          items: _subtitleLangItems(
                              appState.preferredSubtitleLang),
                          onChanged: (v) async {
                            if (v == null) return;
                            if (v == _customSentinel) {
                              final code = await _askCustomLang(
                                context,
                                title: '自定义字幕语言',
                                initial: appState.preferredSubtitleLang,
                              );
                              if (code == null) return;
                              await appState.setPreferredSubtitleLang(code);
                              return;
                            }
                            await appState.setPreferredSubtitleLang(v);
                          },
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.comment_outlined),
                      title: const Text('弹幕'),
                      subtitle: Text(
                        appState.danmakuLoadMode == DanmakuLoadMode.online
                            ? '在线：${appState.danmakuApiUrls.isEmpty ? '未配置弹幕源' : appState.danmakuApiUrls.first}'
                            : '本地弹幕',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                DanmakuSettingsPage(appState: widget.appState),
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.video_file_outlined),
                      title: const Text('优先视频版本'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<VideoVersionPreference>(
                          value: appState.preferredVideoVersion,
                          items: VideoVersionPreference.values
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(p.label),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            appState.setPreferredVideoVersion(v);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: '备份与迁移',
                subtitle: '跨设备同步设置/服务器',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.upload_file_outlined),
                      title: const Text('导出备份（免密码）'),
                      subtitle: const Text('不加密：导出全部设置与服务器 token'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _exportPlainBackup(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.lock_outline),
                      title: const Text('导出加密备份（推荐）'),
                      subtitle: const Text('需要备份密码：可选导出账号密码/会话 token'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _exportEncryptedBackup(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.download_for_offline_outlined),
                      title: const Text('导入备份'),
                      subtitle: const Text('覆盖本机全部设置与 Emby 服务器列表'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _importBackup(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.content_paste_outlined),
                      title: const Text('从文本提取并导入服务器'),
                      subtitle: const Text('解析“线路 & 用户密码”消息，批量创建服务器/线路'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openServerTextImport(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Section(
                title: '应用',
                enableBlur: enableBlur,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.apps_outlined),
                      title: const Text('应用图标'),
                      subtitle: Text(AppIconService.isSupported
                          ? '切换后可能需要等待桌面刷新'
                          : '仅 Android 支持'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: appState.appIconId,
                          items: const [
                            DropdownMenuItem(
                                value: 'default', child: Text('默认')),
                            DropdownMenuItem(value: 'pink', child: Text('粉色')),
                            DropdownMenuItem(
                                value: 'purple', child: Text('紫色')),
                            DropdownMenuItem(
                                value: 'miku', child: Text('初音未来')),
                          ],
                          onChanged: !AppIconService.isSupported
                              ? null
                              : (v) async {
                                  if (v == null) return;
                                  final ok = await AppIconService.setIconId(v);
                                  if (!ok && context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('切换失败（可能不支持当前系统/桌面）')),
                                    );
                                    return;
                                  }
                                  await appState.setAppIconId(v);
                                },
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.volunteer_activism_outlined),
                      title: const Text('捐赠'),
                      subtitle: const Text('支持作者继续开发（爱发电）'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () async {
                        final ok = await launchUrlString(_donateUrl);
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('无法打开链接，请检查系统浏览器/网络设置')),
                          );
                        }
                      },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      value: appState.unlimitedStreamCache,
                      onChanged: (v) async {
                        if (v) {
                          final confirmed =
                              await _confirmEnableUnlimitedStreamCache(
                            context,
                          );
                          if (!confirmed) return;
                        }
                        await appState.setUnlimitedStreamCache(v);
                      },
                      secondary: const Icon(Icons.all_inclusive),
                      title: const Text('不限制视频流缓存'),
                      subtitle: const Text(
                        '开启后在线播放会尽量缓存到结束，容易被误判为下载，请谨慎使用。',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('清理视频流缓存'),
                      subtitle: const Text('删除本地缓存的视频流数据'),
                      onTap: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dctx) => AlertDialog(
                            title: const Text('清理视频流缓存'),
                            content: const Text(
                              '将删除已缓存的视频流数据，下次播放时会重新缓存。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(dctx).pop(false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.of(dctx).pop(true),
                                child: const Text('清理'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        try {
                          await StreamCache.clear();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已清理视频流缓存')),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('清理失败：$e')),
                          );
                        }
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('清理封面缓存'),
                      subtitle: const Text('删除本地缓存的封面/随机推荐图片'),
                      onTap: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dctx) => AlertDialog(
                            title: const Text('清理封面缓存'),
                            content: const Text(
                              '将删除已缓存的封面/随机推荐图片，下次展示时会重新下载。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(dctx).pop(false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.of(dctx).pop(
                                  true,
                                ),
                                child: const Text('清理'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        try {
                          await CoverCacheManager.instance.emptyCache();
                          PaintingBinding.instance.imageCache.clear();
                          PaintingBinding.instance.imageCache.clearLiveImages();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已清理封面缓存')),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('清理失败：$e')),
                          );
                        }
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.system_update_alt_outlined),
                      title: const Text('检查更新'),
                      subtitle: _currentVersionFull.trim().isEmpty
                          ? null
                          : Text('当前版本：${_currentVersionFull.trim()}'),
                      trailing: _checkingUpdate
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap:
                          _checkingUpdate ? null : () => _checkUpdates(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.info_outline),
                      title: const Text('关于'),
                      subtitle: const Text(_repoUrl),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () async {
                        final ok = await launchUrlString(_repoUrl);
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('无法打开链接，请检查系统浏览器/网络设置'),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.asset});

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
      setState(() => _status = '正在启动安装程序（如弹出权限提示请允许）...');
      await svc.startWindowsInstaller(file);
      exit(0);
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

class _UnlimitedStreamCacheConfirmDialog extends StatefulWidget {
  const _UnlimitedStreamCacheConfirmDialog();

  @override
  State<_UnlimitedStreamCacheConfirmDialog> createState() =>
      _UnlimitedStreamCacheConfirmDialogState();
}

class _UnlimitedStreamCacheConfirmDialogState
    extends State<_UnlimitedStreamCacheConfirmDialog> {
  static const _waitSeconds = 3;
  int _remaining = _waitSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _remaining -= 1;
        if (_remaining <= 0) {
          _remaining = 0;
          timer.cancel();
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canConfirm = _remaining == 0;
    return AlertDialog(
      title: const Text('开启不限制缓存？'),
      content: const Text(
        '开启后将会一直缓存到结束，容易被误判为下载。\n'
        '注意使用。\n\n'
        '等待 3 秒后「确定」按钮才可以点击。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canConfirm ? () => Navigator.of(context).pop(true) : null,
          child: Text(canConfirm ? '确定' : '确定（$_remaining）'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    this.subtitle,
    required this.child,
    required this.enableBlur,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool enableBlur;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      enableBlur: enableBlur,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if ((subtitle ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!.trim(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
