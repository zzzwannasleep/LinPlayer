part of 'settings_screen.dart';

/// 代理 / 网络设置页（移动端 + 桌面端共用）。
///
/// 支持 HTTP(S) / SOCKS4 / SOCKS5 自定义代理，可选是否代理媒体流播放。
/// SOCKS 仅作用于 Dart 层请求（API/图片/字幕）；媒体流走代理仅 HTTP 代理有效，
/// 因 libmpv 不支持 SOCKS。
class NetworkSettingsScreen extends ConsumerStatefulWidget {
  const NetworkSettingsScreen({super.key});

  @override
  ConsumerState<NetworkSettingsScreen> createState() =>
      _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends ConsumerState<NetworkSettingsScreen> {
  late ProxyType _type;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _userController;
  late final TextEditingController _passController;
  late bool _proxyMedia;

  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(proxyConfigProvider);
    _type = config.type;
    _hostController = TextEditingController(text: config.host);
    _portController =
        TextEditingController(text: config.port > 0 ? '${config.port}' : '');
    _userController = TextEditingController(text: config.username);
    _passController = TextEditingController(text: config.password);
    _proxyMedia = config.proxyMedia;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  ProxyConfig _buildConfig() {
    return ProxyConfig(
      type: _type,
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 0,
      username: _userController.text,
      password: _passController.text,
      proxyMedia: _proxyMedia,
    );
  }

  Future<void> _save() async {
    final config = _buildConfig();
    await ref.read(proxyConfigProvider.notifier).save(config);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(config.isEnabled ? '代理已保存并生效' : '已关闭代理'),
      ),
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await testProxyConnection(_buildConfig());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result.ok;
      _testResult = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _type != ProxyType.none;
    return Scaffold(
      appBar: AppBar(title: const Text('代理设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          const _NetworkSectionLabel('代理协议'),
          Card(
            child: Column(
              children: [
                for (final type in ProxyType.values)
                  RadioListTile<ProxyType>(
                    value: type,
                    groupValue: _type,
                    title: Text(type.label),
                    dense: true,
                    onChanged: (v) => setState(() => _type = v ?? ProxyType.none),
                  ),
              ],
            ),
          ),
          if (enabled) ...[
            const SizedBox(height: 16),
            const _NetworkSectionLabel('服务器'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _hostController,
                      decoration: const InputDecoration(
                        labelText: '主机 (Host)',
                        hintText: '例如 127.0.0.1',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口 (Port)',
                        hintText: '例如 7890',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _NetworkSectionLabel('认证（可选）'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _userController,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '密码',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: SwitchListTile(
                value: _proxyMedia,
                title: const Text('代理媒体流播放'),
                subtitle: Text(
                  _type.isSocks
                      ? '⚠️ 媒体播放器(libmpv)不支持 SOCKS，此项仅对 HTTP 代理生效；'
                          'SOCKS 仅代理 API/图片/字幕等请求。'
                      : '开启后视频播放也经代理；关闭则播放直连、仅代理 API 等请求。',
                ),
                onChanged: (v) => setState(() => _proxyMedia = v),
              ),
            ),
          ],
          if (_testResult != null) ...[
            const SizedBox(height: 16),
            Card(
              color: _testOk
                  ? Colors.green.withValues(alpha: 0.12)
                  : Colors.red.withValues(alpha: 0.12),
              child: ListTile(
                leading: Icon(
                  _testOk ? Icons.check_circle : Icons.error,
                  color: _testOk ? Colors.green : Colors.red,
                ),
                title: Text(_testResult!),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (!enabled || _testing) ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NetworkSectionLabel extends StatelessWidget {
  final String text;
  const _NetworkSectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
