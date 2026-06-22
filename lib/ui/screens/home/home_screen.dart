import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/utils/color_extractor.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';
import '../../utils/image_size_helper.dart';
import '../../widgets/common/dynamic_background.dart';
import '../../widgets/common/media_widgets.dart';

/// 首页构建性能优化
///
/// 减少首次构建开销的策略：
/// 1. 使用 RepaintBoundary 隔离复杂区域的重绘
/// 2. 延迟加载非首屏内容（通过 Visibility 或 Future.delayed）
/// 3. 降低轮播图图片分辨率

/// 首页
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  double _appBarOpacity = 1.0;
  double _lastScrollOffset = 0.0;
  // 轮播图提取的沉浸色，仅在深色模式下作为整页背景使用。
  Color _carouselColor = const Color(0xFF121212);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final delta = offset - _lastScrollOffset;

    // 使用微任务避免setState过于频繁导致掉帧
    if (delta.abs() > 2) {
      setState(() {
        if (delta > 0) {
          _appBarOpacity = (_appBarOpacity - delta / 100).clamp(0.0, 1.0);
        } else if (delta < 0) {
          _appBarOpacity = (_appBarOpacity - delta / 100).clamp(0.0, 1.0);
        }
      });
    }

    _lastScrollOffset = offset;
  }

  void _onBackgroundColorChanged(Color color) {
    if (_carouselColor != color) {
      setState(() {
        _carouselColor = color;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currentServer = ref.watch(currentServerProvider);
    final hideDailyRecommendations =
        ref.watch(hideDailyRecommendationsProvider);
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);

    final brightness = Theme.of(context).brightness;
    final themeBg = Theme.of(context).scaffoldBackgroundColor;
    final wallpaperPath = ref.watch(customWallpaperPathProvider);
    final hasWallpaper = wallpaperPath.isNotEmpty;
    // 跟随取色：深色模式用提取的深色沉浸色；浅色模式用提取的浅色系沉浸色，
    // 但取色未就绪（仍是深色默认值）时退回浅色主题背景，避免浅色模式闪一下深色。
    final carouselIsLight = _carouselColor.computeLuminance() >= 0.5;
    final pageBg = brightness == Brightness.dark
        ? _carouselColor
        : (carouselIsLight ? _carouselColor : themeBg);
    // 壁纸场景：scrim 基色决定前景文字明暗（深色模式黑底浅字、浅色模式白底深字）。
    final scrimBase =
        brightness == Brightness.dark ? Colors.black : Colors.white;
    // 轮播底部渐变要淡出到“它下方实际的背景色”，避免出现一条突兀的色带。
    final carouselFade = hasWallpaper
        ? scrimBase
        : (brightness == Brightness.light ? themeBg : null);

    return Scaffold(
      backgroundColor: hasWallpaper ? scrimBase : pageBg,
      body: Stack(
        children: [
          if (hasWallpaper)
            Positioned.fill(
              child: Image.file(
                File(wallpaperPath),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          if (hasWallpaper)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        scrimBase.withValues(alpha: 0.30),
                        scrimBase.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: DynamicBackground(
            backgroundColor: hasWallpaper ? scrimBase : pageBg,
            opaque: !hasWallpaper,
            child: Stack(
              children: [
                CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    // 随机推荐轮播（可被隐藏）- 直接顶到最上方
                    if (!hideDailyRecommendations)
                      SliverToBoxAdapter(
                        child: RandomRecommendationCarousel(
                          onColorChanged: _onBackgroundColorChanged,
                          fadeToColor: carouselFade,
                        ),
                      ),

                // 继续观看
                const SliverToBoxAdapter(child: ContinueWatchingSection()),

                // 媒体库
                const SliverToBoxAdapter(child: LibrariesSection()),

                // 各媒体库最新内容
                const SliverToBoxAdapter(child: LatestItemsSections()),

                const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
              ],
            ),
            // 顶部栏（悬浮，透明背景）
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _appBarOpacity,
                duration: const Duration(milliseconds: 150),
                child: _HomeAppBar(
                  serverName: currentServer?.name ?? '服务器',
                  backgroundImage: recommendationsAsync.when(
                    data: (items) => items.isNotEmpty ? items.first : null,
                    loading: () => null,
                    error: (_, __) => null,
                  ),
                ),
              ),
            ),
          ],
        ),
            ),
          ),
          ],
        ),
    );
  }
}

