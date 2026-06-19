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

/// TV 媒体库页 —— 顶部排序，下方 2:3 海报网格（真实数据）。
class TvLibraryScreen extends ConsumerStatefulWidget {
  /// 由首页/查看全部传入的目标媒体库；为空时取第一个媒体库。
  final String? initialLibraryId;

  const TvLibraryScreen({super.key, this.initialLibraryId});

  @override
  ConsumerState<TvLibraryScreen> createState() => _TvLibraryScreenState();
}

class _TvLibraryScreenState extends ConsumerState<TvLibraryScreen> {
  /// 海报密度档位：决定单张海报的目标宽度倍率，配合 max-extent 网格
  /// 让列数随屏幕宽度自适应。三档对应「较密 / 中等 / 较疏」。
  static const List<double> _densityFactors = [0.85, 1.0, 1.3];
  int _densityIndex = 1;
  String? _libraryId;
  // 排序字段：名称 / 最近添加 / 评分 / 首播日期
  String _sortBy = 'SortName';

  @override
  void initState() {
    super.initState();
    _libraryId = widget.initialLibraryId;
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final librariesAsync = ref.watch(librariesProvider);

    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Padding(
        padding: EdgeInsets.all(m.spacingXl),
        child: librariesAsync.when(
          data: (libs) {
            if (libs.isEmpty) {
              return _centerHint('暂无媒体库');
            }
            final libId = _libraryId ?? libs.first.id;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(m, libs, libId),
                SizedBox(height: m.spacingMd),
                _buildSortRow(m),
                SizedBox(height: m.spacingLg),
                Expanded(child: _buildGrid(m, libId)),
              ],
            );
          },
          loading: () =>
              const Center(child: CircularProgressIndicator(color: TvDesignTokens.brand)),
          error: (e, _) => _centerHint('加载媒体库失败：$e'),
        ),
      ),
    );
  }

  Widget _buildHeader(TvMetrics m, List<Library> libs, String selectedId) {
    final dense = _densityIndex == 0;
    final lib = libs.firstWhere(
      (l) => l.id == selectedId,
      orElse: () => libs.first,
    );
    return Row(
      children: [
        Text(
          lib.name,
          style: TextStyle(
            fontSize: m.fontSizeXxl,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Spacer(),
        TvFocusable(
          onSelect: () => setState(() {
            _densityIndex = (_densityIndex + 1) % _densityFactors.length;
          }),
          child: _chip(
            m,
            icon: dense ? Icons.grid_on : Icons.grid_view,
            label: _densityIndex == 0
                ? '较密'
                : (_densityIndex == 1 ? '中等' : '较疏'),
            selected: false,
          ),
        ),
      ],
    );
  }

  /// 排序选项：名称 / 最近添加 / 评分 / 首播日期。
  static const List<({String label, String value})> _sortOptions = [
    (label: '名称', value: 'SortName'),
    (label: '最近添加', value: 'DateCreated'),
    (label: '评分', value: 'CommunityRating'),
    (label: '首播日期', value: 'PremiereDate'),
  ];

  Widget _buildSortRow(TvMetrics m) {
    return Wrap(
      spacing: m.spacingSm,
      runSpacing: m.spacingSm,
      children: [
        for (final opt in _sortOptions)
          TvFocusable(
            onSelect: () => setState(() => _sortBy = opt.value),
            child: _chip(m, label: opt.label, selected: _sortBy == opt.value),
          ),
      ],
    );
  }

  Widget _buildGrid(TvMetrics m, String libraryId) {
    // 名称按升序（A→Z），其余（最近添加/评分/首播日期）按降序（新→旧 / 高→低）。
    final itemsAsync = ref.watch(libraryItemsProvider((
      libraryId: libraryId,
      sortBy: _sortBy,
      sortOrder: _sortBy == 'SortName' ? 'Ascending' : 'Descending',
    )));
    final api = ref.read(apiClientProvider);

    // 2:3 海报 + 下方标题；列数随屏幕宽度自适应，密度档位微调目标宽度。
    final double maxExtent =
        m.posterWidth2_3 * _densityFactors[_densityIndex];
    return itemsAsync.when(
      data: (items) {
        if (items.isEmpty) return _centerHint('该媒体库暂无内容');
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            childAspectRatio: 2 / 3.4,
            crossAxisSpacing: m.posterSpacing,
            mainAxisSpacing: m.posterSpacing,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final urls = resolveMediaItemImageUrls(api, item, maxWidth: 360);
            return TvFocusable(
              padding: EdgeInsets.all(m.s(6)),
              onSelect: () => context.push('/tv/detail/${item.id}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(m.posterRadius),
                      child: urls.isNotEmpty
                          ? MediaImage(
                              imageUrl: urls.first,
                              imageUrls: urls.length > 1 ? urls.sublist(1) : null,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                            )
                          : ColoredBox(
                              color: TvDesignTokens.surfaceElevated,
                              child: Icon(Icons.movie_outlined,
                                  color: TvDesignTokens.textDisabled,
                                  size: m.s(40)),
                            ),
                    ),
                  ),
                  SizedBox(height: m.spacingXs),
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.fontSizeXs,
                      color: TvDesignTokens.textPrimary,
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(
                  delay: Duration(milliseconds: 12 * (index % 6)),
                  duration: TvDesignTokens.contentFadeDuration,
                );
          },
        );
      },
      loading: () =>
          const Center(child: CircularProgressIndicator(color: TvDesignTokens.brand)),
      error: (e, _) => _centerHint('加载失败：$e'),
    );
  }

  Widget _chip(TvMetrics m,
      {IconData? icon, required String label, required bool selected}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: m.spacingMd,
        vertical: m.spacingXs,
      ),
      decoration: BoxDecoration(
        color: selected
            ? TvDesignTokens.brand.withValues(alpha: 0.18)
            : TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
        border:
            selected ? Border.all(color: TvDesignTokens.brand, width: 2) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon,
                size: m.s(22),
                color: selected
                    ? TvDesignTokens.brand
                    : TvDesignTokens.textSecondary),
            SizedBox(width: m.spacingXs),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: m.fontSizeSm,
              color: selected ? TvDesignTokens.brand : TvDesignTokens.textPrimary,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _centerHint(String text) {
    final m = context.tv;
    return Center(
      child: Text(
        text,
        style: TextStyle(
          color: TvDesignTokens.textSecondary,
          fontSize: m.fontSizeMd,
        ),
      ),
    );
  }
}
