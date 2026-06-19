import 'dart:async';
import 'dart:ui';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/download_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/download/download_helper.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/utils/color_extractor.dart';
import '../../../core/utils/playback_url_resolver.dart';
import '../../../core/widgets/app_shimmer.dart';

import '../../../ui/utils/media_helpers.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../../ui/widgets/common/video_background.dart';
import '../../utils/desktop_smooth_scroll.dart';
import '../../widgets/desktop_media_card.dart';
import '../../widgets/native_feedback.dart';

part 'desktop_media_detail_screen_state.dart';
part 'desktop_media_detail_screen_header.dart';
part 'desktop_media_detail_screen_sections.dart';

/// 桌面端媒体详情页（剧/电影通用）
class DesktopMediaDetailScreen extends ConsumerWidget {
  final String itemId;

  const DesktopMediaDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemAsync = ref.watch(mediaItemProvider(itemId));

    return Scaffold(
      body: itemAsync.when(
        data: (item) => _DetailContent(item: item, itemId: itemId),
        loading: () => const _SkeletonView(),
        error: (error, _) => _ErrorView(
          error: error,
          onRetry: () => ref.invalidate(mediaItemProvider(itemId)),
        ),
      ),
    );
  }
}
