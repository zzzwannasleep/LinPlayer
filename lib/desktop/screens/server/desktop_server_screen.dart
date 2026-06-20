import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/api/emby_api.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../utils/desktop_smooth_scroll.dart';

enum _ServerContextAction { rename, lines, icon, login }

/// 桌面端服务器管理页
class DesktopServerScreen extends ConsumerStatefulWidget {
  const DesktopServerScreen({super.key});

  @override
  ConsumerState<DesktopServerScreen> createState() =>
      _DesktopServerScreenState();
}

class _DesktopServerScreenState extends ConsumerState<DesktopServerScreen> {
  bool _isGridView = true;

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final currentServer = ref.watch(currentServerProvider);

    return Scaffold(
      body: DesktopSmoothScrollBuilder(
        builder: (context, controller) => CustomScrollView(
          controller: controller,
          slivers: [
            // 顶部栏
            SliverToBoxAdapter(
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: Row(
                  children: [
                    const Text(
                      '服务器管理',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),

                    // 添加服务器按钮
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => context.push('/add-server'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF5B8DEF),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add, color: Colors.white, size: 18),
                              SizedBox(width: 6),
                              Text(
                                '添加服务器',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // 视图切换
                    IconButton(
                      icon:
                          Icon(_isGridView ? Icons.view_list : Icons.grid_view),
                      onPressed: () =>
                          setState(() => _isGridView = !_isGridView),
                      tooltip: _isGridView ? '列表视图' : '网格视图',
                    ),
                  ],
                ),
              ),
            ),

            // 服务器列表
            if (servers.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.dns_outlined,
                          size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text(
                        '暂无服务器',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      const SizedBox(height: 24),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => context.push('/add-server'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF5B8DEF),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add, color: Colors.white, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  '添加服务器',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (_isGridView)
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    childAspectRatio: 2.95,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 10,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final server = servers[index];
                      final isCurrent = server.id == currentServer?.id;
                      return _ServerGridCard(
                        server: server,
                        isCurrent: isCurrent,
                        onTap: () => _selectServer(server),
                        onSecondaryTapDown: (details) =>
                            _showContextMenu(server, details.globalPosition),
                      );
                    },
                    childCount: servers.length,
                  ),
                ),
              )
            else
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final server = servers[index];
                      final isCurrent = server.id == currentServer?.id;
                      return _ServerListTile(
                        server: server,
                        isCurrent: isCurrent,
                        onTap: () => _selectServer(server),
                        onSecondaryTapDown: (details) =>
                            _showContextMenu(server, details.globalPosition),
                      );
                    },
                    childCount: servers.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _selectServer(ServerConfig server) {
    debugPrint(
        '[SelectServer] Selecting ${server.name}: authToken=${server.authToken != null ? 'present' : 'null'}, userId=${server.userId}');
    ref.read(currentServerProvider.notifier).state = server;
    if (serverHasUsableAuth(server)) {
      ref.read(authStateProvider.notifier).state = AuthState.authenticated;
    } else {
      ref.read(authStateProvider.notifier).state = AuthState.unauthenticated;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${server.name} 未认证，部分功能可能无法使用'),
            action: SnackBarAction(
              label: '登录',
              onPressed: () {
                _showReauthDialog(server);
              },
            ),
          ),
        );
      }
    }
    ref.invalidate(librariesProvider);
    ref.invalidate(resumeItemsProvider);
  }

  void _showReauthDialog(ServerConfig server) {
    showDialog(
      context: context,
      builder: (context) => _ReauthDialog(server: server),
    );
  }

  Future<void> _showContextMenu(ServerConfig server, Offset position) async {
    final result = await showMenu<_ServerContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          value: _ServerContextAction.rename,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('编辑服务器名称'),
          ),
        ),
        const PopupMenuItem(
          value: _ServerContextAction.lines,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.route_outlined),
            title: Text('管理线路'),
          ),
        ),
        const PopupMenuItem(
          value: _ServerContextAction.icon,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.image_outlined),
            title: Text('更换图标'),
          ),
        ),
        const PopupMenuItem(
          value: _ServerContextAction.login,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.login_outlined),
            title: Text('重新登录'),
          ),
        ),
      ],
    );

    if (!mounted || result == null) return;

    switch (result) {
      case _ServerContextAction.rename:
        context.push('/edit-server/${server.id}');
        break;
      case _ServerContextAction.lines:
        context.push('/server-lines/${server.id}');
        break;
      case _ServerContextAction.icon:
        context.push('/server-icons/${server.id}');
        break;
      case _ServerContextAction.login:
        _showReauthDialog(server);
        break;
    }
  }
}

/// 服务器网格卡片
class _ServerGridCard extends StatefulWidget {
  final ServerConfig server;
  final bool isCurrent;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails>? onSecondaryTapDown;

  const _ServerGridCard({
    required this.server,
    required this.isCurrent,
    required this.onTap,
    this.onSecondaryTapDown,
  });

  @override
  State<_ServerGridCard> createState() => _ServerGridCardState();
}

