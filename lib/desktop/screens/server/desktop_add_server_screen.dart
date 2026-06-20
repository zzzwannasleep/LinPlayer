import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../../ui/widgets/server/batch_parse_view.dart';

/// 桌面端添加服务器页
class DesktopAddServerScreen extends ConsumerStatefulWidget {
  const DesktopAddServerScreen({super.key});
  
  @override
  ConsumerState<DesktopAddServerScreen> createState() => _DesktopAddServerScreenState();
}

class _DesktopAddServerScreenState extends ConsumerState<DesktopAddServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _pathController = TextEditingController(text: '/emby');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  
  @override
  void dispose() {
    _urlController.dispose();
    _pathController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('添加服务器'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.pop(),
        ),
        actions: [
          TextButton.icon(
            onPressed: _openBatchParse,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('批量解析'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 服务器地址
                  _buildTextField(
                    controller: _urlController,
                    label: '服务器地址',
                    hint: 'https://example.com 或 IP:端口',
                    prefixIcon: Icons.link,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '服务器地址不能为空';
                      }
                      return null;
                    },
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 路径
                  _buildTextField(
                    controller: _pathController,
                    label: '路径（可选）',
                    hint: '/emby',
                    prefixIcon: Icons.folder,
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 服务器名称
                  _buildTextField(
                    controller: _nameController,
                    label: '服务器名称（可选）',
                    hint: '我的服务器',
                    prefixIcon: Icons.edit,
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // 分隔线
                  const Divider(),
                  
                  const SizedBox(height: 24),
                  
                  // 用户名
                  _buildTextField(
                    controller: _usernameController,
                    label: '用户名',
                    hint: '输入用户名',
                    prefixIcon: Icons.person,
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 密码
                  _buildTextField(
                    controller: _passwordController,
                    label: '密码',
                    hint: '输入密码',
                    prefixIcon: Icons.lock,
                    obscureText: _obscurePassword,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off : Icons.visibility,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                  
                  const SizedBox(height: 32),
                  
                  // 连接按钮
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: _isLoading ? null : _connectServer,
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              '连接并保存',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData prefixIcon,
    bool obscureText = false,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(prefixIcon, size: 20),
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF5B8DEF), width: 2),
        ),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surface,
      ),
    );
  }
  
  void _openBatchParse() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('批量解析添加')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: BatchParseView(
              onAdded: (setCurrent) {
                if (!mounted) return;
                if (setCurrent) {
                  context.go('/');
                } else {
                  Navigator.of(context).pop();
                }
              },
            ),
          ),
        ),
      ),
    ));
  }

  Future<void> _connectServer() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    
    try {
      final url = _urlController.text.trim();
      final path = _pathController.text.trim();
      final username = _usernameController.text.trim();
      final password = _passwordController.text;
      
      if (url.isEmpty) {
        throw Exception('服务器地址不能为空');
      }
      
      var fullUrl = _normalizeUrl(url);

      if (path.isNotEmpty && path != '/') {
        final cleanPath = path.startsWith('/') ? path : '/$path';
        final urlWithoutSlash = fullUrl.endsWith('/') ? fullUrl.substring(0, fullUrl.length - 1) : fullUrl;
        if (!urlWithoutSlash.endsWith(cleanPath)) {
          fullUrl = '$urlWithoutSlash$cleanPath';
        }
      }

      final client = EmbyApiClient(baseUrl: fullUrl);
      
      final serverInfo = await client.server.getPublicInfo(fullUrl);
      
      if (username.isNotEmpty) {
        final authResult = await client.auth.login(username: username, password: password);
        
        // 验证认证结果
        if (authResult.userId.isEmpty) {
          throw Exception('认证失败：服务器返回的用户ID为空');
        }
        if (authResult.accessToken.isEmpty) {
          throw Exception('认证失败：服务器返回的访问令牌为空');
        }
        
        final name = _nameController.text.trim().isNotEmpty
            ? _nameController.text.trim()
            : serverInfo.serverName;
        
        debugPrint('[AddServer] Auth success - userId: ${authResult.userId}, tokenLength: ${authResult.accessToken.length}');
        
        final server = ServerConfig(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          baseUrl: fullUrl,
          lines: [ServerLine(
            id: 'default',
            name: '默认线路',
            url: fullUrl,
          )],
          username: username,
          authToken: authResult.accessToken,
          userId: authResult.userId,
        );
        
        debugPrint('[AddServer] Saving server - id: ${server.id}, authToken: ${server.authToken != null ? 'present' : 'null'}, userId: ${server.userId}');
        
        ref.read(serverListProvider.notifier).addServer(server);
        ref.read(currentServerProvider.notifier).state = server;
        ref.read(authStateProvider.notifier).state = AuthState.authenticated;
        
        if (!mounted) return;
        context.go('/');
      } else {
        final name = _nameController.text.trim().isNotEmpty
            ? _nameController.text.trim()
            : serverInfo.serverName;
        
        final server = ServerConfig(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name,
          baseUrl: fullUrl,
          lines: [ServerLine(
            id: 'default',
            name: '默认线路',
            url: fullUrl,
          )],
        );
        
        ref.read(serverListProvider.notifier).addServer(server);
        
        if (!mounted) return;
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = _formatError(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
  
  /// 规范化服务器URL
  String _normalizeUrl(String url) {
    var normalized = url.trim();

    if (!normalized.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      normalized = 'https://$normalized';
    }

    final portInUrl = RegExp(r':(\d+)(?:/|$)').firstMatch(normalized);
    if (portInUrl == null) {
      final scheme = normalized.startsWith('https://') ? 'https' : 'http';
      final hostMatch = RegExp(r'https?://([^/:]+)').firstMatch(normalized);
      if (hostMatch != null) {
        final host = hostMatch.group(1)!;
        final defaultPort = scheme == 'https' ? '443' : '80';
        final pathStart = normalized.indexOf('/', scheme.length + 3);
        final path = pathStart != -1 ? normalized.substring(pathStart) : '';
        normalized = '$scheme://$host:$defaultPort$path';
      }
    }

    return normalized;
  }

  String _formatError(dynamic e) {
    final msg = e.toString().toLowerCase();

    if (msg.contains('failed host lookup') ||
        msg.contains('no address associated with hostname') ||
        msg.contains('name or service not known') ||
        msg.contains('errno = 7')) {
      return '无法解析服务器地址，请检查域名或网络连接';
    }

    if (msg.contains('400')) {
      return '服务器返回 400 错误，请检查 URL 路径是否正确';
    }
    if (msg.contains('401')) return '认证失败：用户名或密码错误';
    if (msg.contains('403')) return '访问被拒绝';
    if (msg.contains('404')) return '服务器接口不存在，请检查 URL 和路径';
    if (msg.contains('502')) return '服务器网关错误';
    if (msg.contains('connection') || msg.contains('timeout') || msg.contains('refused')) {
      return '网络连接失败，请检查服务器地址和端口';
    }

    return e.toString().replaceAll('Exception: ', '');
  }
}