/// 服务器选择器覆盖层（带动画和透明效果）
class _ServerSelectorOverlay extends StatefulWidget {
  final List<ServerConfig> servers;
  final Offset buttonPosition;
  final Size buttonSize;
  final double screenWidth;
  final double screenHeight;
  final VoidCallback onDismiss;

  const _ServerSelectorOverlay({
    required this.servers,
    required this.buttonPosition,
    required this.buttonSize,
    required this.screenWidth,
    required this.screenHeight,
    required this.onDismiss,
  });

  @override
  State<_ServerSelectorOverlay> createState() => _ServerSelectorOverlayState();
}

class _ServerSelectorOverlayState extends State<_ServerSelectorOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _dismiss() {
    _animationController.reverse().then((_) {
      widget.onDismiss();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 计算最大文本宽度：基于最长服务器名字
    final maxTextWidth = widget.servers
        .map((s) => s.name.length * 16.0) // 估计每个字符16px
        .reduce((a, b) => a > b ? a : b);
    final containerWidth =
        (56 + maxTextWidth + 48).clamp(180.0, widget.screenWidth * 0.7);

    return GestureDetector(
      onTap: _dismiss,
      child: AnimatedBuilder(
        animation: _fadeAnimation,
        builder: (context, child) {
          return Container(
            color: Colors.transparent,
            child: child,
          );
        },
        child: Stack(
          children: [
            Positioned(
              left: widget.buttonPosition.dx,
              top: widget.buttonPosition.dy + widget.buttonSize.height,
              child: SlideTransition(
                position: _slideAnimation,
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final currentServerId =
                          ref.watch(currentServerProvider)?.id;
                      final theme = Theme.of(context);
                      return Container(
                        width: containerWidth,
                        decoration: BoxDecoration(
                          // 用主题表面色，浅/深模式下都与文字对比清晰（原为透明 →
                          // 写死黑字在深色模式不可见）。
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: widget.servers.length,
                            itemBuilder: (context, index) {
                              final server = widget.servers[index];
                              final isCurrent = server.id == currentServerId;
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () {
                                    _dismiss();
                                    Future.delayed(
                                        const Duration(milliseconds: 150), () {
                                      ref
                                          .read(currentServerProvider.notifier)
                                          .state = server;
                                      if (server.authToken != null) {
                                        ref
                                            .read(authStateProvider.notifier)
                                            .state = AuthState.authenticated;
                                      }
                                      ref.invalidate(librariesProvider);
                                      ref.invalidate(resumeItemsProvider);
                                      ref.invalidate(
                                          randomRecommendationsProvider);
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF5B8DEF)
                                                .withValues(alpha: 0.1),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: server.iconUrl != null
                                              ? ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: MediaImage(
                                                    imageUrl: server.iconUrl,
                                                    width: 32,
                                                    height: 32,
                                                    fit: BoxFit.cover,
                                                    useDefaultUserAgent: true,
                                                  ),
                                                )
                                              : const Icon(
                                                  Icons.dns,
                                                  size: 16,
                                                  color: Color(0xFF5B8DEF),
                                                ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            server.name,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: isCurrent
                                                  ? const Color(0xFF5B8DEF)
                                                  : Theme.of(context)
                                                      .colorScheme
                                                      .onSurface,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (isCurrent)
                                          const Icon(
                                            Icons.check_circle,
                                            color: Color(0xFF5B8DEF),
                                            size: 18,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 首页顶部栏
class _HomeAppBar extends ConsumerStatefulWidget {
  final String serverName;
  final MediaItem? backgroundImage;

  const _HomeAppBar({required this.serverName, this.backgroundImage});

  @override
  ConsumerState<_HomeAppBar> createState() => _HomeAppBarState();
}

class _HomeAppBarState extends ConsumerState<_HomeAppBar> {
  OverlayEntry? _serverMenuOverlay;
  final GlobalKey _serverButtonKey = GlobalKey();

  void _showServerSelector() {
    final servers = ref.read(serverListProvider);
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无服务器')),
      );
      return;
    }

    _hideServerMenu();

    final renderBox =
        _serverButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final size = renderBox.size;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    _serverMenuOverlay = OverlayEntry(
      builder: (context) => _ServerSelectorOverlay(
        servers: servers,
        buttonPosition: position,
        buttonSize: size,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        onDismiss: _hideServerMenu,
      ),
    );

    Overlay.of(context).insert(_serverMenuOverlay!);
  }

  void _hideServerMenu() {
    _serverMenuOverlay?.remove();
    _serverMenuOverlay = null;
  }

  void _navigateToServerManagement() {
    HapticFeedback.mediumImpact();
    context.go('/');
  }

  @override
  void deactivate() {
    _hideServerMenu();
    super.deactivate();
  }

  @override
  void dispose() {
    _hideServerMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentServer = ref.watch(currentServerProvider);

    return SafeArea(
      child: Container(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // 服务器名称（可点击切换）
              GestureDetector(
                key: _serverButtonKey,
                onTap: _showServerSelector,
                onLongPress: _navigateToServerManagement,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFF5B8DEF).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: currentServer?.iconUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: MediaImage(
                                imageUrl: currentServer!.iconUrl,
                                width: 32,
                                height: 32,
                                fit: BoxFit.cover,
                                useDefaultUserAgent: true,
                              ),
                            )
                          : const Icon(Icons.dns,
                              size: 18, color: Color(0xFF5B8DEF)),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.serverName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.keyboard_arrow_down,
                        size: 20, color: Colors.grey),
                  ],
                ),
              ),
              const Spacer(),
              // 媒体库按钮
              IconButton(
                icon: const Icon(Icons.collections_bookmark),
                onPressed: () {
                  context.push('/libraries');
                },
              ),
              // 搜索按钮
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () {
                  context.push('/search');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 随机推荐轮播
class RandomRecommendationCarousel extends ConsumerStatefulWidget {
  final ValueChanged<Color>? onColorChanged;

  /// 轮播底部渐变淡出到的颜色（覆盖内部提取色），用于让轮播无缝融入下方页面背景。
  /// 浅色模式/壁纸场景由首页传入；深色沉浸场景传 null 走提取色。
  final Color? fadeToColor;

  const RandomRecommendationCarousel({
    super.key,
    this.onColorChanged,
    this.fadeToColor,
  });

  @override
  ConsumerState<RandomRecommendationCarousel> createState() =>
      _RandomRecommendationCarouselState();
}

class _RandomRecommendationCarouselState
    extends ConsumerState<RandomRecommendationCarousel> {
  PageController? _pageController;
  int _currentPage = 0;
  Color _dominantColor = Colors.transparent;
  Color _backgroundColor = const Color(0xFF121212);
  String? _itemsSignature;
  int _colorPrefetchToken = 0;
  // 颜色缓存：itemId -> ExtractedColors
  final Map<String, ExtractedColors> _colorCache = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _colorPrefetchToken++;
    _colorCache.clear();
    _pageController?.dispose();
    _pageController = null;
    super.dispose();
  }

  /// 只预取当前页附近的颜色，避免离开首页后仍有大量任务排队。
  Future<void> _precacheColors(List<MediaItem> items, int centerIndex) async {
    if (items.isEmpty) return;

    final api = ref.read(apiClientProvider);
    final int sessionId = ++_colorPrefetchToken;
    final int safeIndex = centerIndex.clamp(0, items.length - 1);

    for (final index in _buildPrefetchIndexes(safeIndex, items.length)) {
      if (!mounted || sessionId != _colorPrefetchToken) return;

      final item = items[index];
      // 后台预热相邻页的背景图 + Logo 艺术字，避免滑到该页才加载导致的“不同步”。
      _precacheCarouselImages(item);
      if (!_colorCache.containsKey(item.id)) {
        // 用与展示一致的背景图取色，避免色彩与画面不匹配。
        final imageUrl = _carouselBackgroundUrl(api, item);

        if (imageUrl != null) {
          await _extractColorForItem(item.id, imageUrl, sessionId);
        }
      }

      if (index == safeIndex && mounted && sessionId == _colorPrefetchToken) {
        _applyColorForItem(item);
      }

      if (!mounted || sessionId != _colorPrefetchToken) return;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  List<int> _buildPrefetchIndexes(int centerIndex, int itemCount) {
    final indexes = <int>[];

    void addIndex(int index) {
      if (index >= 0 && index < itemCount && !indexes.contains(index)) {
        indexes.add(index);
      }
    }

    addIndex(centerIndex);
    addIndex(centerIndex + 1);
    addIndex(centerIndex - 1);
    return indexes;
  }

  /// 预热轮播图片：背景图写入磁盘缓存、Logo 写入内存图缓存，
  /// 让相邻页在滑到之前就准备好，消除“跳到该页才加载”的不同步。
  void _precacheCarouselImages(MediaItem item) {
    if (!mounted) return;
    final api = ref.read(apiClientProvider);

    final bgUrl = _carouselBackgroundUrl(api, item);
    if (bgUrl != null) {
      // 与 _CarouselItem 的 MediaImage 同源（PersistentNetworkImageProvider）
      warmPersistentImageCache(context, [bgUrl]);
    }

    final logoUrl = _carouselLogoUrl(api, item);
    if (logoUrl != null && logoUrl.isNotEmpty) {
      // Logo 走 Image.network，预热 Flutter 内存图缓存
      precacheImage(NetworkImage(logoUrl), context).catchError((_) {});
    }
  }

  Future<void> _extractColorForItem(
    String itemId,
    String imageUrl,
    int sessionId,
  ) async {
    try {
      final brightness =
          mounted ? Theme.of(context).brightness : Brightness.dark;
      final colors = await ColorExtractor.extractFromUrl(
        imageUrl,
        brightness: brightness,
      );
      if (mounted && sessionId == _colorPrefetchToken) {
        _colorCache[itemId] = colors;
      }
    } catch (e) {
      // 颜色提取失败不影响图片显示
      debugPrint('Color extraction failed for $itemId: $e');
    }
  }

  void _applyColorForItem(MediaItem item) {
    if (_colorCache.containsKey(item.id)) {
      final colors = _colorCache[item.id]!;
      if (mounted) {
        setState(() {
          _dominantColor = colors.gradientStart;
          _backgroundColor = colors.background;
        });
        widget.onColorChanged?.call(colors.background);
      }
    }
  }

  void _onPageChanged(int index, List<MediaItem> items) {
    if (_currentPage != index) {
      setState(() {
        _currentPage = index;
      });
    }

    if (index < items.length) {
      _applyColorForItem(items[index]);
      _precacheColors(items, index);
    }
  }

  void _syncColorExtraction(List<MediaItem> items) {
    if (items.isEmpty) return;

    final signature = items.map((item) => item.id).join('|');
    if (_itemsSignature == signature) return;

    _itemsSignature = signature;
    _currentPage = 0;
    _dominantColor = Colors.transparent;
    _backgroundColor = const Color(0xFF121212);
    _colorCache.clear();
    _colorPrefetchToken++;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _pageController;
      if (controller != null && controller.hasClients) {
        controller.jumpToPage(0);
      }
      _precacheColors(items, 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final recommendationsAsync = ref.watch(randomRecommendationsProvider);
    final screenHeight = MediaQuery.of(context).size.height;
    // 降低轮播图高度以减少渲染开销
    final carouselHeight = screenHeight * 0.55;

    return recommendationsAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();

        _syncColorExtraction(items);

        final currentPage = _currentPage.clamp(0, items.length - 1);
        if (_currentPage != currentPage) {
          _currentPage = currentPage;
        }

        final controller = _pageController;
        if (controller == null) return const SizedBox.shrink();

        return SizedBox(
          height: carouselHeight,
          child: Stack(
            children: [
              // 轮播内容
              PageView.builder(
                controller: controller,
                itemCount: items.length,
                allowImplicitScrolling: false,
                physics: const ClampingScrollPhysics(),
                onPageChanged: (index) => _onPageChanged(index, items),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return RepaintBoundary(
                    child: _CarouselItem(
                      item: item,
                      dominantColor: _dominantColor,
                      backgroundColor: widget.fadeToColor ?? _backgroundColor,
                      onTap: () => context.push(mediaRouteForItem(item)),
                    ),
                  );
                },
              ),

              // 指示器
              Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(items.length, (index) {
                    return Container(
                      width: index == currentPage ? 20 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: index == currentPage
                            ? const Color(0xFF5B8DEF)
                            : Colors.white.withValues(alpha: 0.5),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        );
      },
      loading: () => SizedBox(
        height: carouselHeight,
        child: const AppLoadingIndicator(),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

/// 轮播背景图 URL（优先真正的 Backdrop，回退封面）。
/// 渲染与预加载共用同一函数，确保预热的 URL 与实际请求完全一致。
String? _carouselBackgroundUrl(ApiClientFactory api, MediaItem item) {
  if (item.backdropImageTag != null) {
    return api.image.getBackdropImageUrl(
      item.backdropItemId ?? item.id,
      tag: item.backdropImageTag,
      maxWidth: 720,
    );
  }
  if (item.primaryImageTag != null) {
    return api.image.getPrimaryImageUrl(
      item.id,
      tag: item.primaryImageTag,
      maxWidth: 720,
    );
  }
  return null;
}

/// 轮播 Logo 艺术字 URL。
String? _carouselLogoUrl(ApiClientFactory api, MediaItem item) {
  if (item.logoItemId != null && item.logoImageTag != null) {
    return api.image.getLogoImageUrl(
      item.logoItemId!,
      tag: item.logoImageTag,
      maxWidth: 280,
    );
  }
  return null;
}

class _CarouselItem extends ConsumerWidget {
  final MediaItem item;
  final VoidCallback onTap;
  final Color dominantColor;
  final Color backgroundColor;

  const _CarouselItem({
    required this.item,
    required this.onTap,
    required this.dominantColor,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrl = _carouselBackgroundUrl(api, item);
    // 底部信息落在「渐变→海报主色」上，前景色按主色亮度自适配（深底浅字、
    // 浅底深字），保证浅色海报下也清晰。
    final fg = readableTextColorForBackground(backgroundColor);
    final shadowColor = fg.computeLuminance() > 0.5
        ? Colors.black.withValues(alpha: 0.5)
        : Colors.white.withValues(alpha: 0.5);

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaImage(
            imageUrl: imageUrl,
            width: double.infinity,
            height: double.infinity,
          ),

          // 顶部渐变遮罩（确保顶栏文字可见）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black54,
                  ],
                ),
              ),
            ),
          ),

          // 底部渐变遮罩（平滑过渡到背景色，消除细线）
          Positioned(
            bottom: -1, // 向下延伸1像素消除细线
            left: 0,
            right: 0,
            height: 340,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    dominantColor.withValues(alpha: 0.3),
                    dominantColor.withValues(alpha: 0.7),
                    backgroundColor.withValues(alpha: 0.95),
                    backgroundColor,
                    backgroundColor,
                  ],
                  stops: const [0.0, 0.35, 0.55, 0.75, 0.9, 0.98, 1.0],
                ),
              ),
            ),
          ),

          // 底部信息
          Positioned(
            bottom: 40,
            left: 16,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLogoOrTitle(item, api, fg, shadowColor),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (item.communityRating != null) ...[
                      const Icon(Icons.star, size: 18, color: Colors.amber),
                      const SizedBox(width: 4),
                      Text(
                        item.communityRating!.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: fg,
                          shadows: [
                            Shadow(blurRadius: 4, color: shadowColor)
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    ...?item.genres?.take(5).map((genre) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: fg.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              genre,
                              style: TextStyle(fontSize: 12, color: fg),
                            ),
                          ),
                        )),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 优先使用 Logo 艺术字图片，无 Logo 时回退到文字标题
  Widget _buildLogoOrTitle(
      MediaItem item, ApiClientFactory api, Color fg, Color shadowColor) {
    final logoUrl = _carouselLogoUrl(api, item);

    if (logoUrl != null && logoUrl.isNotEmpty) {
      return Image.network(
        logoUrl,
        height: 48,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorBuilder: (_, __, ___) => _buildTitleText(item.name, fg, shadowColor),
        frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return _buildTitleText(item.name, fg, shadowColor);
        },
      );
    }
    return _buildTitleText(item.name, fg, shadowColor);
  }

  Widget _buildTitleText(String title, Color fg, Color shadowColor) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        color: fg,
        shadows: [
          Shadow(blurRadius: 8, color: shadowColor),
        ],
      ),
    );
  }
}

class ContinueWatchingSection extends ConsumerWidget {
  const ContinueWatchingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumeAsync = ref.watch(resumeItemsProvider);

    return resumeAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();

        // 智能分析图片尺寸偏好
        final sizePreference = ImageSizeHelper.analyzeForResumeSection(items);
        final unplayedItems =
            items.where((item) => !(item.userData?.played ?? false)).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: '继续观看',
              onMoreTap: () => _showContinueWatchingSheet(context, ref),
            ),
            HorizontalList(
              height: sizePreference.height + 50, // 高度 + 标题区域
              children: unplayedItems.asMap().entries.map((entry) {
                return ContinueWatchingCard(
                  item: entry.value,
                  sizePreference: sizePreference,
                ).appEntrance(index: entry.key);
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  void _showContinueWatchingSheet(BuildContext context, WidgetRef ref) {
    // 直接导航到继续观看列表页，而不使用 ModalBottomSheet
    context.push('/resume');
  }
}

/// 公开的继续观看卡片，供其他页面使用
class ContinueWatchingCard extends ConsumerWidget {
  final MediaItem item;
  final ImageSizePreference sizePreference;

  const ContinueWatchingCard({
    super.key,
    required this.item,
    required this.sizePreference,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemImageUrls(
      api,
      item,
      maxWidth: 400,
      preferThumb: true,
    );

    final isEpisode = item.type == 'Episode';
    // 第一行显示剧名称，第二行显示具体季/集；非剧集回退为条目名。
    final titleText = isEpisode
        ? (item.seriesName?.trim().isNotEmpty == true
            ? item.seriesName!
            : item.name)
        : item.name;
    final seasonEpisodeText =
        isEpisode && item.parentIndexNumber != null && item.indexNumber != null
            ? 'S${item.parentIndexNumber} · E${item.indexNumber}'
            : null;

    return GestureDetector(
      onTap: () {
        context.push(mediaRouteForItem(item));
      },
      onLongPress: () => _showLongPressMenu(context, ref),
      child: SizedBox(
        width: sizePreference.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面图 + 进度条（使用智能统一的纵横比）
            AspectRatio(
              aspectRatio: sizePreference.aspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaImage(
                      imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                      imageUrls:
                          imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                      width: sizePreference.width,
                      height: sizePreference.height,
                      cacheWidth: (sizePreference.width * 2).toInt(),
                      cacheHeight: (sizePreference.height * 2).toInt(),
                      fit: BoxFit.cover, // 使用 cover 填满容器
                    ),
                    // 底部渐变（增强进度条可读性）
                    if (item.progress != null)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: 24,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.6),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // 进度条
                    if (item.progress != null)
                      Positioned(
                        bottom: 6,
                        left: 8,
                        right: 8,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: item.progress,
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.3),
                            valueColor:
                                const AlwaysStoppedAnimation(Color(0xFF5B8DEF)),
                            minHeight: 3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 第一行：剧名称
            Text(
              titleText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            // 第二行：季/集信息
            if (seasonEpisodeText != null)
              Text(
                seasonEpisodeText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showLongPressMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('从继续观看中移除'),
              onTap: () {
                Navigator.pop(context);
                _removeFromContinueWatching(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite_border),
              title: const Text('添加到收藏'),
              onTap: () {
                Navigator.pop(context);
                _addToFavorites(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('标记为已播放'),
              onTap: () {
                Navigator.pop(context);
                _markAsPlayed(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _removeFromContinueWatching(BuildContext context, WidgetRef ref) {
    // 通过API标记为未播放来移除继续观看记录
    _showConfirmDialog(
      context,
      title: '移除记录',
      content: '确定要从继续观看中移除 "${item.name}" 吗？',
      onConfirm: () async {
        try {
          final api = ref.read(apiClientProvider);
          await api.user.markAsUnplayed(item.id);
          ref.invalidate(resumeItemsProvider);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已移除')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('移除失败: $e')),
            );
          }
        }
      },
    );
  }

  void _addToFavorites(BuildContext context, WidgetRef ref) {
    _showConfirmDialog(
      context,
      title: '添加到收藏',
      content: '将 "${item.name}" 添加到收藏？',
      onConfirm: () async {
        try {
          final api = ref.read(apiClientProvider);
          await api.favorite.addFavorite(item.id);
          refreshFavorites(ref);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已添加到收藏')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('添加失败: $e')),
            );
          }
        }
      },
    );
  }

  void _markAsPlayed(BuildContext context, WidgetRef ref) {
    _showConfirmDialog(
      context,
      title: '标记为已播放',
      content: '将 "${item.name}" 标记为已播放？',
      onConfirm: () async {
        try {
          final api = ref.read(apiClientProvider);
          await api.user.markAsPlayed(item.id);
          ref.invalidate(resumeItemsProvider);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已标记为已播放')),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('标记失败: $e')),
            );
          }
        }
      },
    );
  }

  void _showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              onConfirm();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 媒体库区块
class LibrariesSection extends ConsumerWidget {
  const LibrariesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final librariesAsync = ref.watch(librariesProvider);

    return librariesAsync.when(
      data: (libraries) {
        if (libraries.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '媒体库',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.push('/libraries'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '查看全部',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            HorizontalList(
              height: 172,
              spacing: 10,
              children: libraries.asMap().entries.map((entry) {
                return SizedBox(
                  width: 160,
                  child: _LibraryCard(library: entry.value),
                ).appEntrance(index: entry.key);
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _LibraryCard extends ConsumerWidget {
  final Library library;

  const _LibraryCard({required this.library});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveLibraryImageUrls(api, library, maxWidth: 400);
    const borderRadius = BorderRadius.all(Radius.circular(16));

    return GestureDetector(
      onTap: () => context.push('/library/${library.id}'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: borderRadius,
            // 封面 cover 填满整张卡片，去掉旧版 contain 留下的彩色底/留白。
            child: SizedBox(
              width: 160,
              height: 118,
              child: imageUrls.isNotEmpty
                  ? MediaImage(
                      imageUrl: imageUrls.first,
                      imageUrls:
                          imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                      width: 160,
                      height: 118,
                      fit: BoxFit.cover,
                      borderRadius: borderRadius,
                    )
                  : Container(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.12),
                      child: const Center(
                        child: Icon(
                          Icons.folder,
                          size: 34,
                          color: Color(0xFF5B8DEF),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 160,
            child: Text(
              library.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// 各媒体库最新内容区块
class LatestItemsSections extends ConsumerWidget {
  const LatestItemsSections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final librariesAsync = ref.watch(librariesProvider);

    return librariesAsync.when(
      data: (libraries) {
        return Column(
          children: libraries.map((library) {
            return _LibraryLatestSection(library: library);
          }).toList(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _LibraryLatestSection extends ConsumerWidget {
  final Library library;

  const _LibraryLatestSection({required this.library});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latestAsync = ref.watch(latestItemsProvider(library.id));

    return latestAsync.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();

        // 智能分析图片尺寸偏好
        final sizePreference = ImageSizeHelper.analyzeForLatestSection(items);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    library.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.push('/library/${library.id}'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '查看更多',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            HorizontalList(
              height: sizePreference.height + 80, // 高度 + 标题和元数据区域
              children: items.asMap().entries.map((entry) {
                final item = entry.value;
                return SizedBox(
                  width: sizePreference.width,
                  child: MediaPoster(
                    item: item,
                    width: sizePreference.width,
                    height: sizePreference.height,
                    onTap: () => context.push(mediaRouteForItem(item)),
                  ),
                ).appEntrance(index: entry.key);
              }).toList(),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
