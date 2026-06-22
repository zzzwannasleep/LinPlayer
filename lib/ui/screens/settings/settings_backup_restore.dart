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

          // 设备密钥（非对称加密互传）
          const Divider(height: 32),
          const Padding(
            padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
            child: Text(
              '设备密钥（加密互传）',
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
              '把你的公钥发给对方，对方导出时选「加密给设备」并填入，'
              '生成的备份只有你这台设备能解开——无需互相约定密码。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _showMyDeviceKeyDialog(context),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('我的公钥（二维码 / 复制）'),
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
    // 备份含服务器账号密码/Token，必须加密。两种方式：口令(H12) 或 加密给设备(H13)。
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择导出方式'),
        children: [
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('用密码加密'),
            subtitle: const Text('对方导入时需输入同一密码'),
            onTap: () => Navigator.pop(dialogContext, 'password'),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_key),
            title: const Text('加密给指定设备（公钥）'),
            subtitle: const Text('填入对方公钥，只有对方设备能解开，无需密码'),
            onTap: () => Navigator.pop(dialogContext, 'recipient'),
          ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;
    if (mode == 'password') {
      await _exportWithPassword(context, ref);
    } else {
      await _exportToRecipient(context, ref);
    }
  }

  Future<void> _exportWithPassword(BuildContext context, WidgetRef ref) async {
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

  /// 加密给指定设备：用对方公钥封装 + 本机 Ed25519 私钥签名。
  Future<void> _exportToRecipient(BuildContext context, WidgetRef ref) async {
    final recipient = await _promptRecipientKey(context);
    if (recipient == null || !context.mounted) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出加密备份',
      fileName: 'linplayer-sealed-backup.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null) return;
    try {
      final myPub = await BackupIdentity.instance.myPublicKey();
      final signKey = await BackupIdentity.instance.signingKeyPair();
      final plain = jsonEncode(_buildBackupPayload(ref));
      final wrapper = await BackupCrypto.sealTo(
        plain,
        recipient: recipient,
        senderEd25519: signKey,
        senderPublicKey: myPub,
        exportTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
      await File(path).writeAsString(jsonEncode(wrapper));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已加密给设备 ${recipient.fingerprint}：$path')),
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

  /// 输入/扫描收件人公钥。返回 null=取消或无效。
  Future<BackupPublicKey?> _promptRecipientKey(BuildContext context) {
    final controller = TextEditingController();
    final canScan =
        Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    return showDialog<BackupPublicKey>(
      context: context,
      builder: (dialogContext) {
        String? error;
        String? fp;
        return StatefulBuilder(builder: (dialogContext, setState) {
          BackupPublicKey? tryParse() {
            try {
              return BackupPublicKey.decode(controller.text);
            } catch (_) {
              return null;
            }
          }

          return AlertDialog(
            title: const Text('加密给设备'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '粘贴对方在「我的公钥」里复制的公钥串（LPKEY1:…），'
                  '或扫描其二维码。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: '对方公钥', border: OutlineInputBorder()),
                  onChanged: (_) => setState(() {
                    final pub = tryParse();
                    fp = pub?.fingerprint;
                    error = null;
                  }),
                ),
                if (canScan) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final scanned = await _scanPublicKey(dialogContext);
                        if (scanned != null) {
                          controller.text = scanned;
                          setState(() {
                            fp = tryParse()?.fingerprint;
                            error = null;
                          });
                        }
                      },
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('扫描二维码'),
                    ),
                  ),
                ],
                if (fp != null) ...[
                  const SizedBox(height: 8),
                  Text('指纹: $fp（请与对方口头核对一致）',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.green)),
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
                  final pub = tryParse();
                  if (pub == null) {
                    setState(() => error = '公钥格式无效');
                    return;
                  }
                  Navigator.pop(dialogContext, pub);
                },
                child: const Text('加密导出'),
              ),
            ],
          );
        });
      },
    );
  }

  /// 全屏相机扫描，返回扫到的字符串（仅移动/macOS 调用）。
  Future<String?> _scanPublicKey(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: const Text('扫描对方公钥')),
          body: MobileScanner(
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final value = barcode.rawValue;
                if (value != null &&
                    value.startsWith(BackupIdentity.tokenPrefix)) {
                  Navigator.of(ctx).pop(value);
                  return;
                }
              }
            },
          ),
        ),
      ),
    );
  }

  /// 展示本设备公钥：二维码 + 可复制文本 + 指纹。
  Future<void> _showMyDeviceKeyDialog(BuildContext context) async {
    BackupPublicKey pub;
    try {
      pub = await BackupIdentity.instance.myPublicKey();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('生成设备密钥失败: $e')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final token = pub.encode();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('我的公钥'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(
                  data: token,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                token,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 8),
              Text('指纹: ${pub.fingerprint}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: token));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('公钥已复制')),
                );
              }
            },
            child: const Text('复制公钥'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭')),
        ],
      ),
    );
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
          const SnackBar(content: Text('导入失败：密码错误或文件已损坏')),
        );
      }
    }
  }

  /// 把读到的备份 JSON 解为明文 payload：加密备份则提示输入密码解密，
  /// 旧版明文备份直接返回。返回 null = 用户取消输入密码。
  Future<Map<String, dynamic>?> _decodeBackup(
      BuildContext context, Map<String, dynamic> json) async {
    // 加密给本设备的备份（非对称）：用本机私钥解封，无需密码。
    if (BackupCrypto.isSealed(json)) {
      final encKey = await BackupIdentity.instance.encryptionKeyPair();
      final myPub = await BackupIdentity.instance.myPublicKey();
      final result = await BackupCrypto.openSealed(
        json,
        recipientX25519: encKey,
        recipientPublicKey: myPub,
      );
      if (context.mounted) {
        final sender = result.senderPublicKey?.fingerprint ?? '未知';
        final sig = result.signatureValid ? '签名已验证' : '⚠ 签名未通过';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('来自设备 $sender · $sig')),
        );
      }
      return jsonDecode(result.plaintext) as Map<String, dynamic>;
    }
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
