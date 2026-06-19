import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../widgets/common/media_widgets.dart';

enum LibraryViewMode { grid, list }

/// 媒体库列表页面（含常驻的屏蔽/解除屏蔽）
class LibrariesScreen extends ConsumerStatefulWidget {
  const LibrariesScreen({super.key});

  @override
  ConsumerState<LibrariesScreen> createState() => _LibrariesScreenState();
}

class _LibrariesScreenState extends ConsumerState<LibrariesScreen> {
  LibraryViewMode _viewMode = LibraryViewMode.grid;

  void _toggleBlock(String libraryId, bool nowBlocked) {
    ref.read(hiddenLibrariesProvider.notifier).toggle(libraryId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowBlocked ? '已解除屏蔽' : '已屏蔽，将不在首页等处显示'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 管理页显示全部媒体库（含被屏蔽的），这样屏蔽后仍可在此解除屏蔽。
    final librariesAsync = ref.watch(allLibrariesProvider);
    final hidden = ref.watch(hiddenLibrariesProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('媒体库'),
        actions: [
          IconButton(
            tooltip: _viewMode == LibraryViewMode.grid ? '列表视图' : '网格视图',
            icon: Icon(
              _viewMode == LibraryViewMode.grid
                  ? Icons.view_list
                  : Icons.grid_view,
            ),
            onPressed: () {
              setState(() {
                _viewMode = _viewMode == LibraryViewMode.grid
                    ? LibraryViewMode.list
                    : LibraryViewMode.grid;
              });
            },
          ),
        ],
      ),
      body: librariesAsync.when(
        data: (libraries) {
          if (libraries.isEmpty) {
            return const Center(child: Text('暂无媒体库'));
          }
          if (_viewMode == LibraryViewMode.grid) {
            return _GridView(
              libraries: libraries,
              hiddenIds: hidden,
              onToggleBlock: _toggleBlock,
              onTap: (library) => context.push('/library/${library.id}'),
            );
          }
          return _ListView(
            libraries: libraries,
            hiddenIds: hidden,
            onToggleBlock: _toggleBlock,
            onTap: (library) => context.push('/library/${library.id}'),
          );
        },
        loading: () => const AppLoadingIndicator(),
        error: (error, _) => Center(child: Text('加载失败: $error')),
      ),
    );
  }
}

/// 常驻屏蔽/解除屏蔽小圆钮。
class _BlockToggleButton extends StatelessWidget {
  final bool blocked;
  final VoidCallback onTap;

  const _BlockToggleButton({required this.blocked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            blocked ? Icons.visibility_off : Icons.block,
            size: 18,
            color: blocked ? const Color(0xFFFF6B6B) : Colors.white,
          ),
        ),
      ),
    );
  }
}

class _GridView extends ConsumerWidget {
  final List<Library> libraries;
  final Set<String> hiddenIds;
  final void Function(String id, bool nowBlocked) onToggleBlock;
  final void Function(Library) onTap;

  const _GridView({
    required this.libraries,
    required this.hiddenIds,
    required this.onToggleBlock,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.85,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: libraries.length,
      itemBuilder: (context, index) {
        final library = libraries[index];
        final blocked = hiddenIds.contains(library.id);
        final imageUrl = library.primaryImageTag != null
            ? api.image.getPrimaryImageUrl(library.id,
                tag: library.primaryImageTag, maxWidth: 400)
            : null;
        final borderRadius = BorderRadius.circular(16);

        return GestureDetector(
          onTap: () => onTap(library),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Opacity(
                      opacity: blocked ? 0.4 : 1.0,
                      child: Container(
                        decoration: BoxDecoration(borderRadius: borderRadius),
                        clipBehavior: Clip.antiAlias,
                        width: double.infinity,
                        height: double.infinity,
                        child: imageUrl != null
                            ? ColoredBox(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: SizedBox.expand(
                                  child: Transform.scale(
                                    scale: 1.04,
                                    child: MediaImage(
                                      imageUrl: imageUrl,
                                      width: double.infinity,
                                      height: double.infinity,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              )
                            : Container(
                                color:
                                    const Color(0xFF5B8DEF).withValues(alpha: 0.1),
                                child: const Center(
                                  child: Icon(Icons.folder,
                                      size: 48, color: Color(0xFF5B8DEF)),
                                ),
                              ),
                      ),
                    ),
                    if (blocked)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '已屏蔽',
                            style: TextStyle(
                                fontSize: 11, color: Color(0xFFFF6B6B)),
                          ),
                        ),
                      ),
                    // 常驻屏蔽/解除按钮
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _BlockToggleButton(
                        blocked: blocked,
                        onTap: () => onToggleBlock(library.id, blocked),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                library.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ).appEntrance(index: index);
      },
    );
  }
}

class _ListView extends StatelessWidget {
  final List<Library> libraries;
  final Set<String> hiddenIds;
  final void Function(String id, bool nowBlocked) onToggleBlock;
  final void Function(Library) onTap;

  const _ListView({
    required this.libraries,
    required this.hiddenIds,
    required this.onToggleBlock,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: libraries.length,
      itemBuilder: (context, index) {
        final library = libraries[index];
        final blocked = hiddenIds.contains(library.id);

        return ListTile(
          leading: Icon(
            library.collectionType == 'movies' ? Icons.movie : Icons.tv,
            color: blocked
                ? Theme.of(context).disabledColor
                : const Color(0xFF5B8DEF),
          ),
          title: Text(
            library.name,
            style: blocked
                ? TextStyle(color: Theme.of(context).disabledColor)
                : null,
          ),
          subtitle: blocked
              ? const Text('已屏蔽',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFF6B6B)))
              : null,
          trailing: IconButton(
            tooltip: blocked ? '解除屏蔽' : '屏蔽',
            icon: Icon(
              blocked ? Icons.visibility_off : Icons.block,
              color: blocked ? const Color(0xFFFF6B6B) : null,
            ),
            onPressed: () => onToggleBlock(library.id, blocked),
          ),
          onTap: () => onTap(library),
        );
      },
    );
  }
}
