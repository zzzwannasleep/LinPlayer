import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_interfaces.dart';
import '../../core/providers/app_providers.dart';

String mediaRouteForItem(MediaItem item) {
  switch (item.type) {
    case 'Episode':
      return '/episode/${item.id}';
    case 'Season':
      return '/season/${item.id}';
    default:
      return '/detail/${item.id}';
  }
}

/// 为一条媒体结果挑选**正确的** ApiClient。
///
/// 聚合搜索的结果可能来自其它服务器（[MediaItem.sourceServerId] 非空）：此时用其
/// 来源服务器的 base+token 解析封面/海报，否则当前服务器的图片地址鉴权不过导致空白。
/// 普通场景（sourceServerId 为 null）直接返回当前服务器 client，行为不变。
ApiClientFactory apiClientForItem(WidgetRef ref, MediaItem item) {
  final origin = item.sourceServerId;
  if (origin != null) {
    final client = ref.read(serverApiClientProvider(origin));
    if (client != null) return client;
  }
  return ref.read(apiClientProvider);
}

/// 打开一条媒体结果。若来自其它服务器（聚合搜索），先把当前服务器切到来源服务器，
/// 再导航到详情/分集/季——否则详情页会用当前服务器去取一个不存在的 itemId 而失败。
void openMediaItem(WidgetRef ref, BuildContext context, MediaItem item) {
  final origin = item.sourceServerId;
  if (origin != null && origin != ref.read(currentServerProvider)?.id) {
    ref
        .read(currentServerProvider.notifier)
        .syncWithAvailableServers(ref.read(serverListProvider),
            preferredServerId: origin);
  }
  context.push(mediaRouteForItem(item));
}

Color readableTextColorForBackground(Color background) {
  return background.computeLuminance() < 0.32 ? Colors.white : Colors.black87;
}

/// 已观看进度文案：返回如「已观看 12:34」/「已观看 1:02:03」；无有效进度返回 null。
/// [positionTicks] 为 Emby 的 100ns 单位（10,000,000 ticks = 1 秒）。
String? formatWatchedProgressLabel(num? positionTicks) {
  if (positionTicks == null || positionTicks <= 0) return null;
  final totalSeconds = positionTicks ~/ 10000000;
  if (totalSeconds <= 0) return null;
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  final time = h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  return '已观看 $time';
}

Color readableSecondaryTextColorForBackground(Color background) {
  return background.computeLuminance() < 0.32 ? Colors.white70 : Colors.black54;
}

List<String> resolveLibraryImageUrls(
  ApiClientFactory api,
  Library library, {
  int? maxWidth,
}) {
  return _dedupeUrls([
    if (library.primaryImageTag != null)
      api.image.getPrimaryImageUrl(
        library.id,
        tag: library.primaryImageTag,
        maxWidth: maxWidth,
      ),
  ]);
}

