import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_login_service.dart';
import '../../../core/sources/source_registry.dart';
import '../../../ui/screens/source/quark_qr_login_view.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focusable.dart';

/// TV 端网盘/聚合源登录页（账密型，OpenList/Ani-rss）。聚焦输入框唤起 leanback IME。
class TvSourceLoginScreen extends ConsumerStatefulWidget {
  final SourceKind kind;

  const TvSourceLoginScreen({super.key, required this.kind});

  @override
  ConsumerState<TvSourceLoginScreen> createState() =>
      _TvSourceLoginScreenState();
}

class _TvSourceLoginScreenState extends ConsumerState<TvSourceLoginScreen> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _nameController = TextEditingController();
  final _cookieController = TextEditingController();
  bool _loading = false;
  String? _error;
  int _quarkMethod = 0; // 0=扫码，1=Cookie

  SourceTypeDescriptor get _descriptor =>
      sourceTypeOf(widget.kind) ?? kSourceTypes.first;

  bool get _isQuark => widget.kind == SourceKind.quark;
  bool get _isCookieLogin => _isQuark && _quarkMethod == 1;

  void _onLoggedIn(ServerConfig server) {
    ref.read(serverListProvider.notifier).addServer(server);
    ref.read(currentServerProvider.notifier).state = server;
    ref.read(authStateProvider.notifier).state = AuthState.authenticated;
    if (mounted) context.go('/tv/home');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _nameController.dispose();
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_isCookieLogin) {
      if (_cookieController.text.trim().isEmpty) {
        setState(() => _error = '请粘贴 Cookie');
        return;
      }
    } else if (_urlController.text.trim().isEmpty) {
      setState(() => _error = '请填写服务器地址');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final server = await _login();
      if (mounted) _onLoggedIn(server);
    } on SourceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<dynamic> _login() {
    switch (widget.kind) {
      case SourceKind.openlist:
        return SourceLoginService.loginOpenList(
          name: _nameController.text,
          baseUrl: _urlController.text,
          username: _userController.text,
          password: _passController.text,
        );
      case SourceKind.anirss:
        return SourceLoginService.loginAniRss(
          name: _nameController.text,
          baseUrl: _urlController.text,
          username: _userController.text,
          password: _passController.text,
        );
      case SourceKind.quark:
        return SourceLoginService.loginQuarkCookie(
          name: _nameController.text,
          cookie: _cookieController.text,
        );
      default:
        throw SourceException('该源暂未支持登录');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final d = _descriptor;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: m.s(720)),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(m.spacingXxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '添加 ${d.name}',
                  style: TextStyle(
                    fontSize: m.fontSizeXxl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: m.spacingSm),
                Text(
                  d.subtitle,
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
                SizedBox(height: m.spacingXl),
                _field(
                  m: m,
                  label: '备注名称（可选）',
                  controller: _nameController,
                ),
                SizedBox(height: m.spacingLg),
                if (_isQuark) ...[
                  _quarkMethodToggle(m),
                  SizedBox(height: m.spacingLg),
                  if (_quarkMethod == 0)
                    Center(
                      child: QuarkQrLoginView(
                        currentName: () => _nameController.text,
                        onSuccess: _onLoggedIn,
                      ),
                    )
                  else
                    _field(
                      m: m,
                      label: 'Cookie',
                      controller: _cookieController,
                      hint: '__pus=...; __puus=...; ...',
                      autofocus: true,
                      maxLines: 4,
                    ),
                ] else ...[
                  _field(
                    m: m,
                    label: '服务器地址',
                    controller: _urlController,
                    hint: 'https://example.com:5244',
                    autofocus: true,
                    keyboardType: TextInputType.url,
                  ),
                  SizedBox(height: m.spacingLg),
                  _field(m: m, label: '用户名', controller: _userController),
                  SizedBox(height: m.spacingLg),
                  _field(
                    m: m,
                    label: '密码',
                    controller: _passController,
                    obscure: true,
                  ),
                ],
                if (_error != null) ...[
                  SizedBox(height: m.spacingLg),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: TvDesignTokens.error,
                    ),
                  ).animate().shake(duration: 400.ms),
                ],
                SizedBox(height: m.spacingXl),
                Row(
                  children: [
                    // 扫码方式无需「连接」按钮（扫码确认后自动完成）。
                    if (!(_isQuark && _quarkMethod == 0)) ...[
                      if (_loading)
                        Padding(
                          padding: EdgeInsets.only(right: m.spacingLg),
                          child: SizedBox(
                            width: m.s(28),
                            height: m.s(28),
                            child: const CircularProgressIndicator(
                              color: TvDesignTokens.brand,
                              strokeWidth: 3,
                            ),
                          ),
                        ),
                      TvButton(
                        text: _loading ? '连接中…' : '登录并添加',
                        icon: Icons.link,
                        onPressed: _loading ? null : _connect,
                      ),
                      SizedBox(width: m.spacingMd),
                    ],
                    TvFocusable(
                      padding: EdgeInsets.all(m.s(4)),
                      onSelect: () => Navigator.of(context).maybePop(),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: m.spacingLg,
                          vertical: m.spacingMd,
                        ),
                        decoration: BoxDecoration(
                          color: TvDesignTokens.surface,
                          borderRadius: BorderRadius.circular(m.posterRadius),
                        ),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            fontSize: m.fontSizeMd,
                            color: TvDesignTokens.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quarkMethodToggle(TvMetrics m) {
    Widget chip(int value, String label, IconData icon) {
      final selected = _quarkMethod == value;
      return TvFocusable(
        padding: EdgeInsets.all(m.s(4)),
        onSelect: () => setState(() {
          _quarkMethod = value;
          _error = null;
        }),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: m.spacingLg, vertical: m.spacingMd),
          decoration: BoxDecoration(
            color: selected
                ? TvDesignTokens.brand.withValues(alpha: 0.18)
                : TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
            border: selected
                ? Border.all(color: TvDesignTokens.brand, width: 2)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: m.s(22),
                  color: selected
                      ? TvDesignTokens.brand
                      : TvDesignTokens.textPrimary),
              SizedBox(width: m.spacingSm),
              Text(label,
                  style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: selected
                          ? TvDesignTokens.brand
                          : TvDesignTokens.textPrimary)),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(0, '扫码登录', Icons.qr_code),
        SizedBox(width: m.spacingMd),
        chip(1, 'Cookie', Icons.cookie_outlined),
      ],
    );
  }

  Widget _field({
    required TvMetrics m,
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    bool autofocus = false,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: m.fontSizeSm,
            color: TvDesignTokens.textSecondary,
          ),
        ),
        SizedBox(height: m.spacingXs),
        Focus(
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return Container(
                decoration: BoxDecoration(
                  color: TvDesignTokens.surface,
                  borderRadius: BorderRadius.circular(m.posterRadius),
                  border: Border.all(
                    color: focused
                        ? TvDesignTokens.brand
                        : TvDesignTokens.divider,
                    width: focused ? 3 : 1.5,
                  ),
                ),
                padding: EdgeInsets.symmetric(horizontal: m.spacingMd),
                child: TextField(
                  controller: controller,
                  autofocus: autofocus,
                  obscureText: obscure,
                  keyboardType: keyboardType,
                  maxLines: obscure ? 1 : maxLines,
                  style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: TvDesignTokens.textPrimary,
                  ),
                  cursorColor: TvDesignTokens.brand,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: hint,
                    hintStyle: TextStyle(
                      color: TvDesignTokens.textDisabled,
                      fontSize: m.fontSizeSm,
                    ),
                    contentPadding:
                        EdgeInsets.symmetric(vertical: m.spacingMd),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
