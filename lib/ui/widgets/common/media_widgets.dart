import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_identity.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/persistent_image_provider.dart';
import '../../../core/widgets/app_shimmer.dart';
import '../../utils/media_helpers.dart';

class MediaImage extends StatelessWidget {
  final String? imageUrl;
  final List<String>? imageUrls;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget? placeholder;
  final Widget? errorWidget;
  final String? heroTag;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool gaplessPlayback;
  final Alignment alignment;

  /// 用中立浏览器 UA 请求（而非 App 的 `LinPlayer/x.x.x`）。
  /// 服务器图标等第三方 CDN 资源需要，否则可能被拒导致图标损坏。
  final bool useDefaultUserAgent;

  const MediaImage({
    super.key,
    required this.imageUrl,
    this.imageUrls,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.heroTag,
    this.cacheWidth,
    this.cacheHeight,
    this.gaplessPlayback = true,
    this.alignment = Alignment.center,
    this.useDefaultUserAgent = false,
  });

  @override
  Widget build(BuildContext context) {
    final candidates = {
      if (imageUrl != null && imageUrl!.isNotEmpty) imageUrl!,
      ...?imageUrls?.where((url) => url.isNotEmpty),
    }.toList();

    Widget image = candidates.isEmpty
        ? _buildPlaceholder(context)
        : _FallbackNetworkImage(
            imageUrls: candidates,
            width: width,
            height: height,
            fit: fit,
            alignment: alignment,
            cacheWidth: cacheWidth,
            cacheHeight: cacheHeight,
            gaplessPlayback: gaplessPlayback,
            useDefaultUserAgent: useDefaultUserAgent,
            placeholderBuilder: () => placeholder ?? _buildPlaceholder(context),
            errorBuilder: () => errorWidget ?? _buildError(context),
          );

    if (borderRadius != null) {
      image = ClipRRect(
        borderRadius: borderRadius!,
        child: image,
      );
    }

    if (heroTag != null) {
      image = Hero(
        tag: heroTag!,
        child: image,
      );
    }

    return image;
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.image_outlined, size: 32, color: Colors.grey),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.errorContainer,
      child: const Center(
        child: Icon(Icons.broken_image_outlined, size: 32, color: Colors.grey),
      ),
    );
  }
}

class _FallbackNetworkImage extends StatefulWidget {
  final List<String> imageUrls;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool gaplessPlayback;
  final bool useDefaultUserAgent;
  final Widget Function() placeholderBuilder;
  final Widget Function() errorBuilder;

  const _FallbackNetworkImage({
    required this.imageUrls,
    required this.width,
    required this.height,
    required this.fit,
    required this.alignment,
    required this.cacheWidth,
    required this.cacheHeight,
    required this.gaplessPlayback,
    required this.useDefaultUserAgent,
    required this.placeholderBuilder,
    required this.errorBuilder,
  });

  @override
  State<_FallbackNetworkImage> createState() => _FallbackNetworkImageState();
}

class _FallbackNetworkImageState extends State<_FallbackNetworkImage> {
  static const int _maxRetryRounds = 2;
  static const Duration _retryDelay = Duration(milliseconds: 900);

  /// 解码目标的最大边长上限。即使容器/屏幕很大，也把单张图片解码尺寸
  /// 钳制在此范围内，避免单张全分辨率位图（背景图可达 4K）吃满内存缓存。
  /// 1280 长边 ≈ 1280×720×4 ≈ 3.7MB，足够桌面/TV 清晰显示。
  static const int _maxDecodeDim = 1280;

  int _currentIndex = 0;
  int _retryRound = 0;
  int _requestEpoch = 0;
  bool _retryScheduled = false;

