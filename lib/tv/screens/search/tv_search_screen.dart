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
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focusable.dart';

/// TV 搜索页 —— 左侧虚拟键盘 + 右侧真实搜索结果 / 历史。
class TvSearchScreen extends ConsumerStatefulWidget {
  const TvSearchScreen({super.key});

  @override
  ConsumerState<TvSearchScreen> createState() => _TvSearchScreenState();
}

class _TvSearchScreenState extends ConsumerState<TvSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _hasSearched = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _submit(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    ref.read(searchQueryProvider.notifier).state = q;
    ref.read(searchHistoryProvider.notifier).addQuery(q);
    setState(() => _hasSearched = true);
  }

  void _onKeyPress(String key) {
    _searchController.text += key;
    setState(() {});
  }

  void _onBackspace() {
    final t = _searchController.text;
    if (t.isNotEmpty) {
      _searchController.text = t.substring(0, t.length - 1);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Row(
        children: [
          Expanded(
            flex: 2,
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
                  _buildInputBox(m),
                  SizedBox(height: m.spacingLg),
                  Expanded(child: _buildVirtualKeyboard(m)),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Container(
              color: TvDesignTokens.surface,
              child: _hasSearched
                  ? _buildSearchResults(m)
                  : _buildSearchHistory(m),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBox(TvMetrics m) {
    final hasText = _searchController.text.isNotEmpty;
    return Container(
      padding: EdgeInsets.all(m.spacingMd),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        children: [
          Icon(Icons.search,
              color: TvDesignTokens.textSecondary, size: m.s(32)),
          SizedBox(width: m.spacingMd),
          Expanded(
            child: Text(
              hasText ? _searchController.text : '输入搜索内容...',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: hasText
                    ? TvDesignTokens.textPrimary
                    : TvDesignTokens.textDisabled,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVirtualKeyboard(TvMetrics m) {
    const rows = [
      ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
      ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
      ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
    ];
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final row in rows)
          Padding(
            padding: EdgeInsets.only(bottom: m.keyboardKeySpacing),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final key in row)
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: m.keyboardKeySpacing),
                    child: TvFocusable(
                      autofocus: row == rows.first && key == 'q',
                      padding: const EdgeInsets.all(4),
                      onSelect: () => _onKeyPress(key),
                      child: Container(
                        width: m.keyboardKeyWidth,
                        height: m.keyboardKeyHeight,
                        decoration: BoxDecoration(
                          color: TvDesignTokens.surfaceElevated,
                          borderRadius: BorderRadius.circular(m.posterRadius),
                        ),
                        child: Center(
                          child: Text(
                            key.toUpperCase(),
                            style: TextStyle(
                              fontSize: m.keyboardFontSize,
                              color: TvDesignTokens.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.only(top: m.spacingMd),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TvFocusable(
                padding: const EdgeInsets.all(4),
                onSelect: () => _onKeyPress(' '),
                child: _keyCap(m, width: m.s(160), child: Text('空格',
                    style: TextStyle(
                        fontSize: m.fontSizeSm,
                        color: TvDesignTokens.textPrimary))),
              ),
              SizedBox(width: m.spacingMd),
              TvFocusable(
                padding: const EdgeInsets.all(4),
                onSelect: _onBackspace,
                child: _keyCap(m,
                    child: Icon(Icons.backspace,
                        color: TvDesignTokens.textPrimary, size: m.s(28))),
              ),
              SizedBox(width: m.spacingMd),
              TvButton(
                text: '搜索',
                icon: Icons.search,
                onPressed: () => _submit(_searchController.text),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _keyCap(TvMetrics m, {double? width, required Widget child}) {
    return Container(
      width: width,
      height: m.keyboardKeyHeight,
      padding: EdgeInsets.symmetric(horizontal: m.spacingMd),
      decoration: BoxDecoration(
        color: TvDesignTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Center(child: child),
    );
  }

  Widget _buildSearchHistory(TvMetrics m) {
    final history = ref.watch(searchHistoryProvider);
    if (history.isEmpty) {
      return Center(
        child: Text('暂无搜索历史',
            style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.textDisabled)),
      );
    }
    return ListView(
      padding: EdgeInsets.all(m.spacingLg),
      children: [
        Row(
          children: [
            Text('搜索历史',
                style: TextStyle(
                    fontSize: m.fontSizeLg,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold)),
            const Spacer(),
            TvFocusable(
              padding: const EdgeInsets.all(6),
              onSelect: () =>
                  ref.read(searchHistoryProvider.notifier).clear(),
              child: Text('清除全部',
                  style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: TvDesignTokens.brand)),
            ),
          ],
        ),
        SizedBox(height: m.spacingLg),
        for (final query in history)
          TvFocusable(
            padding: const EdgeInsets.all(4),
            onSelect: () {
              _searchController.text = query;
              _submit(query);
            },
            child: Container(
              padding: EdgeInsets.all(m.spacingMd),
              margin: EdgeInsets.only(bottom: m.spacingSm),
              decoration: BoxDecoration(
                color: TvDesignTokens.background,
                borderRadius: BorderRadius.circular(m.posterRadius),
              ),
              child: Row(
                children: [
                  Icon(Icons.history,
                      color: TvDesignTokens.textSecondary, size: m.s(24)),
                  SizedBox(width: m.spacingMd),
                  Expanded(
                    child: Text(query,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: m.fontSizeMd,
                            color: TvDesignTokens.textPrimary)),
                  ),
                ],
              ),
            ),
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
            child: Text('未找到“$query”的结果',
                style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: TvDesignTokens.textDisabled)),
          );
        }
        return ListView(
          padding: EdgeInsets.all(m.spacingLg),
          children: [
            Text('“$query” 的搜索结果（${items.length}）',
                style: TextStyle(
                    fontSize: m.fontSizeLg,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold)),
            SizedBox(height: m.spacingLg),
            for (final entry in items.asMap().entries)
              _buildResultRow(m, api, entry.value).animate().fadeIn(
                    delay: Duration(milliseconds: 30 * entry.key),
                    duration: TvDesignTokens.contentFadeDuration,
                  ),
          ],
        );
      },
      loading: () =>
          const Center(child: CircularProgressIndicator(color: TvDesignTokens.brand)),
      error: (e, _) => Center(
        child: Text('搜索失败：$e',
            style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.textSecondary)),
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
            color: TvDesignTokens.background,
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
