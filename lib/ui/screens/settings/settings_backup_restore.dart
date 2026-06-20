part of 'settings_screen.dart';

class BackupRestoreScreen extends ConsumerWidget {
  const BackupRestoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final webdavConfig = ref.watch(webdavConfigProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16).copyWith(bottom: 120),
        children: [
          // 本地备份
          const Padding(
            padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
            child: Text(
              '本地备份',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: () => _showExportDialog(context, ref),
            icon: const Icon(Icons.backup),
            label: const Text('导出备份'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showImportDialog(context, ref),
            icon: const Icon(Icons.restore),
            label: const Text('导入备份'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showImportJsonDialog(context),
            icon: const Icon(Icons.file_upload),
            label: const Text('导入服务器配置（JSON）'),
          ),

          // WebDAV配置
          const Divider(height: 32),
          const Padding(
            padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
            child: Text(
              'WebDAV 同步',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          if (webdavConfig != null) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_done, color: Color(0xFF5B8DEF)),
                title: const Text('WebDAV 已配置'),
                subtitle: Text(webdavConfig.serverUrl),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () =>
                      _showWebDAVConfigDialog(context, ref, webdavConfig),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _showWebDAVBackupDialog(context, ref),
              icon: const Icon(Icons.cloud_upload),
              label: const Text('备份到 WebDAV'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showWebDAVRestoreDialog(context, ref),
              icon: const Icon(Icons.cloud_download),
              label: const Text('从 WebDAV 还原'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                ref.read(webdavConfigProvider.notifier).clearConfig();
              },
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              label: const Text('清除 WebDAV 配置',
                  style: TextStyle(color: Colors.red)),
            ),
          ] else ...[
            OutlinedButton.icon(
              onPressed: () => _showWebDAVConfigDialog(context, ref, null),
              icon: const Icon(Icons.cloud),
              label: const Text('配置 WebDAV'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showExportDialog(BuildContext context, WidgetRef ref) async {
    // 备份含服务器账号密码/Token，强制用口令加密整包（H12）。
    final pass = await _promptPassphrase(context, forExport: true);
    if (pass == null || !context.mounted) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出备份',
      fileName: 'linplayer-backup.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null) return;
    try {
      final plain = jsonEncode(_buildBackupPayload(ref));
      final wrapper = await BackupCrypto.encrypt(plain, pass);
      await File(path).writeAsString(jsonEncode(wrapper));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份已加密导出到: $path')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  /// 备份口令输入框。导出时需二次确认；导入时仅输入一次。返回 null=取消。
  Future<String?> _promptPassphrase(BuildContext context,
      {required bool forExport}) {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(builder: (dialogContext, setState) {
          return AlertDialog(
            title: Text(forExport ? '设置备份密码' : '输入备份密码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  forExport
                      ? '备份将用此密码加密（含服务器账号密码/Token）。务必记住——'
                          '忘记密码将无法恢复，与他人互导时对方也需要此密码。'
                      : '此备份已加密，请输入导出时设置的密码。',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: '密码', border: OutlineInputBorder()),
                ),
                if (forExport) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: '确认密码', border: OutlineInputBorder()),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ],
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消')),
              FilledButton(
                onPressed: () {
                  final pass = controller.text;
                  if (pass.isEmpty) {
                    setState(() => error = '密码不能为空');
                    return;
                  }
                  if (forExport && pass != confirmController.text) {
                    setState(() => error = '两次输入不一致');
                    return;
                  }
                  Navigator.pop(dialogContext, pass);
                },
                child: Text(forExport ? '加密导出' : '解密导入'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _showImportDialog(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('将覆盖当前的服务器配置和设置。确定要继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '导入备份',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      final content = await File(path).readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final payload = await _decodeBackup(context, json);
      if (payload == null) return; // 取消输入密码
      await _restoreBackupPayload(ref, payload);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('备份已导入')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导入失败：密码错误或文件已损坏')),
        );
      }
    }
  }

  /// 把读到的备份 JSON 解为明文 payload：加密备份则提示输入密码解密，
  /// 旧版明文备份直接返回。返回 null = 用户取消输入密码。
  Future<Map<String, dynamic>?> _decodeBackup(
      BuildContext context, Map<String, dynamic> json) async {
    if (!BackupCrypto.isEncrypted(json)) return json; // 兼容旧明文备份
    final pass = await _promptPassphrase(context, forExport: false);
    if (pass == null) return null;
    final plain = await BackupCrypto.decrypt(json, pass);
    return jsonDecode(plain) as Map<String, dynamic>;
  }

  void _showImportJsonDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入服务器配置'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '粘贴 JSON 配置...',
            border: OutlineInputBorder(),
          ),
          maxLines: 5,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('配置已导入')),
              );
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _showWebDAVConfigDialog(
      BuildContext context, WidgetRef ref, WebdavConfig? existingConfig) {
    final serverController =
        TextEditingController(text: existingConfig?.serverUrl ?? '');
    final usernameController =
        TextEditingController(text: existingConfig?.username ?? '');
    final passwordController =
        TextEditingController(text: existingConfig?.password ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('WebDAV 配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: serverController,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://dav.example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(
                labelText: '账户',
                hintText: '用户名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                labelText: '密码',
                hintText: '密码',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              ref.read(webdavConfigProvider.notifier).setConfig(
                    serverController.text.trim(),
                    usernameController.text.trim(),
                    passwordController.text,
                  );
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('WebDAV 配置已保存')),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _showWebDAVBackupDialog(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('备份到 WebDAV'),
        content: const Text('将当前所有设置和服务器配置备份到 WebDAV 服务器。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('备份')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final config = ref.read(webdavConfigProvider);
    if (config == null) return;
    final pass = await _promptPassphrase(context, forExport: true);
    if (pass == null) return;
    try {
      final service = WebDAVService(
        serverUrl: config.serverUrl,
        username: config.username,
        password: config.password,
      );
      final plain = jsonEncode(_buildBackupPayload(ref));
      final backupData = jsonEncode(await BackupCrypto.encrypt(plain, pass));
      await service.backupApp(backupData);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已成功加密备份到 WebDAV')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份失败: $e')),
        );
      }
    }
  }

  Future<void> _showWebDAVRestoreDialog(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从 WebDAV 还原'),
        content: const Text('将从 WebDAV 服务器下载备份并覆盖当前设置。确定要继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('还原')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final config = ref.read(webdavConfigProvider);
    if (config == null) return;
    try {
      final service = WebDAVService(
        serverUrl: config.serverUrl,
        username: config.username,
        password: config.password,
      );
      final backupData = await service.restoreApp();
      final json = jsonDecode(backupData) as Map<String, dynamic>;
      if (!context.mounted) return;
      final payload = await _decodeBackup(context, json);
      if (payload == null) return;
      await _restoreBackupPayload(ref, payload);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已成功从 WebDAV 还原设置')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('还原失败：密码错误或文件已损坏')),
        );
      }
    }
  }
}

/// 扩展线路同步设置页面
