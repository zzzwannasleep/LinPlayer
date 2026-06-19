import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/services/watch_history/watch_history_models.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/providers/download_providers.dart';
import '../../../core/services/download/download_helper.dart';
import '../../widgets/common/danmaku_search_widget.dart';
import '../../widgets/common/danmaku_overlay.dart';
import '../../widgets/common/media_widgets.dart';
import '../../utils/media_helpers.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/services/mpv_player_adapter.dart';
import '../../../core/services/exo_player_adapter.dart';
import '../../../core/services/native_mpv_player_adapter.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/font_service.dart';
import '../../../core/services/player_subtitle_loader.dart';
import '../../../core/services/subtitle_processor.dart';
import '../../../core/services/translation/translation_actions.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/translation/streaming_subtitle_translator.dart';
import '../../../core/services/intro_skip_controller.dart';
import '../../../core/utils/playback_error_text.dart';
import '../../../core/utils/playback_url_resolver.dart';
import '../../../core/utils/track_preference.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/player_settings_panel.dart';
import '../../../core/theme/app_motion.dart';

part 'player_screen_state.dart';
part 'player_screen_panels.dart';

/// 播放页
class PlayerScreen extends ConsumerStatefulWidget {
  final String itemId;
  final String? mediaSourceId;

  const PlayerScreen({super.key, required this.itemId, this.mediaSourceId});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}
