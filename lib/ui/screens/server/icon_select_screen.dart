import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/app_identity.dart';
import '../../../core/providers/app_providers.dart';
import '../../widgets/common/media_widgets.dart';

class IconSelectScreen extends ConsumerStatefulWidget {
  final String serverId;

  const IconSelectScreen({super.key, required this.serverId});

  @override
  ConsumerState<IconSelectScreen> createState() => _IconSelectScreenState();
}

class _IconSelectScreenState extends ConsumerState<IconSelectScreen> {
  static const String _defaultLibraryName = '默认网络图标库';
  static const String _defaultLibraryUrl =
      'https://juhe.greentea520.xyz/share/78aspf.json';
  static const double _desktopBreakpoint = 960;

  final TextEditingController _searchController = TextEditingController();

  final List<NetworkIconLibrary> _libraries = [];
  bool _isLoading = true;
  String? _loadError;
  String _searchQuery = '';
  String? _selectedLibraryId;

  @override
  void initState() {
    super.initState();
    _loadDefaultLibrary();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _isDesktopLayout =>
      MediaQuery.sizeOf(context).width >= _desktopBreakpoint;

  NetworkIconLibrary? get _selectedLibrary {
    final targetId = _selectedLibraryId;
    if (targetId == null) {
      return _libraries.isEmpty ? null : _libraries.first;
    }

    for (final library in _libraries) {
      if (library.id == targetId) {
        return library;
      }
    }

    return _libraries.isEmpty ? null : _libraries.first;
  }

  List<IconItem> get _filteredIcons {
    final library = _selectedLibrary;
    if (library == null) {
      return const [];
    }

    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return library.icons;
    }

    return library.icons.where((icon) {
      final sourceName = icon.sourceName?.toLowerCase() ?? '';
      return icon.name.toLowerCase().contains(query) ||
          sourceName.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final server = _findServer(servers);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _closePage,
          ),
          centerTitle: !_isDesktopLayout,
          title: const Text('图标选择'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '本地图片'),
              Tab(text: '网络图标库'),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: _isDesktopLayout ? 1160 : double.infinity,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  _isDesktopLayout ? 24 : 16,
                  _isDesktopLayout ? 24 : 16,
                  _isDesktopLayout ? 24 : 16,
                  _isDesktopLayout ? 24 : 16,
                ),
                child: TabBarView(
                  children: [
                    _buildLocalTab(server),
                    _buildNetworkTab(server),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocalTab(ServerConfig? server) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.24),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CurrentIconPreview(iconUrl: server?.iconUrl),
              const SizedBox(height: 20),
              Text(
                '选择本地图片',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _pickLocalImage,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(_isDesktopLayout ? '浏览文件' : '选择图片'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkTab(ServerConfig? server) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_loadError != null && _libraries.isEmpty) {
      return _NetworkEmptyState(
        message: _loadError!,
        buttonText: '重新加载',
        onPressed: _loadDefaultLibrary,
      );
    }

    final library = _selectedLibrary;
    final icons = _filteredIcons;

    return Column(
      children: [
        _NetworkLibraryHeader(
          library: library,
          libraries: _libraries,
          isDesktopLayout: _isDesktopLayout,
          onChanged: _selectLibrary,
          onAddSource: _showAddSourceDialog,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _searchController,
          onChanged: (value) {
            setState(() {
              _searchQuery = value;
            });
          },
          decoration: InputDecoration(
            hintText: '搜索图标',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: _clearSearch,
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: library == null
              ? _NetworkEmptyState(
                  message: '还没有可用图标库',
                  buttonText: '添加源',
                  onPressed: _showAddSourceDialog,
                )
              : icons.isEmpty
                  ? _NetworkEmptyState(
                      message: _searchQuery.isEmpty ? '当前图标库没有可用图标' : '没有找到匹配的图标',
                      buttonText: _searchQuery.isEmpty ? '重新加载' : '清空搜索',
                      onPressed: _searchQuery.isEmpty
                          ? () => _reloadLibrary(library)
                          : _clearSearch,
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final crossAxisCount =
                            _gridColumnCount(constraints.maxWidth);
                        return Scrollbar(
                          child: GridView.builder(
                            padding: EdgeInsets.zero,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: _isDesktopLayout ? 0.78 : 0.74,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            itemCount: icons.length,
                            itemBuilder: (context, index) {
                              final icon = icons[index];
                              return _NetworkIconCard(
                                icon: icon,
                                selected: server?.iconUrl == icon.url,
                                onTap: () => _selectIcon(icon),
                              );
                            },
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Future<void> _loadDefaultLibrary() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final library = await _fetchLibrary(
        name: _defaultLibraryName,
        url: _defaultLibraryUrl,
        id: _defaultLibraryUrl,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _libraries
          ..clear()
          ..add(library);
        _selectedLibraryId = library.id;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _libraries.clear();
        _isLoading = false;
        _loadError = '图标库加载失败';
      });
    }
  }

  Future<NetworkIconLibrary> _fetchLibrary({
    required String name,
    required String url,
    required String id,
  }) async {
    // 图标库 CDN 多拒绝 App UA，用中立浏览器 UA 请求 JSON。
    final response = await Dio().get(
      url,
      options: Options(
        headers: const {'User-Agent': kDefaultBrowserUserAgent},
      ),
    );
    final icons = _parseIconJson(jsonEncode(response.data));

    return NetworkIconLibrary(
      id: id,
      name: name,
      url: url,
      icons: icons,
    );
  }

  Future<void> _reloadLibrary(NetworkIconLibrary library) async {
    try {
      final updated = await _fetchLibrary(
        name: library.name,
        url: library.url,
        id: library.id,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        final index = _libraries.indexWhere((item) => item.id == library.id);
        if (index != -1) {
          _libraries[index] = updated;
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图标库加载失败')),
      );
    }
  }

  Future<void> _showAddSourceDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    bool submitting = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('添加图标库源'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: '名称',
                        hintText: '我的图标库',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: urlController,
                      decoration: const InputDecoration(
                        labelText: '源地址',
                        hintText: 'https://example.com/icons.json',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      submitting ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          final name = nameController.text.trim();
                          final url = urlController.text.trim();
                          final messenger = ScaffoldMessenger.of(context);

                          if (url.isEmpty) {
                            messenger.showSnackBar(
                              const SnackBar(content: Text('请输入源地址')),
                            );
                            return;
                          }

                          setDialogState(() {
                            submitting = true;
                          });

                          try {
                            final library = await _fetchLibrary(
                              name: name.isEmpty ? '自定义图标库' : name,
                              url: url,
                              id: url,
                            );

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              final existingIndex = _libraries.indexWhere(
                                (item) => item.id == library.id,
                              );
                              if (existingIndex == -1) {
                                _libraries.add(library);
                              } else {
                                _libraries[existingIndex] = library;
                              }
                              _selectedLibraryId = library.id;
                            });

                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          } catch (_) {
                            if (!mounted) {
                              return;
                            }
                            messenger.showSnackBar(
                              const SnackBar(content: Text('添加源失败')),
                            );
                            setDialogState(() {
                              submitting = false;
                            });
                          }
                        },
                  child: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('添加'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    urlController.dispose();
  }

  Future<void> _pickLocalImage() async {
    final platform = defaultTargetPlatform;
    if (platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS) {
      await _pickFromFiles();
      return;
    }

    await _pickFromGallery();
  }

  Future<void> _pickFromGallery() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        _updateServerIcon(image.path);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('选择图片失败')),
      );
    }
  }

  Future<void> _pickFromFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final path = result.files.first.path;
        if (path != null && path.isNotEmpty) {
          _updateServerIcon(path);
        }
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('选择文件失败')),
      );
    }
  }

  void _updateServerIcon(String iconUrl) {
    final servers = ref.read(serverListProvider);
    final server = _findServer(servers);
    if (server == null) {
      return;
    }

    ref.read(serverListProvider.notifier).updateServer(
          server.copyWith(iconUrl: iconUrl),
        );
    _closePage();
  }

  void _selectIcon(IconItem icon) {
    _updateServerIcon(icon.url);
  }

  void _selectLibrary(String? libraryId) {
    setState(() {
      _selectedLibraryId = libraryId;
      _searchQuery = '';
      _searchController.clear();
    });
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
    });
  }

  void _closePage() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    context.go(_isDesktopLayout ? '/servers' : '/');
  }

  ServerConfig? _findServer(List<ServerConfig> servers) {
    for (final server in servers) {
      if (server.id == widget.serverId) {
        return server;
      }
    }
    return null;
  }

  List<IconItem> _parseIconJson(String jsonText) {
    final decoded = jsonDecode(jsonText);
    final items = <Map<String, dynamic>>[];
    final seenUrls = <String>{};

    void collect(dynamic value) {
      if (value is List) {
        for (final item in value) {
          collect(item);
        }
        return;
      }

      if (value is Map) {
        final map = value.map(
          (key, mapValue) => MapEntry(key.toString(), mapValue),
        );

        if (map['url'] is String) {
          items.add(map);
        }

        for (final nested in map.values) {
          collect(nested);
        }
      }
    }

    collect(decoded);

    final icons = <IconItem>[];
    for (final item in items) {
      final url = item['url'].toString();
      if (!seenUrls.add(url)) {
        continue;
      }

      final name =
          (item['name'] ?? item['title'] ?? item['label'])?.toString().trim();
      final sourceName =
          (item['sourceName'] ?? item['libraryName'] ?? item['source'])
              ?.toString()
              .trim();

      icons.add(
        IconItem(
          name: name == null || name.isEmpty ? '图标 ${icons.length + 1}' : name,
          url: url,
          sourceName:
              sourceName == null || sourceName.isEmpty ? null : sourceName,
        ),
      );
    }

    return icons;
  }

  int _gridColumnCount(double width) {
    if (width >= 1000) {
      return 6;
    }
    if (width >= 820) {
      return 5;
    }
    if (width >= 640) {
      return 4;
    }
    if (width >= 460) {
      return 3;
    }
    return 2;
  }
}

