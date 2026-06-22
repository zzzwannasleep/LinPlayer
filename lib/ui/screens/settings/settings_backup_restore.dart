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
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '备份含服务器账号密码/Token，导出时会加密成乱码，任何兼容客户端无需密码即可导入。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          FilledButton.icon(
            onPressed: () => _exportBackup(context, ref),
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

  /// 导出备份:通用配置(Richasy 兼容)格式,容器内带 `_key`,把明文密码/Token
  /// 挡成乱码;免密、任何兼容客户端可直接导入。全程无提示。
  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出备份',
      fileName: 'linplayer-config.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null) return;
    try {
      final container = await _buildCommonConfig(ref);
      await File(path).writeAsString(jsonEncode(container));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份已导出: $path')),
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

  /// 把当前服务器 + 设置打包成通用配置容器。
  Future<Map<String, dynamic>> _buildCommonConfig(WidgetRef ref) async {
    final payload = _buildBackupPayload(ref);
    return CommonConfig.build(
      ref.read(serverListProvider),
      exportTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      extra: {
        'linplayer_settings': payload['settings'],
        if (payload['currentServerId'] != null)
          'current_server_id': payload['currentServerId'],
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
      if (!context.mounted) return;
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
          const SnackBar(content: Text('导入失败：文件已损坏或格式不支持')),
        );
      }
    }
  }

  /// 把读到的备份 JSON 解为统一 payload。
  /// - 通用配置(默认导出)：用 _key/内置密钥解出服务器列表。
  /// - 旧版口令加密备份：提示输入密码解密(向后兼容)。
  /// - 旧版明文备份：直接返回。
  /// 返回 null = 用户取消输入密码。
  Future<Map<String, dynamic>?> _decodeBackup(
      BuildContext context, Map<String, dynamic> json) async {
    if (CommonConfig.isCommonConfig(json)) {
      final servers = await CommonConfig.parse(json);
      final extra = CommonConfig.additionalData(json);
      final settings =
          (extra?['linplayer_settings'] as Map?)?.cast<String, dynamic>();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已识别备份（${servers.length} 个服务器）')),
        );
      }
      return {
        'servers': servers.map(serverConfigToJson).toList(),
        if (settings != null) 'settings': settings,
        if (extra?['current_server_id'] != null)
          'currentServerId': extra!['current_server_id'],
      };
    }
    // 向后兼容：旧版口令加密备份。
    if (BackupCrypto.isEncrypted(json)) {
      final pass = await _promptImportPassphrase(context);
      if (pass == null) return null;
      final plain = await BackupCrypto.decrypt(json, pass);
      return jsonDecode(plain) as Map<String, dynamic>;
    }
    return json; // 旧版明文备份
  }

  /// 旧版加密备份的密码输入框(仅导入时用)。返回 null=取消。
  Future<String?> _promptImportPassphrase(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(builder: (dialogContext, setState) {
          return AlertDialog(
            title: const Text('输入备份密码'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('此备份由旧版本加密，请输入当时设置的密码。',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: '密码', border: OutlineInputBorder()),
                ),
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
                  if (controller.text.isEmpty) {
                    setState(() => error = '密码不能为空');
                    return;
                  }
                  Navigator.pop(dialogContext, controller.text);
                },
                child: const Text('解密导入'),
              ),
            ],
          );
        });
      },
    );
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
    try {
      final service = WebDAVService(
        serverUrl: config.serverUrl,
        username: config.username,
        password: config.password,
      );
      final backupData = jsonEncode(await _buildCommonConfig(ref));
      await service.backupApp(backupData);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已备份到 WebDAV')),
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
          const SnackBar(content: Text('还原失败：文件已损坏或格式不支持')),
        );
      }
    }
  }
}

/// 扩展线路同步设置页面