  @override
  void didUpdateWidget(covariant _FallbackNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameUrls(oldWidget.imageUrls, widget.imageUrls) ||
        _currentIndex >= widget.imageUrls.length) {
      _resetFallbackState();
    }
  }

  /// 计算解码（downsample）目标尺寸。
  ///
  /// 关键内存优化：之前 [cacheWidth]/[cacheHeight] 根本没传给 ExtendedImage，
  /// 所有图片都按原始分辨率解码进内存——首页几张背景图就能撑爆缓存。
  /// 现在统一推导一个解码目标：调用方显式给了就用；否则按容器/约束尺寸
  /// × devicePixelRatio 推导，并钳制到 [_maxDecodeDim]，再交给
  /// [ExtendedResizeImage] 让解码器直接以小尺寸出图。
  ({int? width, int? height}) _resolveDecodeSize(
    BoxConstraints constraints,
    double dpr,
  ) {
    int? cap(int? v) =>
        v == null ? null : (v < 1 ? 1 : (v > _maxDecodeDim ? _maxDecodeDim : v));

    if (widget.cacheWidth != null || widget.cacheHeight != null) {
      return (width: cap(widget.cacheWidth), height: cap(widget.cacheHeight));
    }

    double? w = widget.width;
    if (w == null || !w.isFinite || w <= 0) w = constraints.maxWidth;
    double? h = widget.height;
    if (h == null || !h.isFinite || h <= 0) h = constraints.maxHeight;

    final int? dw =
        (w.isFinite && w > 0) ? (w * dpr).round() : null;
    final int? dh =
        (h.isFinite && h > 0) ? (h * dpr).round() : null;
    return (width: cap(dw), height: cap(dh));
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final decode = _resolveDecodeSize(constraints, dpr);
        final base = PersistentNetworkImageProvider(
          widget.imageUrls[_currentIndex],
          cache: true,
          cacheMaxAge: const Duration(days: 30),
          retries: 5,
          timeRetry: const Duration(milliseconds: 350),
          requestKey: '$_requestEpoch:$_retryRound:$_currentIndex',
          // 中立资源（服务器图标等）用浏览器 UA，覆盖共享 HttpClient 的 App UA，
          // 避免被第三方 CDN 拒绝导致图标损坏。
          headers: widget.useDefaultUserAgent
              ? const {'User-Agent': kDefaultBrowserUserAgent}
              : null,
        );
        // 以推导出的小尺寸解码并缓存。maxBytes/compressionRatio 必须显式置 null，
        // 否则 ExtendedResizeImage 默认 maxBytes=50KB 会无视 width/height 把图压成
        // 50KB 的糊图。policy.fit 保持纵横比、避免 cover 显示时变形。
        final ImageProvider<Object> provider;
        if (decode.width != null || decode.height != null) {
          provider = ExtendedResizeImage(
            base,
            width: decode.width,
            height: decode.height,
            maxBytes: null,
            compressionRatio: null,
            policy: ResizeImagePolicy.fit,
          );
        } else {
          provider = base;
        }
        return _buildExtendedImage(provider);
      },
    );
  }

  Widget _buildExtendedImage(ImageProvider provider) {
    return ExtendedImage(
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: widget.gaplessPlayback,
      enableMemoryCache: true,
      clearMemoryCacheIfFailed: false,
      enableLoadState: true,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            if (state.extendedImageInfo != null || state.wasSynchronouslyLoaded) {
              return state.completedWidget;
            }
            return widget.placeholderBuilder();
          case LoadState.completed:
            return state.completedWidget;
          case LoadState.failed:
            if (_scheduleRetryIfPossible()) {
              return state.extendedImageInfo != null
                  ? state.completedWidget
                  : widget.placeholderBuilder();
            }
            return widget.errorBuilder();
        }
      },
    );
  }

  void _resetFallbackState() {
    _currentIndex = 0;
    _retryRound = 0;
    _requestEpoch = 0;
    _retryScheduled = false;
  }

  bool _scheduleRetryIfPossible() {
    if (_retryScheduled || !mounted) {
      return _retryScheduled;
    }

    if (_currentIndex < widget.imageUrls.length - 1) {
      _retryScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _currentIndex += 1;
          _retryScheduled = false;
        });
      });
      return true;
    }

    if (_retryRound >= _maxRetryRounds) {
      return false;
    }

    _retryScheduled = true;
    Future<void>.delayed(_retryDelay, () {
      if (!mounted) return;
      setState(() {
        _retryRound += 1;
        _currentIndex = 0;
        _requestEpoch += 1;
        _retryScheduled = false;
      });
    });
    return true;
  }

  bool _sameUrls(List<String> previous, List<String> next) {
    if (identical(previous, next)) return true;
    if (previous.length != next.length) return false;
    for (var i = 0; i < previous.length; i++) {
      if (previous[i] != next[i]) return false;
    }
    return true;
  }
}

Future<void> warmPersistentImageCache(
  BuildContext context,
  Iterable<String> imageUrls, {
  Duration cacheMaxAge = const Duration(days: 30),
}) async {
  final deduped = <String>{};
  for (final imageUrl in imageUrls) {
    if (imageUrl.isEmpty || !deduped.add(imageUrl)) {
      continue;
    }
    try {
      await precacheImage(
        PersistentNetworkImageProvider(
          imageUrl,
          cache: true,
          cacheMaxAge: cacheMaxAge,
        ),
        context,
      );
    } catch (_) {
      // Ignore cache warmup errors and continue with other candidates.
    }
  }
}

class MediaPoster extends ConsumerWidget {
  final MediaItem item;
  final double width;
  final double height;
  final VoidCallback? onTap;
  final String? heroTag;

  const MediaPoster({
    super.key,
    required this.item,
    required this.width,
    required this.height,
    this.onTap,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final imageUrls = resolveMediaItemImageUrls(api, item, maxWidth: 320);
    final useFill = !width.isFinite || !height.isFinite;
    final borderRadius = BorderRadius.circular(16);

    Widget imageWidget = SizedBox(
      width: width.isFinite ? width : null,
      height: height.isFinite ? height : null,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SizedBox.expand(
            child: Transform.scale(
              scale: 1.05,
              child: MediaImage(
                imageUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
                imageUrls: imageUrls.length > 1 ? imageUrls.sublist(1) : null,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: width.isFinite ? (width * 2).toInt() : 640,
                cacheHeight: height.isFinite ? (height * 2).toInt() : 960,
                fit: BoxFit.cover, // 使用 cover 填满容器，统一显示大小
                heroTag: heroTag,
              ),
            ),
          ),
        ),
      ),
    );

