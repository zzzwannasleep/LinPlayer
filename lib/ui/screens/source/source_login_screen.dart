import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_login_service.dart';
import '../../../core/sources/source_registry.dart';
import 'quark_qr_login_view.dart';

/// 网盘/聚合源登录页（移动端）。
///
/// 初版覆盖账密型源（OpenList、Ani-rss）。夸克等扫码/Cookie 型在 P5 接入时
/// 再按 [SourceTypeDescriptor.loginMethods] 分支扩展本页。
class SourceLoginScreen extends ConsumerStatefulWidget {
  final SourceKind kind;

  const SourceLoginScreen({super.key, required this.kind});

  @override
  ConsumerState<SourceLoginScreen> createState() => _SourceLoginScreenState();
}

class _SourceLoginScreenState extends ConsumerState<SourceLoginScreen> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _cookieCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  // 夸克登录方式：0=扫码，1=Cookie 粘贴。
  int _quarkMethod = 0;

  SourceTypeDescriptor get _descriptor =>
      sourceTypeOf(widget.kind) ?? kSourceTypes.first;

  bool get _isQuark => widget.kind == SourceKind.quark;
  bool get _isCookieLogin => _isQuark && _quarkMethod == 1;

  void _onLoggedIn(ServerConfig server) {
    ref.read(serverListProvider.notifier).addServer(server);
    ref.read(currentServerProvider.notifier).state = server;
    ref.read(authStateProvider.notifier).state = AuthState.authenticated;
    if (mounted) context.go('/browse');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _cookieCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isCookieLogin) {
      if (_cookieCtrl.text.trim().isEmpty) {
        setState(() => _error = '请粘贴 Cookie');
        return;
      }
    } else if (_urlCtrl.text.trim().isEmpty) {
      setState(() => _error = '请填写服务器地址');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final server = await _login();
      if (!mounted) return;
      _onLoggedIn(server); // 登录成功直接进入该源的文件浏览页。
    } on SourceException catch (e) {
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '登录失败: $e';
      });
    }
  }

  Future<dynamic> _login() {
    switch (widget.kind) {
      case SourceKind.openlist:
        return SourceLoginService.loginOpenList(
          name: _nameCtrl.text,
          baseUrl: _urlCtrl.text,
          username: _userCtrl.text,
          password: _passCtrl.text,
        );
      case SourceKind.anirss:
        return SourceLoginService.loginAniRss(
          name: _nameCtrl.text,
          baseUrl: _urlCtrl.text,
          username: _userCtrl.text,
          password: _passCtrl.text,
        );
      case SourceKind.quark:
        return SourceLoginService.loginQuarkCookie(
          name: _nameCtrl.text,
          cookie: _cookieCtrl.text,
        );
      default:
        throw SourceException('该源暂未支持登录');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _descriptor;
    return Scaffold(
      appBar: AppBar(title: Text('添加 ${d.name}')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: d.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(d.icon, color: d.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(d.subtitle,
                    style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color)),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '备注名称（可选）',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 16),
          if (_isQuark) _buildQuarkBody() else _buildPasswordBody(),
        ],
      ),
    );
  }

  Widget _buildQuarkBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('扫码登录'), icon: Icon(Icons.qr_code)),
            ButtonSegment(
                value: 1, label: Text('Cookie'), icon: Icon(Icons.cookie_outlined)),
          ],
          selected: {_quarkMethod},
          onSelectionChanged: (s) => setState(() {
            _quarkMethod = s.first;
            _error = null;
          }),
        ),
        const SizedBox(height: 20),
        if (_quarkMethod == 0)
          QuarkQrLoginView(
            currentName: () => _nameCtrl.text,
            onSuccess: _onLoggedIn,
          )
        else ...[
          const Text(
            '在电脑浏览器登录 pan.quark.cn，按 F12 → 网络，复制任一 drive 请求的 '
            'Cookie 整段粘贴到下方。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cookieCtrl,
            maxLines: 5,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Cookie',
              hintText: '__pus=...; __puus=...; ...',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          _submitButton(),
        ],
      ],
    );
  }

  Widget _buildPasswordBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _urlCtrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '服务器地址',
            hintText: 'https://example.com:5244',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _userCtrl,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '用户名',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _passCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '密码',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 24),
        _submitButton(),
      ],
    );
  }

  Widget _submitButton() {
    return FilledButton(
      onPressed: _loading ? null : _submit,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      child: _loading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('登录并添加'),
    );
  }
}
