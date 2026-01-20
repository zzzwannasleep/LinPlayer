import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/server_share_text_parser.dart';
import 'state/app_state.dart';

class ServerTextImportSheet extends StatefulWidget {
  const ServerTextImportSheet({super.key, required this.appState});

  final AppState appState;

  @override
  State<ServerTextImportSheet> createState() => _ServerTextImportSheetState();
}

class _ServerTextImportSheetState extends State<ServerTextImportSheet> {
  final _rawCtrl = TextEditingController();
  final _rawFocus = FocusNode();

  List<_ImportGroupDraft> _groups = [];
  bool _importing = false;

  @override
  void dispose() {
    _disposeGroups();
    _rawCtrl.dispose();
    _rawFocus.dispose();
    super.dispose();
  }

  void _disposeGroups() {
    for (final g in _groups) {
      g.usernameCtrl.dispose();
      g.passwordCtrl.dispose();
    }
    _groups = [];
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('剪贴板没有文本')),
      );
      return;
    }
    _rawCtrl.text = text;
    _parse();
  }

  void _parse() {
    _rawFocus.unfocus();

    final parsed = ServerShareTextParser.parse(_rawCtrl.text);

    _disposeGroups();
    final drafts = <_ImportGroupDraft>[];

    final defaultUsername = widget.appState.activeServer?.username.trim() ?? '';
    for (final g in parsed) {
      if (g.lines.isEmpty) continue;
      final lineDrafts = g.lines
          .map(
            (l) => _ImportLineDraft(
              name: l.name,
              url: l.url,
              selected: l.selectedByDefault,
            ),
          )
          .toList();

      String primaryUrl = lineDrafts.first.url;
      for (final l in lineDrafts) {
        if (l.selected) {
          primaryUrl = l.url;
          break;
        }
      }

      drafts.add(
        _ImportGroupDraft(
          selected: true,
          usernameCtrl: TextEditingController(text: defaultUsername),
          passwordCtrl: TextEditingController(text: g.password),
          lines: lineDrafts,
          primaryUrl: primaryUrl,
        ),
      );
    }

    setState(() => _groups = drafts);

    if (drafts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未解析到服务器地址')),
      );
    }
  }

  void _clear() {
    _rawCtrl.clear();
    _disposeGroups();
    setState(() {});
  }

  Future<void> _importSelected() async {
    if (_importing) return;

    final selectedGroups = _groups.where((g) => g.selected).toList();
    if (selectedGroups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要导入的服务器')),
      );
      return;
    }

    for (final g in selectedGroups) {
      if (g.usernameCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请为每个服务器填写账号')),
        );
        return;
      }
      if (g.lines.where((l) => l.selected).isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('每个服务器至少选择一个线路地址')),
        );
        return;
      }
    }

    setState(() => _importing = true);

    final results = <String>[];
    var success = 0;

    String progressText = '';
    var started = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialogState) {
          if (!started) {
            started = true;
            unawaited(() async {
              for (var i = 0; i < selectedGroups.length; i++) {
                final g = selectedGroups[i];
                final lines = g.lines.where((l) => l.selected).toList();
                final display = g.displayName;
                final primaryUrl = lines.any((l) => l.url == g.primaryUrl)
                    ? g.primaryUrl
                    : lines.first.url;
                g.primaryUrl = primaryUrl;

                setDialogState(() {
                  progressText =
                      '正在导入 ${i + 1}/${selectedGroups.length}：$display';
                });

                final uri = Uri.tryParse(primaryUrl);
                final scheme =
                    (uri?.scheme.toLowerCase() == 'http') ? 'http' : 'https';

                await widget.appState.addServer(
                  hostOrUrl: primaryUrl,
                  scheme: scheme,
                  port: null,
                  username: g.usernameCtrl.text.trim(),
                  password: g.passwordCtrl.text,
                  displayName: null,
                  remark: null,
                  iconUrl: null,
                );

                final err = widget.appState.error;
                if (err != null) {
                  results.add('失败 $display：$err');
                  continue;
                }
                success++;
                results.add('成功 $display');

                for (final l in lines) {
                  if (l.url == primaryUrl) continue;
                  try {
                    await widget.appState
                        .addCustomDomain(name: l.name, url: l.url);
                  } catch (e) {
                    results.add('警告 $display：添加线路失败（${l.url}）$e');
                  }
                }
              }

              if (dctx.mounted) Navigator.of(dctx).pop();
            }());
          }

          return WillPopScope(
            onWillPop: () async => false,
            child: AlertDialog(
              title: const Text('正在批量导入'),
              content: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(progressText.isEmpty ? '准备中…' : progressText),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (!mounted) return;
    setState(() => _importing = false);

    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('导入结果'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              '成功：$success/${selectedGroups.length}\n\n${results.join('\n')}',
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (success > 0 && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding:
          EdgeInsets.only(left: 16, right: 16, bottom: viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '从文本导入服务器',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _importing ? null : _pasteFromClipboard,
                      icon: const Icon(Icons.content_paste_outlined),
                      label: const Text('粘贴'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _importing ? null : _parse,
                      icon: const Icon(Icons.auto_fix_high_outlined),
                      label: const Text('解析'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _rawCtrl,
                  focusNode: _rawFocus,
                  maxLines: 7,
                  decoration: const InputDecoration(
                    labelText: '导入信息',
                    hintText: '粘贴“目前线路 & 用户密码…”等内容，然后点“解析”。',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (_groups.isEmpty)
                  Text(
                    '解析后会在这里显示服务器列表。'
                    '\n\n提示：只会默认勾选更像“服务器线路”的地址，其他链接（如客户端/探针）会默认不勾选。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  )
                else ...[
                  Text(
                    '已解析到 ${_groups.length} 个服务器：',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ..._groups.asMap().entries.map(
                        (entry) => Padding(
                          padding: EdgeInsets.only(
                            bottom: entry.key == _groups.length - 1 ? 0 : 10,
                          ),
                          child: _GroupCard(
                            index: entry.key,
                            group: entry.value,
                            onChanged: () => setState(() {}),
                          ),
                        ),
                      ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _importing ? null : _clear,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清空'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _importing ? null : _importSelected,
                  icon: const Icon(Icons.playlist_add_outlined),
                  label: const Text('导入选中'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({
    required this.index,
    required this.group,
    required this.onChanged,
  });

  final int index;
  final _ImportGroupDraft group;
  final VoidCallback onChanged;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final total = g.lines.length;
    final selected = g.lines.where((l) => l.selected).length;
    final pwdHint = g.passwordCtrl.text.trim().isEmpty ? '未识别密码' : '已识别密码';

    final effectivePrimary = g.lines.any((l) => l.url == g.primaryUrl)
        ? g.primaryUrl
        : g.lines.first.url;
    g.primaryUrl = effectivePrimary;

    final selectedLines = g.lines.where((l) => l.selected).toList();
    final canPickPrimary = selectedLines.isNotEmpty;
    final currentPrimary = canPickPrimary
        ? (selectedLines.any((l) => l.url == g.primaryUrl)
            ? g.primaryUrl
            : selectedLines.first.url)
        : null;
    if (currentPrimary != null && currentPrimary != g.primaryUrl) {
      g.primaryUrl = currentPrimary;
    }

    String labelForUrl(String url) {
      final line = g.lines.firstWhere((l) => l.url == url,
          orElse: () => _ImportLineDraft(name: url, url: url, selected: true));
      return line.name.trim().isEmpty ? line.url : line.name.trim();
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Checkbox(
            value: g.selected,
            onChanged: (v) {
              g.selected = v ?? false;
              widget.onChanged();
            },
          ),
          title: Text(g.displayName),
          subtitle: Text('线路：$selected/$total · $pwdHint'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            TextField(
              controller: g.usernameCtrl,
              decoration: const InputDecoration(
                labelText: '账号',
                hintText: '每个服务器需要填写自己的账号',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: g.passwordCtrl,
              obscureText: !g.passwordVisible,
              decoration: InputDecoration(
                labelText: '密码',
                suffixIcon: IconButton(
                  tooltip: g.passwordVisible ? '隐藏' : '显示',
                  icon: Icon(g.passwordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () {
                    setState(() => g.passwordVisible = !g.passwordVisible);
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('登录线路'),
              subtitle: Text(
                canPickPrimary ? labelForUrl(currentPrimary!) : '请至少选择一个线路地址',
              ),
              trailing: canPickPrimary
                  ? DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: currentPrimary!,
                        items: selectedLines
                            .map(
                              (l) => DropdownMenuItem(
                                value: l.url,
                                child: SizedBox(
                                  width: 180,
                                  child: Text(
                                    l.name.trim().isEmpty ? l.url : l.name.trim(),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          g.primaryUrl = v;
                          widget.onChanged();
                        },
                      ),
                    )
                  : const Text('—'),
            ),
            const SizedBox(height: 6),
            Text(
              '线路地址（导入后会自动作为“自定义线路”添加到该服务器）：',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 6),
            ...g.lines.map(
              (l) => CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: l.selected,
                onChanged: (v) {
                  l.selected = v ?? false;
                  if (l.selected && g.primaryUrl.trim().isEmpty) {
                    g.primaryUrl = l.url;
                  }
                  widget.onChanged();
                },
                title: Text(l.name.trim().isEmpty ? l.url : l.name.trim()),
                subtitle: Text(l.url),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportGroupDraft {
  bool selected;
  final TextEditingController usernameCtrl;
  final TextEditingController passwordCtrl;
  final List<_ImportLineDraft> lines;
  String primaryUrl;
  bool passwordVisible = false;

  _ImportGroupDraft({
    required this.selected,
    required this.usernameCtrl,
    required this.passwordCtrl,
    required this.lines,
    required this.primaryUrl,
  });

  String get displayName {
    final uri = Uri.tryParse(primaryUrl);
    final host = uri?.host.trim();
    if (host != null && host.isNotEmpty) return host;
    return '服务器';
  }
}

class _ImportLineDraft {
  final String name;
  final String url;
  bool selected;

  _ImportLineDraft({
    required this.name,
    required this.url,
    required this.selected,
  });
}
