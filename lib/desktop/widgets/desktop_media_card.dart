import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import 'desktop_cover_radii.dart';

/// Desktop media poster card used across the shell.
class DesktopMediaCard extends ConsumerStatefulWidget {
  final MediaItem item;
  final double width;
  final double? height;
  final bool showProgress;
  final VoidCallback? onTap;
  final bool compact;
  final int titleMaxLines;
  final bool showMetadata;

  const DesktopMediaCard({
    super.key,
    required this.item,
    required this.width,
    this.height,
    this.showProgress = false,
    this.onTap,
    this.compact = false,
    this.titleMaxLines = 2,
    this.showMetadata = true,
  });

  @override
  ConsumerState<DesktopMediaCard> createState() => _DesktopMediaCardState();
}

class _DesktopMediaCardState extends ConsumerState<DesktopMediaCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    // 聚合搜索的跨服务器结果用其来源服务器解析封面，避免当前服务器鉴权不过空白。
    final api = apiClientForItem(ref, widget.item);
    final imageUrls =
        resolveMediaItemImageUrls(api, widget.item, maxWidth: 400);
    final theme = Theme.of(context);
    final aspectRatio =
        widget.height != null ? widget.width / widget.height! : 2 / 3;
    // 字重恒定，避免 hover 时 w500↔w700 触发文本 relayout；
    // hover 反馈交给上移 + 渐显遮罩（见下方 AnimatedContainer）。
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      fontSize: widget.compact ? 13.5 : null,
      height: widget.compact ? 1.18 : 1.24,
      fontWeight: FontWeight.w600,
    );
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: widget.compact ? 11.5 : null,
      height: 1.22,
    );

    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap ?? () => openMediaItem(ref, context, widget.item),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.fastOutSlowIn,
            width: widget.width,
            transform: _isHovered
                ? (Matrix4.identity()..translateByDouble(0.0, -4.0, 0.0, 1.0))
                : Matrix4.identity(),
            transformAlignment: Alignment.center,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: aspectRatio,
                  child: ClipRRect(
                    borderRadius: desktopPortraitCoverRadius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        MediaImage(
                          imageUrl:
                              imageUrls.isNotEmpty ? imageUrls.first : null,
                          width: widget.width,
                          height: widget.height ?? widget.width / aspectRatio,
                          cacheWidth:
                              (widget.width * 2).toInt(), // 2x 显示尺寸，适配高 DPI
                          cacheHeight: widget.height != null
                              ? (widget.height! * 2).toInt()
                              : ((widget.width / aspectRatio) * 2).toInt(),
                          fit: BoxFit.cover,
                        ),
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 120),
                          opacity: _isHovered ? 1.0 : 0.0,
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
                            child: const Center(
                              child: Icon(
                                Icons.play_circle_outline,
                                size: 48,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        if (widget.showProgress && widget.item.progress != null)
                          Positioned(
                            bottom: 8,
                            left: 8,
                            right: 8,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: widget.item.progress,
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.3),
                                valueColor: const AlwaysStoppedAnimation(
                                    Color(0xFF5B8DEF)),
                                minHeight: 3,
                              ),
                            ),
                          ),
                        if (widget.item.communityRating != null)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.star,
                                      size: 12, color: Colors.amber),
                                  const SizedBox(width: 2),
                                  Text(
                                    widget.item.communityRating!
                                        .toStringAsFixed(1),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: widget.compact ? 6 : 8),
                Text(
                  widget.item.name,
                  maxLines: widget.titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                if (widget.showMetadata &&
                    (widget.item.productionYear != null ||
                        (widget.item.genres?.isNotEmpty ?? false)))
                  Text(
                    widget.item.productionYear?.toString() ??
                        (widget.item.genres?.isNotEmpty ?? false
                            ? widget.item.genres!.first
                            : ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
