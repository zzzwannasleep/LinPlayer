import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focusable.dart';

/// TV 添加服务器页 —— 真实连接 Emby（地址 + 账号 + 密码）。
/// TV 上聚焦输入框即唤起系统输入法（leanback IME）。
class TvAddServerScreen extends ConsumerStatefulWidget {
  const TvAddServerScreen({super.key});

  @override
  ConsumerState<TvAddServerScreen> createState() => _TvAddServerScreenState();
}

class _TvAddServerScreenState extends ConsumerState<TvAddServerScreen> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  String _normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Future<void> _connect() async {
    final url = _normalizeUrl(_urlController.text);
    final username = _userController.text.trim();
    final password = _passController.text;
    if (url.isEmpty) {
      setState(() => _error = '请填写服务器地址');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = EmbyApiClient(baseUrl: url);
      final auth = await client.auth.login(username: username, password: password);
      final info = await client.server.getSystemInfo();
      final server = ServerConfig(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: info.serverName,
        baseUrl: url,
        username: username,
        authToken: auth.accessToken,
        userId: auth.userId,
        password: password,
      );
      ref.read(serverListProvider.notifier).addServer(server);
      ref.read(currentServerProvider.notifier).state = server;
      ref.read(authStateProvider.notifier).state = AuthState.authenticated;
      ref.invalidate(librariesProvider);
      ref.invalidate(resumeItemsProvider);
      ref.invalidate(randomRecommendationsProvider);
      if (mounted) context.go('/tv/home');
    } catch (e) {
      if (mounted) {
        setState(() => _error = '连接失败：$e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
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
                  '添加服务器',
                  style: TextStyle(
                    fontSize: m.fontSizeXxl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: m.spacingSm),
                Text(
                  '连接你的 Emby 服务器',
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
                SizedBox(height: m.spacingXl),
                _field(
                  m: m,
                  label: '服务器地址',
                  controller: _urlController,
                  hint: 'http://192.168.1.100:8096',
                  autofocus: true,
                  keyboardType: TextInputType.url,
                ),
                SizedBox(height: m.spacingLg),
                _field(
                  m: m,
                  label: '用户名',
                  controller: _userController,
                  hint: '账号（留空可匿名登录）',
                ),
                SizedBox(height: m.spacingLg),
                _field(
                  m: m,
                  label: '密码',
                  controller: _passController,
                  hint: '密码（可留空）',
                  obscure: true,
                ),
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
                    if (_loading)
                      Padding(
                        padding:
                            EdgeInsets.only(right: m.spacingLg),
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
                      text: _loading ? '连接中…' : '连接',
                      icon: Icons.link,
                      onPressed: _loading ? null : _connect,
                    ),
                    SizedBox(width: m.spacingMd),
                    TvFocusable(
                      padding: EdgeInsets.all(m.s(4)),
                      onSelect: () => context.go('/tv/home'),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: m.spacingLg,
                          vertical: m.spacingMd,
                        ),
                        decoration: BoxDecoration(
                          color: TvDesignTokens.surface,
                          borderRadius: BorderRadius.circular(
                              m.posterRadius),
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

  Widget _field({
    required TvMetrics m,
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    bool autofocus = false,
    TextInputType? keyboardType,
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
                  borderRadius:
                      BorderRadius.circular(m.posterRadius),
                  border: Border.all(
                    color: focused
                        ? TvDesignTokens.brand
                        : TvDesignTokens.divider,
                    width: focused ? 3 : 1.5,
                  ),
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: m.spacingMd,
                ),
                child: TextField(
                  controller: controller,
                  autofocus: autofocus,
                  obscureText: obscure,
                  keyboardType: keyboardType,
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
                    contentPadding: EdgeInsets.symmetric(
                      vertical: m.spacingMd,
                    ),
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
