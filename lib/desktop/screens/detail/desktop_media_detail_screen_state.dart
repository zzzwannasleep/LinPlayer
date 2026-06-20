part of 'desktop_media_detail_screen.dart';

// ============================================================================
// 主内容区
// ============================================================================

class _DetailContent extends ConsumerStatefulWidget {
  final MediaItem item;
  final String itemId;

  const _DetailContent({required this.item, required this.itemId});

  @override
  ConsumerState<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends ConsumerState<_DetailContent> {
  late Color _backgroundColor;
  late Color _dominantColor;
  Color _primaryColor = AppColors.brand;
  Color? _extractedBackgroundColor;
  Brightness? _lastBrightness;

  final ScrollController _scrollController = DesktopSmoothScrollController();

  @override
  void initState() {
    super.initState();
    _backgroundColor = _defaultSurfaceColor(context);
    _dominantColor = _defaultSurfaceColor(context);
    _lastBrightness = Theme.of(context).brightness;
    _extractColor();
    _triggerPreload();
  }

  /// 进入详情页即按规范流程预热真实播放流（受「预加载」开关控制，fire-and-forget）。
  /// 非可直接播放条目（如剧集 / 季根）会在服务内部自动 no-op。
  void _triggerPreload() {
    if (!ref.read(preloadEnabledProvider)) return;
    final ApiClientFactory api;
    try {
      api = ref.read(apiClientProvider);
    } catch (_) {
      return; // 未连接服务器
    }
    PreloadService.instance.preloadItem(
      api: api,
      itemId: widget.itemId,
      enabled: true,
      preferredMediaSourceId: ref.read(selectedMediaSourceProvider),
      versionRegex: ref.read(preferredVersionRegexProvider),
      strmDirectPlay: ref.read(strmDirectPlayProvider),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_lastBrightness == brightness) {
      return;
    }

    _lastBrightness = brightness;
    _backgroundColor = _extractedBackgroundColor != null
        ? _blendWithThemeSurface(_extractedBackgroundColor!)
        : _defaultSurfaceColor(context);
    if (_extractedBackgroundColor == null) {
      _dominantColor = _defaultSurfaceColor(context);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isDarkTheme => Theme.of(context).brightness == Brightness.dark;

  Color _defaultSurfaceColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _isDarkTheme
        ? colorScheme.surface
        : colorScheme.surfaceContainerLowest;
  }

  Color _blendWithThemeSurface(Color extracted) {
    final baseSurface = _defaultSurfaceColor(context);
    final blendRatio = _isDarkTheme ? 0.72 : 0.18;
    return Color.lerp(baseSurface, extracted, blendRatio) ?? extracted;
  }

  String get _seriesContextId {
    if (widget.item.type == 'Season') {
      return widget.item.seriesId ?? widget.item.parentId ?? widget.itemId;
    }
    return widget.itemId;
  }

  Future<void> _extractColor() async {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemLandscapeImageUrls(
      api,
      widget.item,
      maxWidth: 1920,
    );
    final imageUrl = imageUrls.isNotEmpty ? imageUrls.first : null;

    if (imageUrl == null) return;

    final colors = await ColorExtractor.extractFromUrl(imageUrl);
    if (mounted) {
      setState(() {
        _dominantColor = colors.gradientStart;
        _extractedBackgroundColor = colors.background;
        _backgroundColor = _blendWithThemeSurface(colors.background);
        _primaryColor = colors.primary;
      });
    }
  }

  void _handleRefresh() {
    ref.invalidate(mediaItemProvider(widget.itemId));
    ref.invalidate(seasonsProvider(_seriesContextId));
    ref.invalidate(episodesProvider((
      seriesId: _seriesContextId,
      seasonId: widget.item.type == 'Season' ? widget.itemId : null,
    )));
    ref.invalidate(similarItemsProvider(widget.itemId));
  }

  void _handleRematch() async {
    final confirmed = await showDesktopConfirm(
      context,
      title: '重新匹配',
      message: '这将重新获取该媒体的元数据，是否继续？',
      confirmText: '继续',
    );

    if (confirmed) {
      try {
        // TODO: 调用 Emby 刷新元数据 API
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          _handleRefresh();
          showDesktopMessage(context, '已开始重新匹配');
        }
      } catch (e) {
        if (mounted) {
          showDesktopMessage(context, '重新匹配失败: $e', isError: true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleFactor = (screenWidth / 1440.0).clamp(0.7, 1.3);
    final theme = Theme.of(context);

    // 响应式内边距
    final horizontalPadding = screenWidth > 1600
        ? 48.0
        : screenWidth > 1200
            ? 32.0
            : 24.0;

    // 基准尺寸（基于1440px设计稿）
    const basePosterHeight = 320.0;
    final posterHeight = basePosterHeight * scaleFactor;
    final posterWidth = posterHeight * (2 / 3);
    const overlap = 48.0;
    // 顶部为返回/刷新工具栏预留的高度（按钮 40 + 上下留白），随缩放线性变化。
    // 海报顶部 = heroHeight + overlap - posterHeight = topToolbarReserve，
    // 因此始终落在工具栏下方，小窗时也不会遮挡按钮。
    final topToolbarReserve = 72.0 * scaleFactor;
    // 海报底部仍向下溢出 overlap 融入内容区；hero 高度 = 顶部预留 + 海报可见高度。
    final heroHeight = topToolbarReserve + posterHeight - overlap;
    const contentMaxWidth = 1440.0;

    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: _backgroundColor,
      ),
      child: Scaffold(
        backgroundColor: _backgroundColor,
        body: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (context.canPop()) context.pop();
            },
          },
          child: Focus(
            autofocus: true,
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                // Hero 区域
                SliverToBoxAdapter(
                  child: _HeroSection(
                    item: widget.item,
                    itemId: widget.itemId,
                    backgroundColor: _backgroundColor,
                    dominantColor: _dominantColor,
                    heroHeight: heroHeight,
                    posterHeight: posterHeight,
                    posterWidth: posterWidth,
                    overlap: overlap,
                    horizontalPadding: horizontalPadding,
                    contentMaxWidth: contentMaxWidth,
                    onRefresh: _handleRefresh,
                    onRematch: _handleRematch,
                    scaleFactor: scaleFactor,
                  ),
                ),

                // 内容区
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: contentMaxWidth),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontalPadding,
                        ),
                        child: _InfoSection(
                          item: widget.item,
                          itemId: widget.itemId,
                          backgroundColor: _backgroundColor,
                          primaryColor: _primaryColor,
                          posterWidth: posterWidth,
                          overlap: overlap,
                          scaleFactor: scaleFactor,
                        ),
                      ),
                    ),
                  ),
                ),

                // 底部安全区域
                const SliverPadding(padding: EdgeInsets.only(bottom: 64)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _detailUsesDarkTheme(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark;
}

Color _detailSurface(BuildContext context, {double level = 0.0}) {
  final colorScheme = Theme.of(context).colorScheme;
  final base = _detailUsesDarkTheme(context)
      ? colorScheme.surface
      : colorScheme.surfaceContainerLowest;
  final elevated = _detailUsesDarkTheme(context)
      ? colorScheme.surfaceContainerHighest
      : colorScheme.surfaceContainerHigh;
  return Color.lerp(base, elevated, level.clamp(0.0, 1.0)) ?? base;
}

Color _detailCardSurface(
  BuildContext context, {
  bool hovered = false,
  bool selected = false,
}) {
  final level = selected
      ? 0.76
      : hovered
          ? 0.62
          : 0.46;
  return _detailSurface(context, level: level);
}

Color _detailPlaceholderSurface(BuildContext context) {
  return _detailSurface(context, level: 0.54);
}

Color _detailPrimaryText(BuildContext context) {
  return Theme.of(context).colorScheme.onSurface;
}

Color _detailSecondaryText(BuildContext context) {
  return Theme.of(context).colorScheme.onSurfaceVariant;
}

Color _detailHintText(BuildContext context) {
  return _detailSecondaryText(context).withValues(
    alpha: _detailUsesDarkTheme(context) ? 0.76 : 0.88,
  );
}

Color _detailBorder(BuildContext context, {double emphasis = 0.0}) {
  final base = Theme.of(context).colorScheme.outlineVariant;
  final alpha = _detailUsesDarkTheme(context)
      ? 0.18 + (emphasis * 0.18)
      : 0.32 + (emphasis * 0.14);
  return base.withValues(alpha: alpha.clamp(0.0, 1.0));
}

Color _detailShadow(BuildContext context, {double opacity = 0.18}) {
  final colorScheme = Theme.of(context).colorScheme;
  final base =
      _detailUsesDarkTheme(context) ? Colors.black : colorScheme.shadow;
  final alpha = _detailUsesDarkTheme(context) ? opacity + 0.14 : opacity;
  return base.withValues(alpha: alpha.clamp(0.0, 1.0));
}

Color _detailImageOverlay(
  BuildContext context, {
  double darkAlpha = 0.30,
  double lightAlpha = 0.22,
}) {
  final overlayBase =
      _detailUsesDarkTheme(context) ? Colors.black : Colors.white;
  return overlayBase.withValues(
    alpha: _detailUsesDarkTheme(context) ? darkAlpha : lightAlpha,
  );
}

Color _heroTitleColor(Color background) {
  return readableTextColorForBackground(background);
}

Color _heroSecondaryColor(Color background) {
  return readableSecondaryTextColorForBackground(background);
}

Color _heroShadowColor(Color background) {
  final textColor = _heroTitleColor(background);
  final isLightText = textColor.computeLuminance() > 0.5;
  return (isLightText ? Colors.black : Colors.white).withValues(
    alpha: isLightText ? 0.30 : 0.18,
  );
}

Color _heroChipColor(Color background) {
  final textColor = _heroTitleColor(background);
  return textColor.withValues(
    alpha: textColor.computeLuminance() > 0.5 ? 0.18 : 0.12,
  );
}

// ============================================================================
// Hero 区域
// ============================================================================
