import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/danmaku/danmaku_service.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/server_batch_adder.dart';
import '../../../core/utils/server_batch_parser.dart';

/// 三端通用的「批量解析添加服务器」视图。
///
/// 用户把机场/Emby 分享出来的整段开通信息粘进来 → 解析出多个账号块(每块可有多条
/// 服务器线路 + 弹幕线路 + 用户名/密码) → 只需补一个用户名即可一键套用到所有块 →
/// 一键添加。服务器名称与图标自动从 Emby 获取，无需手填。
class BatchParseView extends ConsumerStatefulWidget {
  /// 至少成功添加一个服务器后回调（通常用于关闭页面/跳转首页）。
  final void Function(bool setCurrent)? onAdded;

  /// 是否把首个成功添加的服务器设为当前(登录态)。添加页登录流程传 true；
  /// 设置里「再加一个」可传 false。
  final bool setAsCurrent;

  const BatchParseView({
    super.key,
    this.onAdded,
    this.setAsCurrent = true,
  });

  @override
  ConsumerState<BatchParseView> createState() => _BatchParseViewState();
}

class _BlockEdit {
  final ParsedServerBlock block;
  final TextEditingController username;
  final TextEditingController password;
  String? status; // null=未处理；'ok'；错误信息
  bool adding = false;

  _BlockEdit(this.block)
      : username = TextEditingController(text: block.username ?? ''),
        password = TextEditingController(text: block.password ?? '');

  void dispose() {
    username.dispose();
    password.dispose();
  }
}

class _BatchParseViewState extends ConsumerState<BatchParseView> {
  final _pasteController = TextEditingController();
  final _applyUsernameController = TextEditingController();
  final List<_BlockEdit> _blocks = [];
  bool _isAdding = false;

  @override
  void dispose() {
    _pasteController.dispose();
    _applyUsernameController.dispose();
    for (final b in _blocks) {
      b.dispose();
    }
    super.dispose();
  }

  void _parse() {
    final blocks = ServerBatchParser.parse(_pasteController.text);
    for (final b in _blocks) {
      b.dispose();
    }
    _blocks
      ..clear()
      ..addAll(blocks.map(_BlockEdit.new));
    // 用第一个解析到的用户名预填「统一用户名」。
    final firstUser = blocks
        .map((b) => b.username)
        .firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null);
    if (firstUser != null) _applyUsernameController.text = firstUser;
    if (mounted) {
      setState(() {});
      if (blocks.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没解析到服务器线路，请检查粘贴内容')),
        );
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _pasteController.text = data.text!;
      _parse();
    }
  }

  void _applyUsernameToAll() {
    final u = _applyUsernameController.text.trim();
    if (u.isEmpty) return;
    for (final b in _blocks) {
      b.username.text = u;
    }
    setState(() {});
  }

  Future<void> _addAll() async {
    if (_blocks.isEmpty) return;
    setState(() => _isAdding = true);
    var addedCount = 0;
    var firstAdded = true;
    var danmakuCount = 0;

    for (final edit in _blocks) {
      if (edit.status == 'ok') continue; // 跳过已成功的
      final user = edit.username.text.trim();
      final pass = edit.password.text;
      if (user.isEmpty) {
        setState(() => edit.status = '请填写用户名');
        continue;
      }
      setState(() {
        edit.adding = true;
        edit.status = null;
      });
      try {
        final server = await ServerBatchAdder.authenticateBlock(
          edit.block,
          username: user,
          password: pass,
        );
        ref.read(serverListProvider.notifier).addServer(server);
        if (firstAdded && widget.setAsCurrent) {
          ref.read(currentServerProvider.notifier).state = server;
          ref.read(authStateProvider.notifier).state = AuthState.authenticated;
        }
        firstAdded = false;
        addedCount++;

        // 该账号的弹幕线路加入全局弹幕源。
        final danmaku = ServerBatchAdder.danmakuSourcesOf(
          edit.block,
          basePriority: ref.read(danmakuServiceProvider).sources.length,
        );
        for (final cfg in danmaku) {
          await ref.read(danmakuServiceProvider.notifier).addCustomSource(cfg);
          danmakuCount++;
        }
        setState(() => edit.status = 'ok');
      } catch (e) {
        setState(() => edit.status = _short(e));
      } finally {
        setState(() => edit.adding = false);
      }
    }

    setState(() => _isAdding = false);
    if (!mounted) return;
    if (addedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
            '已添加 $addedCount 个服务器${danmakuCount > 0 ? '、$danmakuCount 条弹幕线路' : ''}')),
      );
      widget.onAdded?.call(widget.setAsCurrent);
    }
  }

  String _short(Object e) {
    var s = e.toString().replaceAll('Exception: ', '');
    if (s.length > 120) s = '${s.substring(0, 120)}…';
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16).copyWith(bottom: 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _pasteController,
            decoration: InputDecoration(
              labelText: '粘贴开通信息 / 分享文本',
              hintText: '支持多服务器、多线路，自动识别用户名 / 密码 / 弹幕线路',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '从剪贴板粘贴',
                icon: const Icon(Icons.content_paste),
                onPressed: _pasteFromClipboard,
              ),
            ),
            maxLines: 8,
            minLines: 5,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _parse,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('解析'),
          ),
          if (_blocks.isNotEmpty) ...[
            const SizedBox(height: 20),
            // 一键套用用户名：账号名大概率一致，填一次套用到所有块。
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _applyUsernameController,
                    decoration: const InputDecoration(
                      labelText: '统一用户名',
                      isDense: true,
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _applyUsernameToAll,
                  child: const Text('套用全部'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...List.generate(_blocks.length, (i) => _buildBlockCard(theme, i)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isAdding ? null : _addAll,
              icon: _isAdding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_done_outlined),
              label: Text(_isAdding ? '正在添加…' : '添加全部'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBlockCard(ThemeData theme, int index) {
    final edit = _blocks[index];
    final b = edit.block;
    final statusOk = edit.status == 'ok';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  statusOk ? Icons.check_circle : Icons.dns_outlined,
                  size: 18,
                  color: statusOk ? Colors.green : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text('服务器 ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${b.lines.length} 线路'
                    '${b.danmakuLines.isNotEmpty ? ' · ${b.danmakuLines.length} 弹幕' : ''}',
                    style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: edit.username,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: edit.password,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...b.lines.map((l) => _lineRow(theme, Icons.link, l.name, l.url)),
            ...b.danmakuLines
                .map((l) => _lineRow(theme, Icons.comment_outlined, l.name, l.url)),
            if (edit.adding) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (edit.status != null && edit.status != 'ok') ...[
              const SizedBox(height: 8),
              Text(edit.status!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
            ],
            if (statusOk) ...[
              const SizedBox(height: 6),
              const Text('已添加',
                  style: TextStyle(color: Colors.green, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lineRow(ThemeData theme, IconData icon, String name, String url) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: theme.hintColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text('$name  $url',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
