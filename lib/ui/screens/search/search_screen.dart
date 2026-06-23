import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import '../../widgets/common/media_widgets.dart';

/// 搜索页（含聚合搜索）
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  bool _showResults = false;
  
  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final isAggregate = ref.watch(aggregateSearchProvider);
    final searchResults = ref.watch(searchResultsProvider);
    final searchHistory = ref.watch(searchHistoryProvider);
    
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '搜索...',
            border: InputBorder.none,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      ref.read(searchQueryProvider.notifier).state = '';
                      setState(() => _showResults = false);
                    },
                  ),
                // 聚合搜索开关
                _AggregateToggle(
                  isAggregate: isAggregate,
                  onToggle: (value) {
                    ref.read(aggregateSearchProvider.notifier).state = value;
                  },
                ),
              ],
            ),
          ),
          onSubmitted: (value) {
            if (value.isNotEmpty) {
              ref.read(searchQueryProvider.notifier).state = value;
              ref.read(searchHistoryProvider.notifier).addQuery(value);
              setState(() => _showResults = true);
            }
          },
          onChanged: (value) {
            setState(() {});
          },
        ),
      ),
      body: _showResults ? _buildSearchResults(searchResults) : _buildSearchHistory(searchHistory),
    );
  }
  
  Widget _buildSearchHistory(List<String> history) {
    if (history.isEmpty) {
      return _buildEmptyState();
    }
    
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '搜索历史',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            TextButton(
              onPressed: () => ref.read(searchHistoryProvider.notifier).clear(),
              child: const Text('清除'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: history.map((query) => InputChip(
            label: Text(query),
            onPressed: () {
              _searchController.text = query;
              ref.read(searchQueryProvider.notifier).state = query;
              setState(() => _showResults = true);
            },
            deleteIcon: const Icon(Icons.close, size: 16),
            onDeleted: () => ref.read(searchHistoryProvider.notifier).removeQuery(query),
          )).toList(),
        ),
      ],
    );
  }
  
  Widget _buildSearchResults(AsyncValue<List<MediaItem>> results) {
    return results.when(
      data: (items) {
        if (items.isEmpty) {
          return const Center(child: Text('没有找到结果'));
        }
        
        // 聚合搜索显示
        final isAggregate = ref.watch(aggregateSearchProvider);
        if (isAggregate) {
          return _buildAggregateResults();
        }
        
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final api = ref.read(apiClientProvider);
              final imageUrls = resolveMediaItemImageUrls(
                api,
                item,
                maxWidth: 120,
                preferThumb: item.type == 'Episode',
              );
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  onTap: () => context.push(mediaRouteForItem(item)),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 60,
                      height: 90,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: imageUrls.isNotEmpty
                          ? MediaImage(
                              imageUrl: imageUrls.first,
                              imageUrls: imageUrls.length > 1
                                  ? imageUrls.sublist(1)
                                  : null,
                              width: 60,
                              height: 90,
                              fit: BoxFit.contain,
                            )
                          : const Icon(Icons.image),
                    ),
                  ),
                title: Text(item.name),
                subtitle: Text(
                  item.type == 'Movie' ? '电影' : '剧集',
                  style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
                ),
                trailing: item.communityRating != null
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star, size: 16, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text(item.communityRating!.toStringAsFixed(1)),
                        ],
                      )
                    : null,
              ),
            ).appEntrance(index: index);
          },
        );
      },
      loading: () => const AppLoadingIndicator(),
      error: (error, _) => Center(child: Text('搜索失败: $error')),
    );
  }
  
  Widget _buildAggregateResults() {
    // 复用共享的跨服务器聚合 provider（并行查询 + 失败记日志），不再在 UI 层
    // 自己串行遍历服务器，三端口径统一。
    final aggregateAsync = ref.watch(aggregateSearchResultsProvider);

    return aggregateAsync.when(
      loading: () => const AppLoadingIndicator(),
      error: (e, _) => Center(child: Text('搜索失败: $e')),
      data: (aggregateData) {
        if (aggregateData.isEmpty) {
          return const Center(child: Text('没有找到结果'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: aggregateData.length,
          itemBuilder: (context, serverIndex) {
            final serverName = aggregateData.keys.elementAt(serverIndex);
            final items = aggregateData[serverName]!;
            
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Container(width: 40, height: 1, color: Theme.of(context).dividerColor),
                      const SizedBox(width: 8),
                      Text(
                        serverName,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      Container(width: 40, height: 1, color: Theme.of(context).dividerColor),
                    ],
                  ),
                ),
                ...items.map((item) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    onTap: () => openMediaItem(ref, context, item),
                    title: Text(item.name),
                    subtitle: Text(item.type == 'Movie' ? '电影' : '剧集'),
                    trailing: item.communityRating != null
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star, size: 16, color: Colors.amber),
                              Text(item.communityRating!.toStringAsFixed(1)),
                            ],
                          )
                        : null,
                  ),
                )),
              ],
            );
          },
        );
      },
    );
  }
  
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '输入关键词开始搜索',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 聚合搜索开关
class _AggregateToggle extends StatelessWidget {
  final bool isAggregate;
  final ValueChanged<bool> onToggle;
  
  const _AggregateToggle({
    required this.isAggregate,
    required this.onToggle,
  });
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '聚合',
            style: TextStyle(
              fontSize: 12,
              color: isAggregate
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
          Switch(
            value: isAggregate,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}