List<String> resolveMediaItemImageUrls(
  ApiClientFactory api,
  MediaItem item, {
  int? maxWidth,
  bool preferThumb = false,
}) {
  final preferWideImage = item.type == 'Movie' && preferThumb;
  return _dedupeUrls([
    if (preferWideImage && item.thumbImageTag != null)
      api.image.getThumbImageUrl(
        item.id,
        tag: item.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (preferWideImage && item.backdropImageTag != null)
      api.image.getBackdropImageUrl(
        item.backdropItemId ?? item.id,
        tag: item.backdropImageTag,
        maxWidth: maxWidth,
      ),
    if (!preferWideImage && preferThumb && item.thumbImageTag != null)
      api.image.getThumbImageUrl(
        item.id,
        tag: item.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.primaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.id,
        tag: item.primaryImageTag,
        maxWidth: maxWidth,
      ),
    if (!preferWideImage && !preferThumb && item.thumbImageTag != null)
      api.image.getThumbImageUrl(
        item.id,
        tag: item.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.parentThumbItemId != null && item.parentThumbImageTag != null)
      api.image.getThumbImageUrl(
        item.parentThumbItemId!,
        tag: item.parentThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.parentPrimaryImageItemId != null &&
        item.parentPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.parentPrimaryImageItemId!,
        tag: item.parentPrimaryImageTag,
        maxWidth: maxWidth,
      ),
    if (item.seriesId != null &&
        item.seriesId!.isNotEmpty &&
        item.seriesThumbImageTag != null)
      api.image.getThumbImageUrl(
        item.seriesId!,
        tag: item.seriesThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.seriesId != null &&
        item.seriesId!.isNotEmpty &&
        item.seriesPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.seriesId!,
        tag: item.seriesPrimaryImageTag,
        maxWidth: maxWidth,
      ),
    if (!preferWideImage && item.backdropImageTag != null)
      api.image.getBackdropImageUrl(
        item.backdropItemId ?? item.id,
        tag: item.backdropImageTag,
        maxWidth: maxWidth,
      ),
  ]);
}

List<String> resolveMediaItemLandscapeImageUrls(
  ApiClientFactory api,
  MediaItem item, {
  int? maxWidth,
}) {
  return _dedupeUrls([
    if (item.backdropImageTag != null)
      api.image.getBackdropImageUrl(
        item.backdropItemId ?? item.id,
        tag: item.backdropImageTag,
        maxWidth: maxWidth,
      ),
    if (item.thumbImageTag != null)
      api.image.getThumbImageUrl(
        item.id,
        tag: item.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.parentThumbItemId != null && item.parentThumbImageTag != null)
      api.image.getThumbImageUrl(
        item.parentThumbItemId!,
        tag: item.parentThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.seriesId != null &&
        item.seriesId!.isNotEmpty &&
        item.seriesThumbImageTag != null)
      api.image.getThumbImageUrl(
        item.seriesId!,
        tag: item.seriesThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.primaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.id,
        tag: item.primaryImageTag,
        maxWidth: maxWidth,
      ),
    if (item.parentPrimaryImageItemId != null &&
        item.parentPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.parentPrimaryImageItemId!,
        tag: item.parentPrimaryImageTag,
        maxWidth: maxWidth,
      ),
    if (item.seriesId != null &&
        item.seriesId!.isNotEmpty &&
        item.seriesPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.seriesId!,
        tag: item.seriesPrimaryImageTag,
        maxWidth: maxWidth,
      ),
  ]);
}

List<String> resolveMediaItemBannerImageUrls(
  ApiClientFactory api,
  MediaItem item, {
  int? maxWidth,
  bool allowPosterFallback = false,
}) {
  return _dedupeUrls([
    if (item.backdropImageTag != null)
      api.image.getBackdropImageUrl(
        item.backdropItemId ?? item.id,
        tag: item.backdropImageTag,
        maxWidth: maxWidth,
      ),
    if (item.thumbImageTag != null)
      api.image.getThumbImageUrl(
        item.id,
        tag: item.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.parentThumbItemId != null && item.parentThumbImageTag != null)
      api.image.getThumbImageUrl(
        item.parentThumbItemId!,
        tag: item.parentThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (item.seriesId != null &&
        item.seriesId!.isNotEmpty &&
        item.seriesThumbImageTag != null)
      api.image.getThumbImageUrl(
        item.seriesId!,
        tag: item.seriesThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (allowPosterFallback && item.primaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.id,
        tag: item.primaryImageTag,
        maxWidth: maxWidth,
      ),
    if (allowPosterFallback &&
        item.parentPrimaryImageItemId != null &&
        item.parentPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.parentPrimaryImageItemId!,
        tag: item.parentPrimaryImageTag,
        maxWidth: maxWidth,
      ),
    if (allowPosterFallback &&
        item.seriesId != null &&
        item.seriesId!.isNotEmpty &&
        item.seriesPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        item.seriesId!,
        tag: item.seriesPrimaryImageTag,
        maxWidth: maxWidth,
      ),
  ]);
}

List<String> resolveSeasonImageUrls(
  ApiClientFactory api,
  Season season, {
  int? maxWidth,
}) {
  final urls = <String>[];
  const formats = ['jpg', 'png', 'webp'];

  for (final format in formats) {
    if (season.primaryImageTag != null) {
      urls.add(
        api.image.getPrimaryImageUrl(
          season.id,
          tag: season.primaryImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
    if (season.thumbImageTag != null) {
      urls.add(
        api.image.getThumbImageUrl(
          season.id,
          tag: season.thumbImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
    if (season.seriesId.isNotEmpty && season.seriesThumbImageTag != null) {
      urls.add(
        api.image.getThumbImageUrl(
          season.seriesId,
          tag: season.seriesThumbImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
    if (season.seriesId.isNotEmpty && season.seriesPrimaryImageTag != null) {
      urls.add(
        api.image.getPrimaryImageUrl(
          season.seriesId,
          tag: season.seriesPrimaryImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
  }

  return _dedupeUrls(urls);
}

List<String> resolveSeasonLandscapeImageUrls(
  ApiClientFactory api,
  Season season, {
  int? maxWidth,
}) {
  final urls = <String>[];
  const formats = ['jpg', 'png', 'webp'];

  for (final format in formats) {
    if (season.thumbImageTag != null) {
      urls.add(
        api.image.getThumbImageUrl(
          season.id,
          tag: season.thumbImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
    if (season.primaryImageTag != null) {
      urls.add(
        api.image.getPrimaryImageUrl(
          season.id,
          tag: season.primaryImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
    if (season.seriesId.isNotEmpty && season.seriesThumbImageTag != null) {
      urls.add(
        api.image.getThumbImageUrl(
          season.seriesId,
          tag: season.seriesThumbImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
    if (season.seriesId.isNotEmpty && season.seriesPrimaryImageTag != null) {
      urls.add(
        api.image.getPrimaryImageUrl(
          season.seriesId,
          tag: season.seriesPrimaryImageTag,
          maxWidth: maxWidth,
          format: format,
        ),
      );
    }
  }

  return _dedupeUrls(urls);
}

List<String> resolveEpisodeImageUrls(
  ApiClientFactory api,
  Episode episode, {
  int? maxWidth,
  bool preferThumb = true,
}) {
  return _dedupeUrls([
    if (preferThumb && episode.thumbImageTag != null)
      api.image.getThumbImageUrl(
        episode.id,
        tag: episode.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.primaryImageTag != null)
      api.image.getPrimaryImageUrl(
        episode.id,
        tag: episode.primaryImageTag,
        maxWidth: maxWidth,
      ),
    // 兜底：不带 tag 的备选 URL
    api.image.getPrimaryImageUrl(
      episode.id,
      maxWidth: maxWidth,
    ),
    if (!preferThumb && episode.thumbImageTag != null)
      api.image.getThumbImageUrl(
        episode.id,
        tag: episode.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.parentThumbItemId != null &&
        episode.parentThumbImageTag != null)
      api.image.getThumbImageUrl(
        episode.parentThumbItemId!,
        tag: episode.parentThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.parentPrimaryImageItemId != null &&
        episode.parentPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        episode.parentPrimaryImageItemId!,
        tag: episode.parentPrimaryImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.seriesId.isNotEmpty && episode.seriesThumbImageTag != null)
      api.image.getThumbImageUrl(
        episode.seriesId,
        tag: episode.seriesThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.seriesId.isNotEmpty && episode.seriesPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        episode.seriesId,
        tag: episode.seriesPrimaryImageTag,
        maxWidth: maxWidth,
      ),
    // 兜底：不带 tag 的系列备选 URL
    if (episode.seriesId.isNotEmpty)
      api.image.getPrimaryImageUrl(
        episode.seriesId,
        maxWidth: maxWidth,
      ),
  ]);
}

List<String> resolveEpisodeLandscapeImageUrls(
  ApiClientFactory api,
  Episode episode, {
  int? maxWidth,
}) {
  return _dedupeUrls([
    if (episode.thumbImageTag != null)
      api.image.getThumbImageUrl(
        episode.id,
        tag: episode.thumbImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.parentThumbItemId != null &&
        episode.parentThumbImageTag != null)
      api.image.getThumbImageUrl(
        episode.parentThumbItemId!,
        tag: episode.parentThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.seriesId.isNotEmpty && episode.seriesThumbImageTag != null)
      api.image.getThumbImageUrl(
        episode.seriesId,
        tag: episode.seriesThumbImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.primaryImageTag != null)
      api.image.getPrimaryImageUrl(
        episode.id,
        tag: episode.primaryImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.parentPrimaryImageItemId != null &&
        episode.parentPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        episode.parentPrimaryImageItemId!,
        tag: episode.parentPrimaryImageTag,
        maxWidth: maxWidth,
      ),
    if (episode.seriesId.isNotEmpty && episode.seriesPrimaryImageTag != null)
      api.image.getPrimaryImageUrl(
        episode.seriesId,
        tag: episode.seriesPrimaryImageTag,
        maxWidth: maxWidth,
      ),
  ]);
}

List<String> _dedupeUrls(List<String> urls) {
  final seen = <String>{};
  final unique = <String>[];
  for (final url in urls) {
    if (url.isEmpty || !seen.add(url)) {
      continue;
    }
    unique.add(url);
  }
  return unique;
}
