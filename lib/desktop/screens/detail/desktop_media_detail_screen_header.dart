part of 'desktop_media_detail_screen.dart';

class _HeroSection extends ConsumerWidget {
  final MediaItem item;
  final String itemId;
  final Color backgroundColor;
  final Color dominantColor;
  final double heroHeight;
  final double posterHeight;
  final double posterWidth;
  final double overlap;
  final double horizontalPadding;
  final double contentMaxWidth;
  final VoidCallback onRefresh;
  final VoidCallback onRematch;
  final double scaleFactor;

  const _HeroSection({
    required this.item,
    required this.itemId,
    required this.backgroundColor,
    required this.dominantColor,
    required this.heroHeight,
    required this.posterHeight,
    required this.posterWidth,
    required this.overlap,
    required this.horizontalPadding,
    required this.contentMaxWidth,
    required this.onRefresh,
    required this.onRematch,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final useVideoBackground = ref.watch(useVideoBackgroundProvider);
    final titleColor = _heroTitleColor(backgroundColor);
    final secondaryColor = _heroSecondaryColor(backgroundColor);
    final shadowColor = _heroShadowColor(backgroundColor);
    final chipColor = _heroChipColor(backgroundColor);
    final imageUrls = resolveMediaItemLandscapeImageUrls(
      api,
      item,
      maxWidth: 1920,
    );
    final posterUrls = resolveMediaItemImageUrls(
      api,
      item,
      maxWidth: 600,
    );
    final videoUrl = (useVideoBackground &&
            item.remoteTrailers != null &&
            item.remoteTrailers!.isNotEmpty)
        ? item.remoteTrailers!.first
        : null;

    return Stack(
      children: [
        // 背景图/视频
        SizedBox(
          height: heroHeight,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 底色
              Container(color: dominantColor),

              // 背景视频或图片
              if (videoUrl != null)
                VideoBackground(
                  videoUrl: videoUrl,
                  width: double.infinity,
                  height: heroHeight,
                  fit: BoxFit.cover,
                  placeholder: imageUrls.isNotEmpty
                      ? MediaImage(
                          imageUrl: imageUrls.first,
                          imageUrls: imageUrls.length > 1
                              ? imageUrls.sublist(1)
                              : null,
                          width: double.infinity,
                          height: heroHeight,
                          fit: BoxFit.cover,
                        )
                      : null,
                )
              else if (imageUrls.isNotEmpty)
                MediaImage(
                  imageUrl: imageUrls.first,
                  imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                  width: double.infinity,
                  height: heroHeight,
                  fit: BoxFit.cover,
                ),

              // 底部渐变
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      backgroundColor.withValues(alpha: 0.6),
                      backgroundColor,
                    ],
                    stops: const [0.5, 0.85, 1.0],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 海报 + 信息区
        Positioned(
          bottom: -overlap,
          left: 0,
          right: 0,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 海报
                    Container(
                      width: posterWidth,
                      height: posterHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8 * scaleFactor),
                        boxShadow: [
                          BoxShadow(
                            color: _detailShadow(context, opacity: 0.24),
                            offset: Offset(0, 4 * scaleFactor),
                            blurRadius: 16 * scaleFactor,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8 * scaleFactor),
                        child: MediaImage(
                          imageUrl:
                              posterUrls.isNotEmpty ? posterUrls.first : null,
                          width: posterWidth,
                          height: posterHeight,
                          fit: BoxFit.cover,
                          placeholder: Container(
                            color: _detailPlaceholderSurface(context),
                            child: Center(
                              child: Text(
                                item.name.isNotEmpty
                                    ? item.name.substring(0, 1)
                                    : '?',
                                style: TextStyle(
                                  fontSize: 48 * scaleFactor,
                                  fontWeight: FontWeight.bold,
                                  color: _detailHintText(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    SizedBox(width: 32 * scaleFactor),

                    // 标题信息（在海报上方一点）
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: overlap + 16 * scaleFactor,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 标题
                            Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 32 * scaleFactor,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                                color: titleColor,
                                shadows: [
                                  Shadow(blurRadius: 12, color: shadowColor),
                                ],
                              ),
                            ),
                            SizedBox(height: 10 * scaleFactor),

                            // 评分 + 标签行（用 Wrap 防止窄窗时横向溢出，自动换行）
                            Wrap(
                              spacing: 12 * scaleFactor,
                              runSpacing: 8 * scaleFactor,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (item.communityRating != null)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.star,
                                        size: 16,
                                        color: Colors.amber,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        item.communityRating!
                                            .toStringAsFixed(1),
                                        style: TextStyle(
                                          fontSize: 14 * scaleFactor,
                                          fontWeight: FontWeight.w600,
                                          color: titleColor,
                                          shadows: [
                                            Shadow(
                                              blurRadius: 4,
                                              color: shadowColor,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                if (item.productionYear != null)
                                  Text(
                                    '${item.productionYear}',
                                    style: TextStyle(
                                      fontSize: 14 * scaleFactor,
                                      color: secondaryColor,
                                      shadows: [
                                        Shadow(
                                          blurRadius: 4,
                                          color: shadowColor,
                                        ),
                                      ],
                                    ),
                                  ),
                                if ((item.formattedRuntime ?? '').isNotEmpty)
                                  Text(
                                    item.formattedRuntime!,
                                    style: TextStyle(
                                      fontSize: 14 * scaleFactor,
                                      color: secondaryColor,
                                      shadows: [
                                        Shadow(
                                          blurRadius: 4,
                                          color: shadowColor,
                                        ),
                                      ],
                                    ),
                                  ),
                                ...?item.genres?.take(4).map((genre) {
                                  return Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 8 * scaleFactor,
                                      vertical: 3 * scaleFactor,
                                    ),
                                    decoration: BoxDecoration(
                                      color: chipColor,
                                      borderRadius: BorderRadius.circular(
                                        4 * scaleFactor,
                                      ),
                                      border: Border.all(
                                        color:
                                            titleColor.withValues(alpha: 0.16),
                                      ),
                                    ),
                                    child: Text(
                                      genre,
                                      style: TextStyle(
                                        fontSize: 11 * scaleFactor,
                                        color: titleColor,
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // 顶部工具栏（返回 + 刷新）— 置于 Stack 顶层，保证任何缩放下都不被海报遮挡且可点击
        SafeArea(
          child: Padding(
            padding: EdgeInsets.all(12 * scaleFactor),
            child: Row(
              children: [
                _GlassButton(
                  icon: Icons.arrow_back,
                  onPressed: () => context.pop(),
                  scaleFactor: scaleFactor,
                ),
                SizedBox(width: 8 * scaleFactor),
                _GlassButton(
                  icon: Icons.refresh,
                  onPressed: onRefresh,
                  scaleFactor: scaleFactor,
                ),
                const Spacer(),
                // 整剧下载（仅剧集/季）
                if (item.type == 'Series' || item.type == 'Season') ...[
                  _GlassButton(
                    icon: Icons.download,
                    onPressed: () => _downloadEntireSeries(context, ref, item),
                    scaleFactor: scaleFactor,
                  ),
                  SizedBox(width: 8 * scaleFactor),
                ],
                // 窗口控制按钮占位（右侧系统按钮区域）
                SizedBox(width: 120 * scaleFactor),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 整剧下载：把全剧所有分集加入下载队列（桌面端顶部右上角入口）。
Future<void> _downloadEntireSeries(
    BuildContext context, WidgetRef ref, MediaItem series) async {
  final api = ref.read(apiClientProvider);

  final allowedByPolicy = await ref.read(downloadPermissionProvider.future);
  if (!allowedByPolicy) {
    if (context.mounted) {
      showDesktopMessage(context, '当前服务器未开放下载权限', isError: true);
    }
    return;
  }

  if (context.mounted) {
    showDesktopMessage(context, '正在解析剧集，准备下载…');
  }
  try {
    final result = await startSeriesDownload(
      api: api,
      manager: ref.read(downloadManagerProvider),
      series: series,
    );
    if (!context.mounted) return;
    showDesktopMessage(
      context,
      result.queued > 0
          ? '已加入下载 ${result.queued} 集'
              '${result.skipped > 0 ? '（${result.skipped} 集已存在）' : ''}'
          : '全部 ${result.total} 集已在下载列表',
    );
  } catch (e) {
    if (!context.mounted) return;
    showDesktopMessage(context, '整剧下载失败，请稍后重试', isError: true);
  }
}

// ============================================================================
// 毛玻璃按钮
// ============================================================================

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double scaleFactor;

  const _GlassButton({
    required this.icon,
    required this.onPressed,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context) {
    final size = 40.0 * scaleFactor;
    final surface = _detailUsesDarkTheme(context)
        ? Colors.black.withValues(alpha: 0.28)
        : Colors.white.withValues(alpha: 0.58);
    final iconColor = _detailPrimaryText(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: surface,
            shape: BoxShape.circle,
            border: Border.all(
              color: _detailBorder(context, emphasis: 0.1),
            ),
          ),
          child: IconButton(
            icon: Icon(icon, color: iconColor, size: 20 * scaleFactor),
            onPressed: onPressed,
            splashRadius: size / 2,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 右侧信息区
// ============================================================================

class _InfoSection extends ConsumerStatefulWidget {
  final MediaItem item;
  final String itemId;
  final Color backgroundColor;
  final Color primaryColor;
  final double posterWidth;
  final double overlap;
  final double scaleFactor;

  const _InfoSection({
    required this.item,
    required this.itemId,
    required this.backgroundColor,
    required this.primaryColor,
    required this.posterWidth,
    required this.overlap,
    required this.scaleFactor,
  });

  @override
  ConsumerState<_InfoSection> createState() => _InfoSectionState();
}

class _InfoSectionState extends ConsumerState<_InfoSection> {
  bool _overviewExpanded = false;
  bool _mediaInfoExpanded = false;
  bool _isGridView = true;
  String? _selectedSeasonId;

  final LayerLink _playButtonLink = LayerLink();
  final LayerLink _sourceLink = LayerLink();
  final LayerLink _audioLink = LayerLink();
  final LayerLink _subtitleLink = LayerLink();
  final LayerLink _secondarySubtitleLink = LayerLink();

  OverlayEntry? _playMenuOverlay;
  OverlayEntry? _sourceMenuOverlay;
  OverlayEntry? _audioMenuOverlay;
  OverlayEntry? _subtitleMenuOverlay;
  OverlayEntry? _secondarySubtitleMenuOverlay;
  Offset? _menuAnchorPosition;

  @override
  void dispose() {
    _hideAllOverlays();
    super.dispose();
  }

  void _rememberMenuAnchor(TapDownDetails details) {
    _menuAnchorPosition = details.globalPosition;
  }

  void _hideAllOverlays() {
    _playMenuOverlay?.remove();
    _playMenuOverlay = null;
    _sourceMenuOverlay?.remove();
    _sourceMenuOverlay = null;
    _audioMenuOverlay?.remove();
    _audioMenuOverlay = null;
    _subtitleMenuOverlay?.remove();
    _subtitleMenuOverlay = null;
    _secondarySubtitleMenuOverlay?.remove();
    _secondarySubtitleMenuOverlay = null;
  }

  void _togglePlayMenu() {
    if (_playMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    _playMenuOverlay = _createMenuOverlay(
      link: _playButtonLink,
      items: [
        _MenuItem(
          icon: Icons.play_arrow,
          label: '从头开始播放',
          onTap: () {
            _hideAllOverlays();
            ref.read(currentPlayingItemProvider.notifier).state = widget.item;
            context.push('/player/${widget.itemId}');
          },
        ),
        _MenuItem(
          icon: Icons.open_in_new,
          label: '调用外部播放器',
          onTap: () {
            _hideAllOverlays();
            _launchExternalPlayer();
          },
        ),
        _MenuItem(
          icon: Icons.download,
          label: '下载',
          onTap: () {
            _hideAllOverlays();
            _handleDownload();
          },
        ),
      ],
    );
    Overlay.of(context).insert(_playMenuOverlay!);
  }

  Future<void> _launchExternalPlayer() async {
    final externalMpvPath = ref.read(externalMpvPathProvider).trim();
    if (externalMpvPath.isEmpty) {
      showDesktopMessage(context, '请先在设置里选择外部 MPV 路径', isError: true);
      return;
    }

    final executableFile = File(externalMpvPath);
    if (!await executableFile.exists()) {
      if (!mounted) return;
      showDesktopMessage(context, '外部 MPV 路径不存在，请重新在设置中选择', isError: true);
      return;
    }

    try {
      final api = ref.read(apiClientProvider);
      final playbackInfo =
          await ref.read(playbackInfoProvider(widget.itemId).future);
      final selection = buildPlaybackSelection(
        playbackInfo: playbackInfo,
        itemId: widget.itemId,
        preferredMediaSourceId: ref.read(selectedMediaSourceProvider),
        playSessionId:
            '${widget.itemId}-${DateTime.now().microsecondsSinceEpoch}',
      );
      final mediaSource = selection.mediaSource;
      if (mediaSource == null) {
        if (!mounted) return;
        showDesktopMessage(context, '当前条目暂无可播放媒体源', isError: true);
        return;
      }

      final request = selection.primaryRequest;
      final videoUrl = api.playback.getVideoStreamUrl(
        request.itemId,
        mediaSourceId: request.mediaSourceId,
        container: request.container,
        playSessionId: request.playSessionId,
        staticStream: request.staticStream,
        allowDirectPlay: request.allowDirectPlay,
        allowDirectStream: request.allowDirectStream,
        allowTranscoding: request.allowTranscoding,
        enableAutoStreamCopy: request.enableAutoStreamCopy,
        enableAutoStreamCopyAudio: request.enableAutoStreamCopyAudio,
        enableAutoStreamCopyVideo: request.enableAutoStreamCopyVideo,
      );
      final startPositionTicks =
          (widget.item.userData?.playbackPositionTicks ?? 0).round();
      await ref.read(externalPlayerSessionServiceProvider).launchMpv(
            executablePath: externalMpvPath,
            item: widget.item,
            mediaSourceId: mediaSource.id,
            videoUrl: videoUrl,
            startPositionTicks: startPositionTicks,
            mediaSourceRunTimeTicks: mediaSource.runTimeTicks,
          );

      if (!mounted) return;
      // 取最高分辨率视频流，避免 4K 资源被排在前面的低清流误判成 1080p。
      final videoStream = mediaSource.primaryVideoStream ??
          MediaStream(index: 0, type: 'Video');
      final sourceLabel = _buildSourceDisplayName(mediaSource, videoStream);
      showDesktopMessage(context, '已调用外部播放器播放：$sourceLabel');
    } on ProcessException catch (error) {
      if (!mounted) return;
      showDesktopMessage(context, '启动外部播放器失败：${error.message}', isError: true);
    } catch (error) {
      if (!mounted) return;
      showDesktopMessage(context, '获取外部播放地址失败：$error', isError: true);
    }
  }

  Future<void> _handleDownload() async {
    final api = ref.read(apiClientProvider);
    MediaItem detail = widget.item;
    try {
      detail = await api.media.getItemDetails(widget.itemId);
    } catch (_) {}

    final allowedByPolicy =
        await ref.read(downloadPermissionProvider.future);
    final allowedByItem = detail.canDownload ?? true;
    if (!allowedByPolicy || !allowedByItem) {
      if (!mounted) return;
      showDesktopMessage(context, '当前服务器未开放下载权限', isError: true);
      return;
    }

    final task = await startMediaDownload(
      api: api,
      manager: ref.read(downloadManagerProvider),
      item: detail,
      mediaSourceIdOverride: ref.read(selectedMediaSourceProvider),
    );

    if (!mounted) return;
    showDesktopMessage(
        context, task != null ? '已添加到下载队列' : '添加下载失败',
        isError: task == null);
  }

  OverlayEntry _createMenuOverlay({
    required LayerLink link,
    required List<_MenuItem> items,
    double menuWidth = 280,
  }) {
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final anchor = _menuAnchorPosition;
    final localAnchor = overlayBox != null && anchor != null
        ? overlayBox.globalToLocal(anchor)
        : null;
    final screenSize = MediaQuery.of(context).size;
    final resolvedMenuWidth =
        menuWidth.clamp(220.0, screenSize.width - 32.0).toDouble();
    final estimatedRowHeight =
        items.any((item) => item.label.contains('\n')) ? 76.0 : 58.0;
    final estimatedMenuHeight =
        (items.length * estimatedRowHeight).clamp(120.0, 360.0);
    final left = localAnchor?.dx
        .clamp(16.0, screenSize.width - resolvedMenuWidth - 16.0)
        .toDouble();
    final top = localAnchor == null
        ? null
        : (localAnchor.dy + 8.0 + estimatedMenuHeight > screenSize.height - 16.0
                ? (localAnchor.dy - estimatedMenuHeight - 8.0)
                : (localAnchor.dy + 8.0))
            .clamp(16.0, screenSize.height - estimatedMenuHeight - 16.0)
            .toDouble();

    return OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 点击外部关闭
          Positioned.fill(
            child: GestureDetector(
              onTap: _hideAllOverlays,
              behavior: HitTestBehavior.translucent,
              child: Container(color: Colors.transparent),
            ),
          ),
          // 菜单
          if (left != null && top != null)
            Positioned(
              left: left,
              top: top,
              child: _MenuSurface(
                width: resolvedMenuWidth,
                maxHeight: estimatedMenuHeight,
                backgroundColor: widget.backgroundColor,
                items: items,
                primaryColor: widget.primaryColor,
              ),
            )
          else
            CompositedTransformFollower(
              link: link,
              showWhenUnlinked: false,
              offset: const Offset(0, 8),
              child: _MenuSurface(
                width: resolvedMenuWidth,
                maxHeight: estimatedMenuHeight,
                backgroundColor: widget.backgroundColor,
                items: items,
                primaryColor: widget.primaryColor,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _togglePlayed() async {
    final api = ref.read(apiClientProvider);
    try {
      if (widget.item.isWatched) {
        await api.user.markAsUnplayed(widget.itemId);
      } else {
        await api.user.markAsPlayed(widget.itemId);
      }
      ref.invalidate(mediaItemProvider(widget.itemId));
    } catch (e) {
      if (mounted) {
        showDesktopMessage(context, '操作失败: $e', isError: true);
      }
    }
  }

  Future<void> _toggleFavorite() async {
    final api = ref.read(apiClientProvider);
    try {
      final isFav = widget.item.userData?.isFavorite ?? false;
      if (isFav) {
        await api.favorite.removeFavorite(widget.itemId);
      } else {
        await api.favorite.addFavorite(widget.itemId);
      }
      ref.invalidate(mediaItemProvider(widget.itemId));
    } catch (e) {
      if (mounted) {
        showDesktopMessage(context, '操作失败: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final isSeries =
        widget.item.type == 'Series' || widget.item.type == 'Season';
    final selectedSeasonId =
        widget.item.type == 'Season' ? widget.itemId : _selectedSeasonId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 简介（电影：信息在顶部；剧集：下沉到集/季列表之下，让选集更靠前）
        if (!isSeries &&
            widget.item.overview != null &&
            widget.item.overview!.isNotEmpty) ...[
          _OverviewSection(
            overview: widget.item.overview!,
            expanded: _overviewExpanded,
            scaleFactor: scale,
            accentColor: widget.primaryColor,
            onToggle: () =>
                setState(() => _overviewExpanded = !_overviewExpanded),
          ),
          SizedBox(height: 24 * scale),
        ],

        // 操作按钮行
        Row(
          children: [
            _ActionButton(
              icon: widget.item.isWatched
                  ? Icons.check_circle
                  : Icons.check_circle_outline,
              label: widget.item.isWatched ? '标记为未看' : '标记为已看',
              isActive: widget.item.isWatched,
              primaryColor: widget.primaryColor,
              scaleFactor: scale,
              onPressed: _togglePlayed,
            ),
            SizedBox(width: 12 * scale),
            _ActionButton(
              icon: (widget.item.userData?.isFavorite ?? false)
                  ? Icons.favorite
                  : Icons.favorite_border,
              label: '收藏',
              isActive: widget.item.userData?.isFavorite ?? false,
              activeColor: Colors.redAccent,
              primaryColor: widget.primaryColor,
              scaleFactor: scale,
              onPressed: _toggleFavorite,
            ),
          ],
        ),
        SizedBox(height: 24 * scale),

        // 播放按钮
        CompositedTransformTarget(
          link: _playButtonLink,
          child: _PlayButton(
            item: widget.item,
            primaryColor: widget.primaryColor,
            scaleFactor: scale,
            onTap: () {
              // 继续观看或从头播放
              ref.read(currentPlayingItemProvider.notifier).state = widget.item;
              context.push('/player/${widget.itemId}');
            },
            onDropdownTapDown: _rememberMenuAnchor,
            onDropdownTap: _togglePlayMenu,
          ),
        ),

        // 当前播放提示
        if (isSeries) ...[
          SizedBox(height: 8 * scale),
          Text(
            widget.item.type == 'Season' ? '当前浏览本季剧集' : '继续浏览剧集',
            style: TextStyle(
              fontSize: 12 * scale,
              color: _detailHintText(context),
            ),
          ),
        ],

        SizedBox(height: 16 * scale),

        // 媒体源选择器（仅在电影或单集时显示，或者从 playbackInfo 获取）
        if (!isSeries) ...[
          _buildMediaSourceSelectors(scale),
          SizedBox(height: 24 * scale),
        ],

        // 分集区域（仅剧集）
        if (isSeries) ...[
          _EpisodesSection(
            seriesId: widget.item.type == 'Season'
                ? (widget.item.seriesId ??
                    widget.item.parentId ??
                    widget.itemId)
                : widget.itemId,
            selectedSeasonId: selectedSeasonId,
            primaryColor: widget.primaryColor,
            scaleFactor: scale,
            isGridView: _isGridView,
            onToggleView: () => setState(() => _isGridView = !_isGridView),
            onEpisodeTap: (episode) {
              context.push('/episode/${episode.id}');
            },
          ),
          SizedBox(height: 48 * scale),

          // 分季区域
          _SeasonsSection(
            seriesId: widget.item.type == 'Season'
                ? (widget.item.seriesId ??
                    widget.item.parentId ??
                    widget.itemId)
                : widget.itemId,
            selectedSeasonId: selectedSeasonId,
            primaryColor: widget.primaryColor,
            scaleFactor: scale,
            onSeasonTap: (season) {
              setState(() => _selectedSeasonId = season.id);
            },
          ),
          SizedBox(height: 48 * scale),
        ],

        // 简介（剧集：下沉到选集之下）
        if (isSeries &&
            widget.item.overview != null &&
            widget.item.overview!.isNotEmpty) ...[
          _OverviewSection(
            overview: widget.item.overview!,
            expanded: _overviewExpanded,
            scaleFactor: scale,
            accentColor: widget.primaryColor,
            onToggle: () =>
                setState(() => _overviewExpanded = !_overviewExpanded),
          ),
          SizedBox(height: 48 * scale),
        ],

        // 演职人员
        _CastSection(
          persons: widget.item.people ?? const [],
          primaryColor: widget.primaryColor,
          scaleFactor: scale,
        ),
        SizedBox(height: 48 * scale),

        // 相关推荐
        _RelatedSection(
          itemId: widget.itemId,
          primaryColor: widget.primaryColor,
          scaleFactor: scale,
        ),
      ],
    );
  }

  Widget _buildMediaSourceSelectors(double scale) {
    return Consumer(
      builder: (context, ref, child) {
        final playbackAsync = ref.watch(playbackInfoProvider(widget.itemId));
        final server = ref.watch(currentServerProvider);
        final selectedSourceId = ref.watch(selectedMediaSourceProvider);
        final selectedAudioIndex = ref.watch(audioTrackProvider);
        final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
        final selectedSecondarySubtitleIndex = ref.watch(
          secondarySubtitleTrackProvider,
        );

        return playbackAsync.when(
          data: (info) {
            final source = _resolveMediaSource(info, selectedSourceId);
            if (source == null) return const SizedBox.shrink();

            final audioStreams =
                source.mediaStreams.where((s) => s.isAudio).toList();
            final subtitleStreams =
                source.mediaStreams.where((s) => s.isSubtitle).toList();
            final selectedAudio = _resolveSelectedStream(
              audioStreams,
              selectedAudioIndex,
            );
            final selectedSubtitle = _resolveSelectedStream(
              subtitleStreams,
              selectedSubtitleIndex,
            );
            final secondaryCandidates = subtitleStreams
                .where(
                  (stream) =>
                      selectedSubtitle == null ||
                      stream.index != selectedSubtitle.index,
                )
                .toList();
            // 次字幕默认为「无」：不自动选默认轨，仅当用户显式选择时才解析，
            // 否则会出现“明明没选却显示选了第二条字幕”的问题。
            final selectedSecondarySubtitle =
                selectedSecondarySubtitleIndex == null
                    ? null
                    : secondaryCandidates
                        .where((s) => s.index == selectedSecondarySubtitleIndex)
                        .firstOrNull;
            final videoStream =
                source.primaryVideoStream ?? MediaStream(index: 0, type: 'Video');
            final sourceLabel = _buildSourceName(source, videoStream);
            final versionLabel = _buildVideoVersionLabel(source, videoStream);
            final fileSummary = <String>[
              sourceLabel,
              if (versionLabel.isNotEmpty && versionLabel != sourceLabel)
                versionLabel,
              if (source.size != null) _formatBytes(source.size!),
              if (_formatBitRate(source, videoStream) != null)
                _formatBitRate(source, videoStream)!,
            ].join('  ');

            _seedPlaybackSelections(
              ref,
              mediaSource: source,
              audioStreams: audioStreams,
              subtitleStreams: subtitleStreams,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _SelectorCard(
                        label: '线路',
                        value: _resolveCurrentLineName(server),
                        scaleFactor: scale,
                        onTapDown: _rememberMenuAnchor,
                        onTap: () => _showLineSelector(ref, server),
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Expanded(
                      child: CompositedTransformTarget(
                        link: _sourceLink,
                        child: _SelectorCard(
                          label: '版本',
                          value: sourceLabel,
                          tooltip: fileSummary,
                          valueMaxLines: null,
                          scaleFactor: scale,
                          onTapDown: _rememberMenuAnchor,
                          onTap: () => _toggleSourceMenu(info),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12 * scale),
                Row(
                  children: [
                    Expanded(
                      child: CompositedTransformTarget(
                        link: _audioLink,
                        child: _SelectorCard(
                          label: '音频',
                          value: selectedAudio?.readableLabel(
                                siblings: audioStreams,
                              ) ??
                              '无',
                          tooltip: selectedAudio?.readableLabel(
                                siblings: audioStreams,
                              ) ??
                              '无',
                          scaleFactor: scale,
                          onTapDown: _rememberMenuAnchor,
                          onTap: () => _toggleAudioMenu(audioStreams),
                        ),
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Expanded(
                      child: CompositedTransformTarget(
                        link: _subtitleLink,
                        child: _SelectorCard(
                          label: '字幕',
                          value: selectedSubtitle?.readableLabel(
                                siblings: subtitleStreams,
                              ) ??
                              '无',
                          tooltip: selectedSubtitle?.readableLabel(
                                siblings: subtitleStreams,
                              ) ??
                              '无',
                          scaleFactor: scale,
                          onTapDown: _rememberMenuAnchor,
                          onTap: () => _toggleSubtitleMenu(subtitleStreams),
                        ),
                      ),
                    ),
                  ],
                ),
                if (secondaryCandidates.isNotEmpty) ...[
                  SizedBox(height: 12 * scale),
                  CompositedTransformTarget(
                    link: _secondarySubtitleLink,
                    child: _SelectorCard(
                      label: '次字幕',
                      value: selectedSecondarySubtitle?.readableLabel(
                            siblings: secondaryCandidates,
                          ) ??
                          '无',
                      tooltip: selectedSecondarySubtitle?.readableLabel(
                            siblings: secondaryCandidates,
                          ) ??
                          '无',
                      scaleFactor: scale,
                      onTapDown: _rememberMenuAnchor,
                      onTap: () => _toggleSecondarySubtitleMenu(
                        secondaryCandidates,
                      ),
                    ),
                  ),
                ],

                // 文件信息
                SizedBox(height: 12 * scale),
                Text(
                  fileSummary,
                  style: TextStyle(
                    fontSize: 12 * scale,
                    color: _detailHintText(context),
                  ),
                ),

                // 查看媒体信息
                SizedBox(height: 8 * scale),
                GestureDetector(
                  onTap: () => setState(
                    () => _mediaInfoExpanded = !_mediaInfoExpanded,
                  ),
                  child: Text(
                    '查看媒体信息',
                    style: TextStyle(
                      fontSize: 13 * scale,
                      color: widget.primaryColor,
                    ),
                  ),
                ),

                // 媒体信息折叠面板
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: _mediaInfoExpanded
                      ? _MediaInfoPanel(
                          source: source,
                          versionLabel: sourceLabel,
                          scaleFactor: scale,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            );
          },
          loading: () => const SizedBox(
            height: 120,
            child: AppLoadingIndicator(),
          ),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
    );
  }

  MediaSource? _resolveMediaSource(
      PlaybackInfo info, String? selectedSourceId) {
    if (info.mediaSources.isEmpty) return null;
    if (selectedSourceId == null || selectedSourceId.isEmpty) {
      return info.mediaSources.first;
    }
    return info.mediaSources
            .where((source) => source.id == selectedSourceId)
            .firstOrNull ??
        info.mediaSources.first;
  }

  MediaStream? _resolveSelectedStream(
    List<MediaStream> streams,
    int? selectedIndex,
  ) {
    if (streams.isEmpty) return null;
    if (selectedIndex == null) {
      return streams.where((stream) => stream.isDefault == true).firstOrNull ??
          streams.first;
    }
    return streams
            .where((stream) => stream.index == selectedIndex)
            .firstOrNull ??
        streams.where((stream) => stream.isDefault == true).firstOrNull ??
        streams.first;
  }

  void _seedPlaybackSelections(
    WidgetRef ref, {
    required MediaSource mediaSource,
    required List<MediaStream> audioStreams,
    required List<MediaStream> subtitleStreams,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(selectedMediaSourceProvider) != mediaSource.id) {
        ref.read(selectedMediaSourceProvider.notifier).state = mediaSource.id;
      }
      if (ref.read(audioTrackProvider) == null) {
        final selected = _resolveSelectedStream(audioStreams, null);
        if (selected?.index != null) {
          ref.read(audioTrackProvider.notifier).state = selected!.index;
        }
      }
      if (ref.read(subtitleTrackProvider) == null) {
        final selected = _resolveSelectedStream(subtitleStreams, null);
        if (selected?.index != null) {
          ref.read(subtitleTrackProvider.notifier).state = selected!.index;
        }
      }
    });
  }

  String _resolveCurrentLineName(ServerConfig? server) {
    if (server == null || server.lines.isEmpty) {
      return '当前线路';
    }
    final index = server.activeLineIndex.clamp(0, server.lines.length - 1);
    return server.lines[index].name;
  }

  List<String> _videoVersionParts(MediaSource source, MediaStream videoStream) {
    return <String>[
      if (videoStream.resolution.isNotEmpty) videoStream.resolution,
      // 编码格式含动态范围，如 "Dolby Vision HEVC" / "HDR10 HEVC" / "H.264"。
      if (videoStream.videoFormatLabel.isNotEmpty) videoStream.videoFormatLabel,
    ];
  }

  String _buildVideoVersionLabel(MediaSource source, MediaStream videoStream) {
    return _videoVersionParts(source, videoStream).join(' ');
  }

  String _buildSourceDisplayName(MediaSource source, MediaStream videoStream) {
    final customName = source.name?.trim();
    final parts = _videoVersionParts(source, videoStream);
    if (customName != null && customName.isNotEmpty) {
      // 只补充自定义名称里没有体现的版本信息，避免出现
      // “1080p · 1080P H264 MKV”这种把同一版本拼两遍的情况。
      final lower = customName.toLowerCase();
      final extra = parts
          .where((p) => !lower.contains(p.toLowerCase()))
          .toList(growable: false);
      return extra.isEmpty ? customName : '$customName · ${extra.join(' ')}';
    }
    final version = parts.join(' ');
    return version.isNotEmpty ? version : '默认版本';
  }

  String _buildSourceName(MediaSource source, MediaStream videoStream) {
    final customName = source.name?.trim();
    if (customName != null && customName.isNotEmpty) {
      return customName;
    }
    return _buildSourceDisplayName(source, videoStream);
  }

  String? _formatBitRate(MediaSource source, MediaStream videoStream) {
    final bitRate = videoStream.bitRate;
    if (bitRate == null || bitRate <= 0) return null;
    if (bitRate >= 1000000) {
      return '${(bitRate / 1000000).toStringAsFixed(1)} Mbps';
    }
    if (bitRate >= 1000) {
      return '${(bitRate / 1000).toStringAsFixed(0)} Kbps';
    }
    return '$bitRate bps';
  }

  void _showLineSelector(WidgetRef ref, ServerConfig? server) {
    if (server == null || server.lines.isEmpty) return;
    _hideAllOverlays();
    _sourceMenuOverlay = _createMenuOverlay(
      link: _sourceLink,
      items: server.lines.asMap().entries.map((entry) {
        final index = entry.key;
        final line = entry.value;
        final isCurrent = index == server.activeLineIndex;
        return _MenuItem(
          icon: isCurrent ? Icons.check_circle : Icons.route_outlined,
          label: isCurrent ? '${line.name} (当前)' : line.name,
          onTap: () {
            _hideAllOverlays();
            ref
                .read(serverListProvider.notifier)
                .setActiveLine(server.id, index);
            final updatedServer = ref
                .read(serverListProvider)
                .firstWhere((item) => item.id == server.id);
            ref.read(currentServerProvider.notifier).state = updatedServer;
            ref.read(selectedMediaSourceProvider.notifier).state = null;
            ref.read(audioTrackProvider.notifier).state = null;
            ref.read(subtitleTrackProvider.notifier).state = null;
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
            ref.invalidate(playbackInfoProvider(widget.itemId));
          },
        );
      }).toList(),
    );
    Overlay.of(context).insert(_sourceMenuOverlay!);
  }

  void _toggleSourceMenu(PlaybackInfo info) {
    if (_sourceMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedSourceId = ref.read(selectedMediaSourceProvider);
    _sourceMenuOverlay = _createMenuOverlay(
      link: _sourceLink,
      menuWidth: 420,
      items: info.mediaSources.map((source) {
        final videoStream =
            source.primaryVideoStream ?? MediaStream(index: 0, type: 'Video');
        final isCurrent = source.id == selectedSourceId;
        return _MenuItem(
          icon: isCurrent ? Icons.check_circle : Icons.layers_outlined,
          label: isCurrent
              ? '${_buildSourceDisplayName(source, videoStream)} (当前)'
              : _buildSourceDisplayName(source, videoStream),
          onTap: () {
            _hideAllOverlays();
            ref.read(selectedMediaSourceProvider.notifier).state = source.id;
            ref.read(audioTrackProvider.notifier).state = null;
            ref.read(subtitleTrackProvider.notifier).state = null;
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          },
        );
      }).toList(),
    );
    Overlay.of(context).insert(_sourceMenuOverlay!);
  }

  void _toggleAudioMenu(List<MediaStream> audioStreams) {
    if (_audioMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedIndex = ref.read(audioTrackProvider);
    _audioMenuOverlay = _createMenuOverlay(
      link: _audioLink,
      items: audioStreams.map((stream) {
        final isCurrent = stream.index == selectedIndex;
        return _MenuItem(
          icon: isCurrent ? Icons.check_circle : Icons.audiotrack,
          label: isCurrent
              ? '${stream.readableLabel(siblings: audioStreams)} (当前)'
              : stream.readableLabel(siblings: audioStreams),
          onTap: () {
            _hideAllOverlays();
            ref.read(audioTrackProvider.notifier).state = stream.index;
          },
        );
      }).toList(),
    );
    Overlay.of(context).insert(_audioMenuOverlay!);
  }

  void _toggleSubtitleMenu(List<MediaStream> subtitleStreams) {
    if (_subtitleMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedIndex = ref.read(subtitleTrackProvider);
    final secondaryIndex = ref.read(secondarySubtitleTrackProvider);
    _subtitleMenuOverlay = _createMenuOverlay(
      link: _subtitleLink,
      items: [
        _MenuItem(
          icon:
              selectedIndex == null ? Icons.check_circle : Icons.subtitles_off,
          label: selectedIndex == null ? '无字幕 (当前)' : '无字幕',
          onTap: () {
            _hideAllOverlays();
            ref.read(subtitleTrackProvider.notifier).state = null;
          },
        ),
        ...subtitleStreams.map((stream) {
          final isCurrent = stream.index == selectedIndex;
          return _MenuItem(
            icon: isCurrent ? Icons.check_circle : Icons.subtitles_outlined,
            label: isCurrent
                ? '${stream.readableLabel(siblings: subtitleStreams)} (当前)'
                : stream.readableLabel(siblings: subtitleStreams),
            onTap: () {
              _hideAllOverlays();
              ref.read(subtitleTrackProvider.notifier).state = stream.index;
              if (secondaryIndex == stream.index) {
                ref.read(secondarySubtitleTrackProvider.notifier).state = null;
              }
            },
          );
        }),
      ],
    );
    Overlay.of(context).insert(_subtitleMenuOverlay!);
  }

  void _toggleSecondarySubtitleMenu(List<MediaStream> secondaryCandidates) {
    if (_secondarySubtitleMenuOverlay != null) {
      _hideAllOverlays();
      return;
    }
    _hideAllOverlays();
    final selectedIndex = ref.read(secondarySubtitleTrackProvider);
    _secondarySubtitleMenuOverlay = _createMenuOverlay(
      link: _secondarySubtitleLink,
      items: [
        _MenuItem(
          icon:
              selectedIndex == null ? Icons.check_circle : Icons.subtitles_off,
          label: selectedIndex == null ? '无次字幕 (当前)' : '无次字幕',
          onTap: () {
            _hideAllOverlays();
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          },
        ),
        ...secondaryCandidates.map((stream) {
          final isCurrent = stream.index == selectedIndex;
          return _MenuItem(
            icon:
                isCurrent ? Icons.check_circle : Icons.closed_caption_disabled,
            label: isCurrent
                ? '${stream.readableLabel(siblings: secondaryCandidates)} (当前)'
                : stream.readableLabel(siblings: secondaryCandidates),
            onTap: () {
              _hideAllOverlays();
              ref.read(secondarySubtitleTrackProvider.notifier).state =
                  stream.index;
            },
          );
        }),
      ],
    );
    Overlay.of(context).insert(_secondarySubtitleMenuOverlay!);
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    } else if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '$bytes B';
  }
}

// ============================================================================
// 简介区块
// ============================================================================

class _OverviewSection extends StatelessWidget {
  final String overview;
  final bool expanded;
  final double scaleFactor;
  final Color accentColor;
  final VoidCallback onToggle;

  const _OverviewSection({
    required this.overview,
    required this.expanded,
    required this.scaleFactor,
    required this.accentColor,
    required this.onToggle,
  });

  static const int _collapsedMaxLines = 3;

  @override
  Widget build(BuildContext context) {
    final scale = scaleFactor;
    final primaryText = _detailPrimaryText(context).withValues(alpha: 0.92);
    final textStyle = TextStyle(
      fontSize: 14 * scale,
      height: 1.6,
      color: primaryText,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 真正测量在给定宽度下是否超过 3 行，只有溢出时才显示“展开”。
        final painter = TextPainter(
          text: TextSpan(text: overview, style: textStyle),
          maxLines: _collapsedMaxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final isOverflowing = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: Text(
                overview,
                maxLines: expanded ? null : _collapsedMaxLines,
                overflow:
                    expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            if (isOverflowing) ...[
              SizedBox(height: 4 * scale),
              GestureDetector(
                onTap: onToggle,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      expanded ? '收起' : '展开',
                      style: TextStyle(
                        fontSize: 13 * scale,
                        color: accentColor,
                      ),
                    ),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.keyboard_arrow_down,
                        size: 16 * scale,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

// ============================================================================
// 操作按钮
// ============================================================================

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color? activeColor;
  final Color primaryColor;
  final double scaleFactor;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.activeColor,
    required this.primaryColor,
    required this.scaleFactor,
    required this.onPressed,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final secondaryText = _detailSecondaryText(context);
    final color = widget.isActive
        ? (widget.activeColor ?? widget.primaryColor)
        : secondaryText;
    final surfaceColor = widget.isActive
        ? color.withValues(alpha: _detailUsesDarkTheme(context) ? 0.15 : 0.12)
        : _detailCardSurface(context, hovered: false);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          _controller.forward().then((_) => _controller.reverse());
          widget.onPressed();
        },
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final scaleAnim = 1.0 + (_controller.value * 0.1);
            return Transform.scale(
              scale: scaleAnim,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 16 * scale,
                  vertical: 8 * scale,
                ),
                decoration: BoxDecoration(
                  color: surfaceColor,
                  border: Border.all(
                    color: widget.isActive
                        ? color.withValues(alpha: 0.26)
                        : _detailBorder(context, emphasis: 0.08),
                  ),
                  borderRadius: BorderRadius.circular(20 * scale),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 18 * scale, color: color),
                    SizedBox(width: 6 * scale),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 13 * scale,
                        color: color,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// 播放按钮
// ============================================================================

class _PlayButton extends StatefulWidget {
  final MediaItem item;
  final Color primaryColor;
  final double scaleFactor;
  final VoidCallback onTap;
  final VoidCallback onDropdownTap;
  final ValueChanged<TapDownDetails>? onDropdownTapDown;

  const _PlayButton({
    required this.item,
    required this.primaryColor,
    required this.scaleFactor,
    required this.onTap,
    required this.onDropdownTap,
    this.onDropdownTapDown,
  });

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final foregroundColor = readableTextColorForBackground(widget.primaryColor);
    final dividerColor = foregroundColor.withValues(alpha: 0.24);
    final positionTicks = widget.item.userData?.playbackPositionTicks;
    final runTimeTicks = widget.item.runTimeTicks;
    final progress = watchedFraction(positionTicks, runTimeTicks);
    final timeText = formatWatchedOverTotalLabel(positionTicks, runTimeTicks);
    final hasProgress = progress != null && progress > 0;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Row(
        children: [
          // 主播放按钮
          Expanded(
            flex: 7,
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 48 * scale,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      widget.primaryColor,
                      widget.primaryColor.withValues(alpha: 0.85),
                    ],
                  ),
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(8 * scale),
                  ),
                  boxShadow: _isHovered
                      ? [
                          BoxShadow(
                            color: widget.primaryColor.withValues(alpha: 0.4),
                            blurRadius: 16 * scale,
                            offset: Offset(0, 4 * scale),
                          ),
                        ]
                      : null,
                ),
                child: Stack(
                  children: [
                    // 底部观看进度填充
                    if (hasProgress)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: progress.clamp(0.0, 1.0),
                          child: Container(
                            height: 4 * scale,
                            color: foregroundColor.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.play_arrow,
                            color: foregroundColor,
                            size: 24 * scale,
                          ),
                          SizedBox(width: 8 * scale),
                          Text(
                            hasProgress ? '继续观看' : '开始播放',
                            style: TextStyle(
                              fontSize: 16 * scale,
                              fontWeight: FontWeight.w600,
                              color: foregroundColor,
                            ),
                          ),
                          if (timeText != null) ...[
                            SizedBox(width: 10 * scale),
                            Text(
                              timeText,
                              style: TextStyle(
                                fontSize: 12.5 * scale,
                                color: foregroundColor.withValues(alpha: 0.85),
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 分隔线
          Container(
            width: 1,
            height: 48 * scale,
            color: dividerColor,
          ),

          // 下拉箭头
          GestureDetector(
            onTapDown: widget.onDropdownTapDown,
            onTap: widget.onDropdownTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 48 * scale,
              height: 48 * scale,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    widget.primaryColor.withValues(alpha: 0.85),
                    widget.primaryColor.withValues(alpha: 0.7),
                  ],
                ),
                borderRadius: BorderRadius.horizontal(
                  right: Radius.circular(8 * scale),
                ),
              ),
              child: Icon(
                Icons.arrow_drop_down,
                color: foregroundColor,
                size: 24 * scale,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 选择器卡片
// ============================================================================

class _SelectorCard extends StatefulWidget {
  final String label;
  final String value;
  final String? tooltip;
  final int? valueMaxLines;
  final double scaleFactor;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails>? onTapDown;

  const _SelectorCard({
    required this.label,
    required this.value,
    this.tooltip,
    this.valueMaxLines = 3,
    required this.scaleFactor,
    required this.onTap,
    this.onTapDown,
  });

  @override
  State<_SelectorCard> createState() => _SelectorCardState();
}

class _SelectorCardState extends State<_SelectorCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final scale = widget.scaleFactor;
    final hoveredSurface = _detailCardSurface(context, hovered: true);
    final idleSurface = _detailCardSurface(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: widget.onTapDown,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.all(12 * scale),
          decoration: BoxDecoration(
            color: _isHovered ? hoveredSurface : idleSurface,
            border: Border.all(
              color: _detailBorder(
                context,
                emphasis: _isHovered ? 0.28 : 0.06,
              ),
            ),
            borderRadius: BorderRadius.circular(8 * scale),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11 * scale,
                  color: _detailHintText(context),
                ),
              ),
              SizedBox(height: 4 * scale),
              Tooltip(
                message: widget.tooltip ?? widget.value,
                waitDuration: const Duration(milliseconds: 350),
                child: Text(
                  widget.value,
                  style: TextStyle(
                    fontSize: 13 * scale,
                    color: _detailPrimaryText(context),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: widget.valueMaxLines,
                  overflow: widget.valueMaxLines == null
                      ? null
                      : TextOverflow.ellipsis,
                  softWrap: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 菜单项
// ============================================================================

class _MenuItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

class _MenuSurface extends StatelessWidget {
  final double width;
  final double maxHeight;
  final Color backgroundColor;
  final List<_MenuItem> items;
  final Color primaryColor;

  const _MenuSurface({
    required this.width,
    required this.maxHeight,
    required this.backgroundColor,
    required this.items,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Color.lerp(
          _detailSurface(context, level: 0.48),
          backgroundColor,
          0.38,
        ) ??
        backgroundColor;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            width: width,
            decoration: BoxDecoration(
              color: surface.withValues(
                alpha: _detailUsesDarkTheme(context) ? 0.90 : 0.96,
              ),
              border: Border.all(
                color: _detailBorder(context, emphasis: 0.14),
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: _detailShadow(context, opacity: 0.22),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: DesktopSmoothScrollBuilder(
                builder: (context, controller) => SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: items.map((item) {
                      return _FocusableMenuItem(
                        icon: item.icon,
                        label: item.label,
                        onTap: item.onTap,
                        primaryColor: primaryColor,
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusableMenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color primaryColor;

  const _FocusableMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.primaryColor,
  });

  @override
  State<_FocusableMenuItem> createState() => _FocusableMenuItemState();
}

class _FocusableMenuItemState extends State<_FocusableMenuItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final primaryText = _detailPrimaryText(context);
    final secondaryText = _detailSecondaryText(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.primaryColor.withValues(
                    alpha: _detailUsesDarkTheme(context) ? 0.14 : 0.10,
                  )
                : Colors.transparent,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                widget.icon,
                size: 20,
                color: _isHovered ? widget.primaryColor : secondaryText,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    color: _isHovered ? primaryText : secondaryText,
                  ),
                  softWrap: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 媒体信息面板
// ============================================================================

class _MediaInfoPanel extends StatelessWidget {
  final MediaSource source;
  final String versionLabel;
  final double scaleFactor;

  const _MediaInfoPanel({
    required this.source,
    required this.versionLabel,
    required this.scaleFactor,
  });

  @override
  Widget build(BuildContext context) {
    final scale = scaleFactor;
    final videoStream =
        source.primaryVideoStream ?? MediaStream(index: 0, type: 'Video');
    final audioStreams =
        source.mediaStreams.where((s) => s.type == 'Audio').toList();
    final subtitleStreams =
        source.mediaStreams.where((s) => s.type == 'Subtitle').toList();

    return Container(
      margin: EdgeInsets.only(top: 16 * scale),
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: _detailCardSurface(context),
        borderRadius: BorderRadius.circular(8 * scale),
        border: Border.all(
          color: _detailBorder(context, emphasis: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (versionLabel.isNotEmpty)
            _InfoRow(label: '版本', value: versionLabel, scale: scale),
          _InfoRow(
              label: '容器',
              value: source.container?.toUpperCase() ?? '未知',
              scale: scale),
          _InfoRow(label: '大小', value: _formatSize(source.size), scale: scale),
          if (videoStream.displayTitle != null)
            _InfoRow(
                label: '视频', value: videoStream.displayTitle!, scale: scale),
          if (videoStream.bitRate != null && videoStream.bitRate! > 0)
            _InfoRow(
              label: '码率',
              value: videoStream.bitRate! >= 1000000
                  ? '${(videoStream.bitRate! / 1000000).toStringAsFixed(1)} Mbps'
                  : '${(videoStream.bitRate! / 1000).toStringAsFixed(0)} Kbps',
              scale: scale,
            ),
          ...audioStreams.map((s) => _InfoRow(
                label: '音频',
                value: s.readableLabel(siblings: audioStreams),
                scale: scale,
              )),
          ...subtitleStreams.map((s) => _InfoRow(
                label: '字幕',
                value: s.readableLabel(siblings: subtitleStreams),
                scale: scale,
              )),
        ],
      ),
    );
  }

  String _formatSize(int? bytes) {
    if (bytes == null) {
      return '未知';
    }
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '$bytes B';
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final double scale;

  const _InfoRow({
    required this.label,
    required this.value,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor = _detailHintText(context);
    final valueColor = _detailPrimaryText(context).withValues(alpha: 0.88);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60 * scale,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12 * scale,
                color: labelColor,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12 * scale,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 横向滚动列表通用组件
// ============================================================================
