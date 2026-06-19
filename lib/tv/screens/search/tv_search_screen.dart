import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';

/// TV / Pad 搜索页
///
/// 结构（自上而下）：搜索栏 → 搜索历史 → 搜索结果。
/// 直接使用系统输入法（支持中文与语音输入），不再内置软键盘——
/// TV 与平板均自带系统键盘，自绘键盘既无法输入中文又难以点击。
class TvSearchScreen extends ConsumerStatefulWidget {
  const TvSearchScreen({super.key});

  @override
  ConsumerState<TvSearchScreen> createState() => _TvSearchScreenState();
}

class _TvSearchScreenState extends ConsumerState<TvSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();
  bool _hasSearched = false;

  @override
  void dispose() {
    _searchController.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _submit(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    ref.read(searchQueryProvider.notifier).state = q;
    ref.read(searchHistoryProvider.notifier).addQuery(q);
    setState(() => _hasSearched = true);
  }

  void _clear() {
    _searchController.clear();
    ref.read(searchQueryProvider.notifier).state = '';
    setState(() => _hasSearched = false);
    _fieldFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(m.spacingXl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '搜索',
                style: TextStyle(
                  fontSize: m.fontSizeXxl,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: m.spacingLg),
              _buildSearchField(m),
              SizedBox(height: m.spacingLg),
              Expanded(
                child: _hasSearched
                    ? _buildSearchResults(m)
                    : _buildSearchHistory(m),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(TvMetrics m) {
    final hasText = _searchController.text.isNotEmpty;
    return TextField(
      controller: _searchController,
      focusNode: _fieldFocus,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onSubmitted: _submit,
      onChanged: (_) => setState(() {}),
      style: TextStyle(
        fontSize: m.fontSizeLg,
        color: TvDesignTokens.textPrimary,
      ),
      cursorColor: TvDesignTokens.brand,
      decoration: InputDecoration(
        hintText: '搜索影片、剧集……（支持中文 / 语音输入）',
        prefixIcon: Icon(Icons.search,
            color: TvDesignTokens.textSecondary, size: m.s(28)),
        suffixIcon: hasText
            ? IconButton(
                icon: Icon(Icons.close,
                    color: TvDesignTokens.textSecondary, size: m.s(26)),
                onPressed: _clear,
              )
            : null,
        contentPadding: EdgeInsets.symmetric(
          horizontal: m.spacingLg,
          vertical: m.spacingMd,
        ),
      ),
    );
  }

  Widget _buildSearchHistory(TvMetrics m) {
    final history = ref.watch(searchHistoryProvider);
    if (history.isEmpty) {
      return Center(
        child: Text(
          '暂无搜索历史',
          style: TextStyle(
            fontSize: m.fontSizeMd,
            color: TvDesignTokens.textDisabled,
          ),
        ),
      );
    }
    return ListView(
      children: [
        Row(
          children: [
            Text(
              '搜索历史',
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            TvFocusable(
              padding: const EdgeInsets.all(6),
              onSelect: () => ref.read(searchHistoryProvider.notifier).clear(),
              child: Text(
                '清除全部',
                style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.brand,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: m.spacingMd),
        Wrap(
          spacing: m.spacingSm,
          runSpacing: m.spacingSm,
          children: [
            for (final query in history)
              TvFocusable(
                padding: const EdgeInsets.all(4),
                onSelect: () {
                  _searchController.text = query;
                  _submit(query);
                },
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.spacingMd,
                    vertical: m.spacingSm,
                  ),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surface,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history,
                          color: TvDesignTokens.textSecondary, size: m.s(22)),
                      SizedBox(width: m.spacingSm),
                      Text(
                        query,
                        style: TextStyle(
                          fontSize: m.fontSizeMd,
                          color: TvDesignTokens.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSearchResults(TvMetrics m) {
    final resultsAsync = ref.watch(searchResultsProvider);
    final query = ref.watch(searchQueryProvider);
    final api = ref.read(apiClientProvider);

    return resultsAsync.when(
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              '未找到“$query”的结果',
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.textDisabled,
              ),
            ),
          );
        }
        return ListView(
          children: [
            Text(
              '“$query” 的搜索结果（${items.length}）',
              style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: m.spacingLg),
            for (final entry in items.asMap().entries)
              _buildResultRow(m, api, entry.value).animate().fadeIn(
                    delay: Duration(milliseconds: 30 * entry.key),
                    duration: TvDesignTokens.contentFadeDuration,
                  ),
          ],
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(color: TvDesignTokens.brand),
      ),
      error: (e, _) => Center(
        child: Text(
          '搜索失败：$e',
          style: TextStyle(
            fontSize: m.fontSizeSm,
            color: TvDesignTokens.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildResultRow(TvMetrics m, ApiClientFactory api, MediaItem item) {
    final urls = resolveMediaItemLandscapeImageUrls(api, item, maxWidth: 360);
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: TvFocusable(
        padding: const EdgeInsets.all(4),
        onSelect: () => context.push('/tv/detail/${item.id}'),
        child: Container(
          padding: EdgeInsets.all(m.spacingMd),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(m.posterRadius),
                child: SizedBox(
                  width: m.s(124),
                  height: m.s(70),
                  child: urls.isNotEmpty
                      ? MediaImage(
                          imageUrl: urls.first,
                          width: m.s(124),
                          height: m.s(70),
                          fit: BoxFit.cover,
                        )
                      : const ColoredBox(
                          color: TvDesignTokens.surfaceElevated,
                          child: Icon(Icons.movie_outlined,
                              color: TvDesignTokens.textDisabled)),
                ),
              ),
              SizedBox(width: m.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: m.fontSizeMd,
                            color: TvDesignTokens.textPrimary)),
                    SizedBox(height: m.spacingXs),
                    Text(_resultSubtitle(item),
                        style: TextStyle(
                            fontSize: m.fontSizeSm,
                            color: TvDesignTokens.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _resultSubtitle(MediaItem item) {
    final type = switch (item.type) {
      'Movie' => '电影',
      'Series' => '剧集',
      'Episode' => '单集',
      _ => item.type,
    };
    final parts = <String>[type];
    if (item.productionYear != null) parts.add('${item.productionYear}');
    return parts.join(' · ');
  }
}
