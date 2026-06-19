part of 'settings_screen.dart';

class DanmakuSettingsScreen extends ConsumerWidget {
  const DanmakuSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(danmakuEnabledProvider);
    final opacity = ref.watch(danmakuOpacityProvider);
    final fontSize = ref.watch(danmakuFontSizeProvider);
    final speed = ref.watch(danmakuSpeedProvider);
    final density = ref.watch(danmakuDensityProvider);
    final displayArea = ref.watch(danmakuDisplayAreaProvider);
    final stroke = ref.watch(danmakuStrokeProvider);
    final blockwords = ref.watch(danmakuBlockwordsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('弹幕设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          SwitchListTile(
            title: const Text('弹幕开关'),
            value: enabled,
            onChanged: (value) =>
                ref.read(danmakuEnabledProvider.notifier).state = value,
          ),
          ListTile(
            title: const Text('透明度'),
            subtitle: Slider(
              value: opacity,
              onChanged: (value) =>
                  ref.read(danmakuOpacityProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('字号'),
            subtitle: Slider(
              value: fontSize,
              onChanged: (value) =>
                  ref.read(danmakuFontSizeProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('速度'),
            subtitle: Slider(
              value: speed,
              onChanged: (value) =>
                  ref.read(danmakuSpeedProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('密度'),
            subtitle: Slider(
              value: density,
              onChanged: (value) =>
                  ref.read(danmakuDensityProvider.notifier).state = value,
            ),
          ),
          ListTile(
            title: const Text('显示区域'),
            subtitle: const Text('弹幕占用的画面高度范围'),
            trailing: DropdownButton<double>(
              value: displayArea,
              items: const [
                DropdownMenuItem(value: 0.25, child: Text('顶部 1/4')),
                DropdownMenuItem(value: 0.5, child: Text('半屏')),
                DropdownMenuItem(value: 1.0, child: Text('全屏')),
              ],
              onChanged: (v) {
                if (v != null) {
                  ref.read(danmakuDisplayAreaProvider.notifier).state = v;
                }
              },
            ),
          ),
          SwitchListTile(
            title: const Text('描边文字'),
            subtitle: const Text('黑边彩字，关闭则用半透明底框'),
            value: stroke,
            onChanged: (v) =>
                ref.read(danmakuStrokeProvider.notifier).state = v,
          ),
          Builder(builder: (context) {
            final fontPath = ref.watch(customDanmakuFontPathProvider);
            return ListTile(
              title: const Text('弹幕字体'),
              subtitle: Text(
                fontPath.isEmpty ? '默认字体 · 点击导入字体文件 (ttf/otf)' : p.basename(fontPath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: fontPath.isEmpty
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      tooltip: '恢复默认',
                      icon: const Icon(Icons.clear),
                      onPressed: () async {
                        await FontService.clearDanmakuFont();
                        ref
                            .read(customDanmakuFontPathProvider.notifier)
                            .state = '';
                      },
                    ),
              onTap: () => _importCustomFont(context, ref, isApp: false),
            );
          }),
          ListTile(
            title: const Text('弹幕延迟'),
            subtitle: Builder(builder: (context) {
              final delay = ref.watch(danmakuDelayProvider);
              return Slider(
                value: delay,
                min: -5.0,
                max: 5.0,
                label: '${delay.toStringAsFixed(1)}s',
                onChanged: (value) =>
                    ref.read(danmakuDelayProvider.notifier).state = value,
              );
            }),
          ),
          ListTile(
            title: const Text('屏蔽词管理'),
            subtitle: Text('共 ${blockwords.length} 个屏蔽词'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showBlockwordManager(context, ref),
          ),
          SwitchListTile(
            title: const Text('弹幕去重'),
            subtitle: const Text('合并相同文本弹幕，显示重复次数'),
            value: ref.watch(danmakuDedupProvider),
            onChanged: (v) => ref.read(danmakuDedupProvider.notifier).state = v,
          ),
          if (ref.watch(danmakuDedupProvider))
            ListTile(
              title: const Text('去重时间窗口'),
              subtitle: Builder(builder: (context) {
                final window = ref.watch(danmakuDedupWindowProvider);
                return Slider(
                  value: window,
                  min: 1.0,
                  max: 30.0,
                  label: '${window.toStringAsFixed(0)}秒',
                  onChanged: (v) =>
                      ref.read(danmakuDedupWindowProvider.notifier).state = v,
                );
              }),
            ),
          const Divider(),
          ListTile(
            title: const Text('自定义弹幕源'),
            subtitle: const Text('添加 danmu_api / 御坂弹幕 等自定义源'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showCustomSourceManager(context, ref),
          ),
        ],
      ),
    );
  }

  void _showBlockwordManager(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Text(
                        '屏蔽词管理',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.add),
                        onSelected: (value) {
                          if (value == 'add') {
                            _showAddBlockwordDialog(context, ref);
                          } else if (value == 'import') {
                            _showImportDandanplayBlockwords(context, ref);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'add',
                            child: Row(
                              children: [
                                Icon(Icons.edit),
                                SizedBox(width: 8),
                                Text('添加屏蔽词'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'import',
                            child: Row(
                              children: [
                                Icon(Icons.download),
                                SizedBox(width: 8),
                                Text('导入弹弹弹幕屏蔽词'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    child: Consumer(
                      builder: (context, ref, child) {
                        final words = ref.watch(danmakuBlockwordsProvider);
                        if (words.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.block,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '暂无屏蔽词',
                                  style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: scrollController,
                          itemCount: words.length,
                          itemBuilder: (context, index) {
                            final word = words[index];
                            return ListTile(
                              title: Text(word),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.red),
                                onPressed: () {
                                  ref
                                      .read(danmakuBlockwordsProvider.notifier)
                                      .removeWord(word);
                                },
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAddBlockwordDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加屏蔽词'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入屏蔽词...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final word = controller.text.trim();
              if (word.isNotEmpty) {
                ref.read(danmakuBlockwordsProvider.notifier).addWord(word);
              }
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showImportDandanplayBlockwords(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入弹弹弹幕屏蔽词'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('支持导入弹弹play导出的 XML 格式屏蔽词文件。'),
            SizedBox(height: 8),
            Text(
              '会自动识别文本屏蔽词和用户ID屏蔽。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton.icon(
            icon: const Icon(Icons.folder_open),
            onPressed: () async {
              Navigator.pop(context);
              await _pickAndImportXmlFile(context, ref);
            },
            label: const Text('选择 XML 文件'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndImportXmlFile(
      BuildContext context, WidgetRef ref) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xml'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      final path = file.path;

      String xmlContent;
      if (bytes != null) {
        xmlContent = utf8.decode(bytes);
      } else if (path != null) {
        xmlContent = await File(path).readAsString();
      } else {
        throw Exception('无法读取文件内容');
      }

      // 解析 XML
      final importResult = DanmakuFilter.importFromDandanplayXml(xmlContent);

      // 导入到 Provider
      ref
          .read(danmakuBlockwordsProvider.notifier)
          .importWords(importResult.textWords);
      ref
          .read(danmakuBlockwordsProvider.notifier)
          .importUserBlocks(importResult.userIds);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导入 ${importResult.totalImported} 个屏蔽词'
              '${importResult.skippedCount > 0 ? '（跳过 ${importResult.skippedCount} 个）' : ''}',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  void _showCustomSourceManager(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CustomSourceManagerSheet(),
    );
  }
}

class _CustomSourceManagerSheet extends ConsumerStatefulWidget {
  @override
  ConsumerState<_CustomSourceManagerSheet> createState() =>
      _CustomSourceManagerSheetState();
}

class _CustomSourceManagerSheetState
    extends ConsumerState<_CustomSourceManagerSheet> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  DanmakuAuthType _authType = DanmakuAuthType.pathToken;
  bool _isAdding = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  static const _authLabels = {
    DanmakuAuthType.none: '无鉴权',
    DanmakuAuthType.pathToken: 'huangxd 路径 Token',
    DanmakuAuthType.headerToken: 'misaka Token（请求头）',
    DanmakuAuthType.queryToken: 'Token（Query 参数）',
  };

  bool get _needsToken =>
      _authType == DanmakuAuthType.pathToken ||
      _authType == DanmakuAuthType.headerToken ||
      _authType == DanmakuAuthType.queryToken;

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(danmakuServiceProvider);
    final customSources = service.sources;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('自定义弹幕源',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (service.dandanplay != null)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.cloud, color: Colors.blue),
                      title: const Text('弹弹Play（官方）'),
                      subtitle: Text(
                        service.dandanplay!.hasCredentials
                            ? '默认源，内置签名凭据，无需配置'
                            : '默认源（当前构建未内置官方凭据）',
                      ),
                      trailing: Icon(
                        service.dandanplay!.hasCredentials
                            ? Icons.check_circle
                            : Icons.cloud_off,
                        color: service.dandanplay!.hasCredentials
                            ? Colors.green
                            : Colors.grey,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: customSources.length,
                    itemBuilder: (context, index) {
                      final source = customSources[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.dns,
                            color: source.config.enabled
                                ? Colors.green
                                : Colors.grey,
                          ),
                          title: Text(source.config.name),
                          subtitle: Text(source.config.apiUrl,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: source.config.enabled,
                                onChanged: (val) {
                                  ref
                                      .read(danmakuServiceProvider.notifier)
                                      .addCustomSource(
                                          source.config.copyWith(enabled: val));
                                },
                              ),
                              IconButton(
                                icon:
                                    const Icon(Icons.delete, color: Colors.red),
                                onPressed: () {
                                  ref
                                      .read(danmakuServiceProvider.notifier)
                                      .removeCustomSource(source.config.id);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(),
                if (_isAdding) ...[
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '源名称',
                      hintText: '如：我的弹幕API',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'API地址',
                      hintText: '如: http://192.168.1.7:9321',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<DanmakuAuthType>(
                    initialValue: _authType,
                    decoration: const InputDecoration(
                      labelText: '鉴权方式',
                      border: OutlineInputBorder(),
                    ),
                    items: _authLabels.entries
                        .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _authType = v);
                    },
                  ),
                  if (_needsToken) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _tokenController,
                      decoration: const InputDecoration(
                        labelText: 'Token',
                        hintText: '按各项目文档填入访问 token',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => setState(() => _isAdding = false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addSource,
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: () => setState(() => _isAdding = true),
                    icon: const Icon(Icons.add),
                    label: const Text('添加自定义源'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _addSource() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写名称和API地址')),
      );
      return;
    }
    if (_needsToken && token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前鉴权方式需要填入 Token')),
      );
      return;
    }
    final cfg = DanmakuSourceConfig(
      id: const Uuid().v4(),
      type: DanmakuSourceType.custom,
      name: name,
      apiUrl: url,
      priority: ref.read(danmakuServiceProvider).sources.length,
      authType: _authType,
      token: _needsToken ? token : null,
    );
    ref.read(danmakuServiceProvider.notifier).addCustomSource(cfg);
    _nameController.clear();
    _urlController.clear();
    _tokenController.clear();
    setState(() => _isAdding = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加 $name')),
    );
  }
}

/// 备份与恢复页