    if (useFill) {
      imageWidget = AspectRatio(
        aspectRatio: 2 / 3,
        child: imageWidget,
      );
    }

    final List<Widget> infoWidgets = [];
    if (item.productionYear != null) {
      infoWidgets.add(
        Text(
          '${item.productionYear}',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      );
    }
    if (item.communityRating != null) {
      if (infoWidgets.isNotEmpty) {
        infoWidgets.add(const SizedBox(width: 6));
      }
      infoWidgets.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star, size: 12, color: Colors.amber),
            const SizedBox(width: 2),
            Text(
              item.communityRating!.toStringAsFixed(1),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.amber,
              ),
            ),
          ],
        ),
      );
    }

    final isSeries = item.type == 'Series' || item.type == 'Season';
    final episodeCount = item.recursiveItemCount ?? item.childCount;

    return InkWell(
      onTap: onTap,
      borderRadius: borderRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: useFill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          useFill
              ? Expanded(
                  child: Stack(
                    children: [
                      imageWidget,
                      if (item.userData?.playbackPositionTicks != null &&
                          item.runTimeTicks != null)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: ClipRRect(
                            borderRadius: BorderRadius.vertical(
                              bottom: Radius.circular(borderRadius.topLeft.x),
                            ),
                            child: LinearProgressIndicator(
                              value: item.progress,
                              backgroundColor: Colors.black.withValues(alpha: 0.3),
                              valueColor: const AlwaysStoppedAnimation(
                                Color(0xFF5B8DEF),
                              ),
                              minHeight: 3,
                            ),
                          ),
                        ),
                      if (item.isWatched)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      if (isSeries && episodeCount != null && episodeCount > 0)
                        Positioned(
                          top: 8,
                          right: item.isWatched ? 32 : 8,
                          child: _CountBadge(count: episodeCount),
                        ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    imageWidget,
                    if (item.userData?.playbackPositionTicks != null &&
                        item.runTimeTicks != null)
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(borderRadius.topLeft.x),
                          ),
                          child: LinearProgressIndicator(
                            value: item.progress,
                            backgroundColor: Colors.black.withValues(alpha: 0.3),
                            valueColor: const AlwaysStoppedAnimation(
                              Color(0xFF5B8DEF),
                            ),
                            minHeight: 3,
                          ),
                        ),
                      ),
                    if (item.isWatched)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    if (isSeries && episodeCount != null && episodeCount > 0)
                      Positioned(
                        top: 8,
                        right: item.isWatched ? 32 : 8,
                        child: _CountBadge(count: episodeCount),
                      ),
                  ],
                ),
          const SizedBox(height: 6),
          SizedBox(
            width: width.isFinite ? width : double.infinity,
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          if (infoWidgets.isNotEmpty) ...[
            const SizedBox(height: 2),
            SizedBox(
              width: width.isFinite ? width : double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: infoWidgets,
              ),
            ),
          ],
          if (item.seriesName != null)
            SizedBox(
              width: width.isFinite ? width : double.infinity,
              child: Text(
                '${item.seriesName} | S${item.parentIndexNumber}E${item.indexNumber}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 骨架占位。对外 API 不变，内部改用带 shimmer 扫光的 [ShimmerBox]，
/// 让所有已用 Skeleton 的页面自动获得呼吸感加载动效。
class Skeleton extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadius? borderRadius;

  const Skeleton({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return ShimmerBox(
      width: width,
      height: height,
      borderRadius: borderRadius ?? BorderRadius.circular(12),
    );
  }
}

class HorizontalList extends StatelessWidget {
  final List<Widget> children;
  final double spacing;
  final EdgeInsets padding;
  final double? height;

  const HorizontalList({
    super.key,
    required this.children,
    this.spacing = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: children.length,
        separatorBuilder: (_, __) => SizedBox(width: spacing),
        itemBuilder: (_, index) => RepaintBoundary(
          child: children[index],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMoreTap;

  const SectionHeader({
    super.key,
    required this.title,
    this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onMoreTap != null)
            GestureDetector(
              onTap: onMoreTap,
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
    );
  }
}

class RatingBadge extends StatelessWidget {
  final double? rating;
  final double size;

  const RatingBadge({
    super.key,
    this.rating,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    if (rating == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star, size: size, color: Colors.amber),
        const SizedBox(width: 2),
        Text(
          rating!.toStringAsFixed(1),
          style: TextStyle(
            fontSize: size - 1,
            fontWeight: FontWeight.w600,
            color: Colors.amber.shade700,
          ),
        ),
      ],
    );
  }
}

class TagBadge extends StatelessWidget {
  final String text;
  final Color? backgroundColor;
  final Color? textColor;

  const TagBadge({
    super.key,
    required this.text,
    this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: textColor ?? Theme.of(context).textTheme.bodySmall?.color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
