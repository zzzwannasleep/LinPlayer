import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../widgets/server/batch_parse_view.dart';

/// 添加服务器页面
class AddServerScreen extends ConsumerStatefulWidget {
  const AddServerScreen({super.key});
  
  @override
  ConsumerState<AddServerScreen> createState() => _AddServerScreenState();
}

class _AddServerScreenState extends ConsumerState<AddServerScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _urlController = TextEditingController();
  final _pathController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _importController = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    _urlController.dispose();
    _pathController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _importController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('添加服务器'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '手动输入'),
            Tab(text: '批量解析'),
            Tab(text: '导入配置'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildManualTab(),
          _buildBatchTab(),
          _buildImportTab(),
        ],
      ),
    );
  }
  
  Widget _buildManualTab() {
    // 使用固定的 bottom padding，让 SingleChildScrollView 自动处理键盘
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16).copyWith(
        bottom: 100,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://example.com',
              prefixIcon: Icon(Icons.link),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pathController,
            decoration: const InputDecoration(
              labelText: '路径',
              hintText: '/emby',
              prefixIcon: Icon(Icons.folder),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: '用户名',
              prefixIcon: Icon(Icons.person),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(
              labelText: '密码',
              prefixIcon: Icon(Icons.lock),
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
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
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _isLoading ? null : _addServer,
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('连接并保存'),
          ),
        ],
      ),
    );
  }
  
  Widget _buildBatchTab() {
    return BatchParseView(
      onAdded: (setCurrent) {
        if (!mounted) return;
        if (setCurrent) {
          context.pushReplacement('/home');
        } else {
          context.pop();
        }
      },
    );
  }

  Widget _buildImportTab() {
    // 使用固定的 bottom padding，让 SingleChildScrollView 自动处理键盘
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16).copyWith(
        bottom: 100,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '从剪贴板导入',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '支持格式：单个服务器JSON或服务器列表JSON数组',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _importController,
            decoration: const InputDecoration(
              labelText: '粘贴JSON配置',
              hintText: '[{"name": "服务器", "url": "https://..."}]',
              border: OutlineInputBorder(),
            ),
            maxLines: 10,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _importFromJson(context, ref, _importController.text),
            icon: const Icon(Icons.paste),
            label: const Text('解析并导入'),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              try {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['json', 'txt'],
                  allowMultiple: false,
                );
                
                if (result != null && result.files.isNotEmpty) {
                  final file = result.files.first;
                  if (file.path != null) {
                    final content = await File(file.path!).readAsString();
                    if (mounted) {
                      _importFromJson(context, ref, content);
                    }
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('读取文件失败: $e')),
                  );
                }
              }
            },
            icon: const Icon(Icons.folder_open),
            label: const Text('从文件选择'),
          ),
        ],
      ),
    );
  }
  
  void _importFromJson(BuildContext context, WidgetRef ref, String jsonText) {
    if (jsonText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入JSON配置')),
      );
      return;
    }
    
    try {
      // 简单解析：尝试提取URL和名称
      final urlRegex = RegExp(r'["]url["]\s*:\s*["](https?://[^"]+)["]');
      final nameRegex = RegExp(r'["]name["]\s*:\s*["]([^"]+)["]');
      
      final urls = urlRegex.allMatches(jsonText).map((m) => m.group(1)!).toList();
      final names = nameRegex.allMatches(jsonText).map((m) => m.group(1)!).toList();
      
      if (urls.isEmpty) {
        throw Exception('未找到有效的服务器URL');
      }
      
      // 创建服务器配置
      for (var i = 0; i < urls.length; i++) {
        final url = urls[i];
        final name = i < names.length ? names[i] : '导入服务器 ${i + 1}';
        
        final server = ServerConfig(
          id: '${DateTime.now().millisecondsSinceEpoch}_$i',
          name: name,
          baseUrl: url,
          lines: [ServerLine(
            id: 'default',
            name: '默认线路',
            url: url,
          )],
        );
        
        ref.read(serverListProvider.notifier).addServer(server);
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('成功导入 ${urls.length} 个服务器')),
      );
      
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }
  
  Future<void> _addServer() async {
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
        // 避免重复拼接：去掉 URL 尾部斜杠后检查是否已包含该路径
        final urlWithoutSlash = fullUrl.endsWith('/') ? fullUrl.substring(0, fullUrl.length - 1) : fullUrl;
        if (urlWithoutSlash.endsWith(cleanPath) != true) {
          fullUrl = '$urlWithoutSlash$cleanPath';
        }
      }

      final client = EmbyApiClient(baseUrl: fullUrl);
      
      final serverInfo = await client.server.getPublicInfo(fullUrl);
      
      if (username.isNotEmpty) {
        final authResult = await client.auth.login(username: username, password: password);
        
        final server = ServerConfig(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: serverInfo.serverName,
          baseUrl: fullUrl,
          lines: [ServerLine(
            id: 'default',
            name: '默认线路',
            url: fullUrl,
          )],
          username: username,
          authToken: authResult.accessToken,
          userId: authResult.userId,
          password: password,
        );
        
        ref.read(serverListProvider.notifier).addServer(server);
        ref.read(currentServerProvider.notifier).state = server;
        ref.read(authStateProvider.notifier).state = AuthState.authenticated;

        if (!mounted) return;
        context.pushReplacement('/home');
      } else {
        final server = ServerConfig(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: serverInfo.serverName,
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
      setState(() {
        _errorMessage = _formatError(e);
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  /// 规范化服务器URL
  /// 1. 如果没有协议前缀，默认添加 https://
  /// 2. 如果没有显式端口号：
  ///    - http:// 自动追加 :80
  ///    - https:// 自动追加 :443
  String _normalizeUrl(String url) {
    var normalized = url.trim();

    // 1. 添加协议前缀（如果没有的话）
    if (!normalized.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      normalized = 'https://$normalized';
    }

    // 2. 检查是否有显式端口号（域名后的:数字）
    final portInUrl = RegExp(r':(\d+)(?:/|$)').firstMatch(normalized);
    if (portInUrl == null) {
      // 没有显式端口，需要添加默认端口
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

    // DNS / 域名解析错误
    if (msg.contains('failed host lookup') ||
        msg.contains('no address associated with hostname') ||
        msg.contains('name or service not known') ||
        msg.contains('errno = 7')) {
      return '无法解析服务器地址，请检查：\n1. 域名是否拼写正确\n2. 当前网络是否能访问该域名\n3. 是否需要使用 http 而非 https';
    }

    if (msg.contains('400')) {
      return '服务器返回 400 错误，可能原因：\n1. URL 路径重复（如 /emby/emby）\n2. 服务器不是 Emby/Jellyfin\n3. 需要修改路径（尝试将路径改为 / 或其他）\n\n请检查浏览器中能访问的完整地址，确保和输入一致';
    }
    if (msg.contains('401')) return '认证失败：用户名或密码错误';
    if (msg.contains('403')) return '访问被拒绝';
    if (msg.contains('404')) return '服务器接口不存在，请检查 URL 和路径是否正确';
    if (msg.contains('502')) return '服务器网关错误';
    if (msg.contains('connection') || msg.contains('timeout') || msg.contains('refused')) {
      return '网络连接失败，请检查：\n1. 服务器地址和端口是否正确\n2. 当前网络是否能访问该服务器';
    }

    return e.toString().replaceAll('Exception: ', '');
  }
}