class NetworkIconLibrary {
  final String id;
  final String name;
  final String url;
  final List<IconItem> icons;

  const NetworkIconLibrary({
    required this.id,
    required this.name,
    required this.url,
    required this.icons,
  });
}

class IconItem {
  final String name;
  final String url;
  final String? sourceName;

  const IconItem({
    required this.name,
    required this.url,
    this.sourceName,
  });
}

class _CurrentIconPreview extends StatelessWidget {
  final String? iconUrl;

  const _CurrentIconPreview({required this.iconUrl});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRemote = iconUrl != null &&
        (iconUrl!.startsWith('http://') || iconUrl!.startsWith('https://'));

    return Container(
      width: 112,
      height: 112,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: isRemote
          ? MediaImage(
              imageUrl: iconUrl,
              fit: BoxFit.contain,
              useDefaultUserAgent: true,
            )
          : Icon(
              Icons.image_outlined,
              size: 36,
              color: theme.colorScheme.outline,
            ),
    );
  }
}

class _NetworkLibraryHeader extends StatelessWidget {
  final NetworkIconLibrary? library;
  final List<NetworkIconLibrary> libraries;
  final bool isDesktopLayout;
  final ValueChanged<String?> onChanged;
  final VoidCallback onAddSource;

  const _NetworkLibraryHeader({
    required this.library,
    required this.libraries,
    required this.isDesktopLayout,
    required this.onChanged,
    required this.onAddSource,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isDesktopLayout)
            Row(
              children: [
                Expanded(child: _buildLibraryInfo(context)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 220,
                  child: _buildLibraryDropdown(),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: onAddSource,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('添加源'),
                ),
              ],
            )
          else ...[
            _buildLibraryInfo(context),
            const SizedBox(height: 12),
            _buildLibraryDropdown(),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onAddSource,
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加源'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLibraryInfo(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          library?.name ?? '网络图标库',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          library?.url ?? '暂无源地址',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildLibraryDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: library?.id,
      items: libraries
          .map(
            (item) => DropdownMenuItem<String>(
              value: item.id,
              child: Text(
                item.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: onChanged,
      decoration: const InputDecoration(
        labelText: '当前源',
      ),
    );
  }
}

class _NetworkEmptyState extends StatelessWidget {
  final String message;
  final String buttonText;
  final VoidCallback onPressed;

  const _NetworkEmptyState({
    required this.message,
    required this.buttonText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onPressed,
              child: Text(buttonText),
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkIconCard extends StatelessWidget {
  final IconItem icon;
  final bool selected;
  final VoidCallback onTap;

  const _NetworkIconCard({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = selected
        ? theme.colorScheme.primary
        : theme.dividerColor.withValues(alpha: 0.28);

    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: MediaImage(
                    imageUrl: icon.url,
                    fit: BoxFit.contain,
                    useDefaultUserAgent: true,
                    errorWidget: Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                icon.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