class _ServerGridCardState extends State<_ServerGridCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.96,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: Curves.fastOutSlowIn,
    ));
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _scaleController.forward();
  }

  void _onTapUp(TapUpDetails details) {
    _scaleController.reverse();
  }

  void _onTapCancel() {
    _scaleController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: AnimatedBuilder(
          animation: _scaleController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: child,
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.fastOutSlowIn,
            decoration: BoxDecoration(
              color: widget.isCurrent
                  ? const Color(0xFF5B8DEF).withValues(alpha: 0.08)
                  : _isHovered
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: widget.isCurrent
                  ? Border.all(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.5),
                      width: 2,
                    )
                  : _isHovered
                      ? Border.all(
                          color:
                              theme.colorScheme.primary.withValues(alpha: 0.2),
                          width: 1,
                        )
                      : null,
              boxShadow: widget.isCurrent
                  ? [
                      BoxShadow(
                        color: const Color(0xFF5B8DEF).withValues(alpha: 0.15),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : _isHovered
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  // 服务器图标
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: widget.isCurrent
                          ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
                          : const Color(0xFF5B8DEF).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: widget.server.iconUrl != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: MediaImage(
                              imageUrl: widget.server.iconUrl,
                              width: 34,
                              height: 34,
                              fit: BoxFit.cover,
                              useDefaultUserAgent: true,
                            ),
                          )
                        : Icon(
                            Icons.dns,
                            size: 18,
                            color: widget.isCurrent
                                ? const Color(0xFF5B8DEF)
                                : const Color(0xFF5B8DEF)
                                    .withValues(alpha: 0.7),
                          ),
                  ),

                  const SizedBox(width: 12),

                  // 服务器信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.server.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: widget.isCurrent
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: widget.isCurrent
                                ? const Color(0xFF5B8DEF)
                                : theme.colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _serverPrivacySummary(widget.server),
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.textTheme.bodySmall?.color,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),

                  // 当前选中标记 / 未认证标记
                  if (widget.isCurrent)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5B8DEF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 12,
                            color: Color(0xFF5B8DEF),
                          ),
                          SizedBox(width: 4),
                          Text(
                            '当前',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF5B8DEF),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (!serverHasUsableAuth(widget.server))
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 12,
                            color: Colors.orange.shade700,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '未认证',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Colors.orange.shade700,
                            ),
                          ),
                        ],
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
}

/// 服务器列表项
class _ServerListTile extends StatefulWidget {
  final ServerConfig server;
  final bool isCurrent;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails>? onSecondaryTapDown;

  const _ServerListTile({
    required this.server,
    required this.isCurrent,
    required this.onTap,
    this.onSecondaryTapDown,
  });

  @override
  State<_ServerListTile> createState() => _ServerListTileState();
}

class _ServerListTileState extends State<_ServerListTile>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.98,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: Curves.fastOutSlowIn,
    ));
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    _scaleController.forward();
  }

  void _onTapUp(TapUpDetails details) {
    _scaleController.reverse();
  }

  void _onTapCancel() {
    _scaleController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: AnimatedBuilder(
          animation: _scaleController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: child,
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.fastOutSlowIn,
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: widget.isCurrent
                  ? const Color(0xFF5B8DEF).withValues(alpha: 0.08)
                  : _isHovered
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: widget.isCurrent
                  ? Border.all(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.4),
                      width: 1.5,
                    )
                  : null,
            ),
            child: Row(
              children: [
                // 图标
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: widget.isCurrent
                        ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
                        : const Color(0xFF5B8DEF).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: widget.server.iconUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: MediaImage(
                            imageUrl: widget.server.iconUrl,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                            useDefaultUserAgent: true,
                          ),
                        )
                      : Icon(
                          Icons.dns,
                          size: 18,
                          color: widget.isCurrent
                              ? const Color(0xFF5B8DEF)
                              : const Color(0xFF5B8DEF).withValues(alpha: 0.7),
                        ),
                ),

                const SizedBox(width: 12),

                // 信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.server.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: widget.isCurrent
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: widget.isCurrent
                              ? const Color(0xFF5B8DEF)
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        _serverPrivacySummary(widget.server),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ),
                ),

                // 当前标记 / 未认证标记
                if (widget.isCurrent)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 12,
                          color: Color(0xFF5B8DEF),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '当前',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5B8DEF),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (!serverHasUsableAuth(widget.server))
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 12,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '未认证',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _serverPrivacySummary(ServerConfig server) {
  final lineCount = server.lines.length;
  final remark = server.remark?.trim();
  final summary = <String>[
    if (lineCount > 0) '$lineCount 条线路',
    if (remark != null && remark.isNotEmpty) remark,
  ];

  if (summary.isEmpty) {
    return serverHasUsableAuth(server) ? '已配置服务器' : '需要重新登录';
  }

  return summary.join(' · ');
}

/// 重新认证对话框
class _ReauthDialog extends ConsumerStatefulWidget {
  final ServerConfig server;

  const _ReauthDialog({required this.server});

  @override
  ConsumerState<_ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends ConsumerState<_ReauthDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _usernameController.text = widget.server.username?.trim() ?? '';
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('登录到 ${widget.server.name}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: '用户名',
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: '密码',
                prefixIcon: const Icon(Icons.lock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _authenticate,
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ],
    );
  }

  Future<void> _authenticate() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty) {
      setState(() => _errorMessage = '请输入用户名');
      return;
    }

    if (password.isEmpty) {
      setState(() => _errorMessage = '请输入密码');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final client = EmbyApiClient(
        baseUrl: widget.server.activeLineUrl,
      );

      final authResult = await client.auth.login(
        username: username,
        password: password,
      );

      if (authResult.userId.isEmpty || authResult.accessToken.isEmpty) {
        throw Exception('认证失败：服务器返回的数据不完整');
      }

      final updatedServer = widget.server.copyWith(
        username: username,
        authToken: authResult.accessToken,
        userId: authResult.userId,
      );

      ref.read(serverListProvider.notifier).updateServer(updatedServer);
      ref.read(currentServerProvider.notifier).state = updatedServer;
      ref.read(authStateProvider.notifier).state = AuthState.authenticated;

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.server.name} 认证成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}
