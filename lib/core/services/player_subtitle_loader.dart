import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_interfaces.dart';
import '../utils/track_preference.dart';
import 'app_logger.dart';
import 'subtitle_processor.dart';
import 'video_player_service.dart';

/// 播放器字幕加载（内封轨道选择 + 外挂下载/转码），三端共用。
///
/// 把原本散在移动端播放页里的字幕逻辑收敛成一处：编解码归一、外挂字幕下载、
/// ExoPlayer 的 ASS（libass 或转 SRT）处理、按首选语言挑轨。TV / 移动端都可调用。
class PlayerSubtitleLoader {
  static final _logger = AppLogger();

  /// 按首选语言加载字幕：内封走播放器轨道选择，外挂下载到本地再加载。
  /// 返回选中的 Emby 字幕流 index（供 UI 记录当前选择），无可用字幕时返回 null。
  static Future<int?> loadPreferred({
    required VideoPlayerService service,
    required ApiClientFactory api,
    required String itemId,
    required MediaSource mediaSource,
    required String? preferredLanguage,
    required bool exoLibassEnabled,
    String? authToken,
    String? preferredRegex,
  }) async {
    final subtitleStreams =
        mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();
    if (subtitleStreams.isEmpty) return null;

    // 「字幕选择」正则优先：命中则用正则结果，否则回退到首选字幕语言。
    final target = matchPreferredStream(subtitleStreams, preferredRegex) ??
        subtitleStreams.firstWhere(
          (s) => preferredLanguage != null && s.language == preferredLanguage,
          orElse: () => subtitleStreams.first,
        );
    final codec = target.codec?.toLowerCase() ?? 'ass';
    final isExternal = target.isExternal ?? false;
    final core = service.coreType;

    try {
      if (!isExternal) {
        await _selectInternal(service, target, preferredLanguage);
      } else {
        await _loadExternal(
          service: service,
          api: api,
          itemId: itemId,
          mediaSource: mediaSource,
          target: target,
          codec: codec,
          core: core,
          exoLibassEnabled: exoLibassEnabled,
          authToken: authToken,
        );
      }
    } catch (e, st) {
      _logger.eWithStack('SubtitleLoader', '字幕加载失败', e, st);
    }
    return target.index;
  }

  // ---- 内封：按语言在播放器轨道里挑 ----

  static Future<void> _selectInternal(
      VideoPlayerService service, MediaStream target, String? lang) async {
    final subs = service.tracksInfo
        .where((t) =>
            (t['type'] == 'text' || t['type'] == 'bitmap') &&
            t['id'] != 'auto' &&
            t['id'] != 'no')
        .toList();
    if (subs.isEmpty) return;

    final isMpv = service.coreType == PlayerCoreType.mpv ||
        service.coreType == PlayerCoreType.nativeMpv;
    final title = target.displayTitle ?? target.title;
    final trackId = isMpv
        ? matchMpvSubtitleTrack(
            subs, target.language, title, target.codec, target.index)
        : matchExoSubtitleTrack(
            subs, target.language, title, target.codec, target.index);
    if (trackId != null) await service.selectSubtitleTrack(trackId);
  }

  // ---- 内封轨道智能匹配（纯函数，三端共用）----

  /// MPV 内核：按图形/ASS 候选 → 标题 → 语言(含 chi/zh) → Emby 流序 匹配。
  static String? matchMpvSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) {
    final codec = targetCodec?.toLowerCase() ?? '';
    final isGraphical = isGraphicalSubtitleCodec(codec);
    final isAss = codec == 'ass' || codec == 'ssa';

    final candidates = isGraphical
        ? subtitleTracks
            .where((t) => t['type'] == 'bitmap' || t['isBitmap'] == true)
            .toList()
        : isAss
            ? subtitleTracks
                .where((t) => t['isAss'] == true || t['type'] == 'text')
                .toList()
            : subtitleTracks;

    if (candidates.isEmpty) return subtitleTracks.first['id']?.toString();

    if (targetTitle != null && targetTitle.isNotEmpty) {
      for (final t in candidates) {
        final tTitle = t['title']?.toString() ?? '';
        if (tTitle.isNotEmpty && titlesMatch(targetTitle, tTitle)) {
          return t['id']?.toString();
        }
      }
    }

    if (targetLang != null) {
      final langMatches = candidates
          .where((t) =>
              t['language'] == targetLang ||
              t['language'] == 'chi' ||
              t['language'] == 'zh')
          .toList();
      if (langMatches.length == 1) return langMatches.first['id']?.toString();
      if (langMatches.length > 1 &&
          targetTitle != null &&
          targetTitle.isNotEmpty) {
        for (final t in langMatches) {
          final tTitle = t['title']?.toString() ?? '';
          if (tTitle.isNotEmpty && titlesMatch(targetTitle, tTitle)) {
            return t['id']?.toString();
          }
        }
        if (targetStreamIndex >= 0 && targetStreamIndex < langMatches.length) {
          return langMatches[targetStreamIndex]['id']?.toString();
        }
        return langMatches.first['id']?.toString();
      }
    }

    final embySubIndex = computeEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
    if (embySubIndex >= 0 && embySubIndex < candidates.length) {
      return candidates[embySubIndex]['id']?.toString();
    }
    return candidates.first['id']?.toString();
  }

  /// MPV 副字幕：优先按 Emby 流序对齐，再标题，最后任一非位图轨。
  static String? matchMpvSecondarySubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    MediaStream target,
    String? primaryTrackId,
  ) {
    if (subtitleTracks.isEmpty) return null;
    final codec = target.codec?.toLowerCase() ?? '';
    if (isGraphicalSubtitleCodec(codec)) return null;

    final filtered = subtitleTracks.where((t) {
      final isBitmap = t['type'] == 'bitmap' || t['isBitmap'] == true;
      if (isBitmap) return false;
      final embyIndex = extractEmbySubtitleIndex(t['id']?.toString());
      return embyIndex != null && embyIndex == target.index;
    }).toList();
    if (filtered.isNotEmpty) return filtered.first['id']?.toString();

    final title = target.displayTitle ?? target.title;
    if (title != null && title.isNotEmpty) {
      for (final t in subtitleTracks) {
        if (t['id']?.toString() == primaryTrackId) continue;
        final isBitmap = t['type'] == 'bitmap' || t['isBitmap'] == true;
        if (isBitmap) continue;
        final tTitle = t['title']?.toString() ?? '';
        if (tTitle.isNotEmpty && titlesMatch(title, tTitle)) {
          return t['id']?.toString();
        }
      }
    }
    for (final t in subtitleTracks) {
      if (t['id']?.toString() == primaryTrackId) continue;
      final isBitmap = t['type'] == 'bitmap' || t['isBitmap'] == true;
      if (isBitmap) continue;
      return t['id']?.toString();
    }
    return null;
  }

  /// ExoPlayer 内核：按 groupIndex → 标题 → 语言 → Emby 流序 匹配。
  static String? matchExoSubtitleTrack(
    List<Map<String, dynamic>> subtitleTracks,
    String? targetLang,
    String? targetTitle,
    String? targetCodec,
    int targetStreamIndex,
  ) {
    final codec = targetCodec?.toLowerCase() ?? '';
    final isGraphical = isGraphicalSubtitleCodec(codec);

    final candidates = isGraphical
        ? subtitleTracks
            .where((t) => t['type'] == 'bitmap' || t['isBitmap'] == true)
            .toList()
        : subtitleTracks;
    if (candidates.isEmpty) return null;

    for (final t in candidates) {
      final groupIndex = t['groupIndex'];
      if (groupIndex != null && groupIndex == targetStreamIndex) {
        return t['id']?.toString();
      }
    }

    if (targetTitle != null && targetTitle.isNotEmpty) {
      for (final t in candidates) {
        final tTitle = t['title']?.toString() ?? t['label']?.toString() ?? '';
        if (tTitle.isNotEmpty && titlesMatch(targetTitle, tTitle)) {
          return t['id']?.toString();
        }
      }
    }

    if (targetLang != null) {
      final langMatches =
          candidates.where((t) => t['language'] == targetLang).toList();
      if (langMatches.length == 1) return langMatches.first['id']?.toString();
      if (langMatches.length > 1) {
        final idx = computeEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
        if (idx >= 0 && idx < langMatches.length) {
          return langMatches[idx]['id']?.toString();
        }
        return langMatches.first['id']?.toString();
      }
    }

    final idx = computeEmbySubtitleIndex(targetStreamIndex, subtitleTracks);
    if (idx >= 0 && idx < candidates.length) {
      return candidates[idx]['id']?.toString();
    }
    return candidates.first['id']?.toString();
  }

  /// Emby 字幕流序 → 播放器轨道列表内的序号（兼容 `group_track` id 命名）。
  static int computeEmbySubtitleIndex(
      int embyStreamIndex, List<Map<String, dynamic>> subtitleTracks) {
    if (subtitleTracks.isEmpty) return -1;
    final ids = subtitleTracks.map((t) => t['id']?.toString() ?? '').toList();
    for (int i = 0; i < ids.length; i++) {
      final parts = ids[i].split('_');
      if (parts.length == 2 && int.tryParse(parts[0]) == embyStreamIndex) {
        return i;
      }
    }
    final sorted = List<Map<String, dynamic>>.from(subtitleTracks);
    sorted.sort((a, b) {
      final aId = a['id']?.toString() ?? '0';
      final bId = b['id']?.toString() ?? '0';
      final aGroup = int.tryParse(aId.split('_').first) ?? 0;
      final bGroup = int.tryParse(bId.split('_').first) ?? 0;
      if (aGroup != bGroup) return aGroup.compareTo(bGroup);
      final aTrack = int.tryParse(aId.split('_').last) ?? 0;
      final bTrack = int.tryParse(bId.split('_').last) ?? 0;
      return aTrack.compareTo(bTrack);
    });
    int subCounter = 0;
    for (int i = 0; i < sorted.length; i++) {
      final groupStr = sorted[i]['id'].toString().split('_').first;
      final group = int.tryParse(groupStr) ?? 0;
      if (group == embyStreamIndex) return subCounter;
      subCounter++;
    }
    return -1;
  }

  static int? extractEmbySubtitleIndex(String? trackId) {
    if (trackId == null || trackId.isEmpty) return null;
    final parts = trackId.split('_');
    if (parts.length != 2) return null;
    return int.tryParse(parts.first);
  }

  /// Emby 字幕标题与播放器轨道标题是否同一条（含简繁关键词归并）。
  static bool titlesMatch(String embyTitle, String playerTitle) {
    final e = embyTitle.toLowerCase();
    final p = playerTitle.toLowerCase();
    if (e == p) return true;
    if (p.contains(e) || e.contains(p)) return true;
    const simpKeywords = ['简', 'chs', '简体', '简日', 'gb', '简中'];
    const tradKeywords = ['繁', 'cht', '繁体', '繁日', 'big5', '繁中'];
    final eIsSimp = simpKeywords.any((k) => e.contains(k));
    final eIsTrad = tradKeywords.any((k) => e.contains(k));
    final pIsSimp = simpKeywords.any((k) => p.contains(k));
    final pIsTrad = tradKeywords.any((k) => p.contains(k));
    if (eIsSimp && pIsSimp) return true;
    if (eIsTrad && pIsTrad) return true;
    return false;
  }

  // ---- 外挂：下载到临时文件后加载 ----

  static Future<void> _loadExternal({
    required VideoPlayerService service,
    required ApiClientFactory api,
    required String itemId,
    required MediaSource mediaSource,
    required MediaStream target,
    required String codec,
    required PlayerCoreType core,
    required bool exoLibassEnabled,
    String? authToken,
  }) async {
    final embyCodec = embySubtitleCodec(codec, core);
    final subUrl = api.playback
        .getSubtitleStreamUrl(itemId, mediaSource.id, target.index, embyCodec);
    final ext = subtitleFileExtension(codec, core);
    final file = await _prepareFile(
      subtitleUrl: subUrl,
      fileName: 'subtitle_${itemId}_${target.index}.$ext',
      codec: codec,
      core: core,
      exoLibassEnabled: exoLibassEnabled,
      authToken: authToken,
    );
    if (file.existsSync() && await file.length() > 0) {
      await service.loadLibassSubtitle(file.path);
      _logger.i('SubtitleLoader', '外挂字幕加载成功: ${file.path}');
    }
  }

  static Future<File> _prepareFile({
    required String subtitleUrl,
    required String fileName,
    required String codec,
    required PlayerCoreType core,
    required bool exoLibassEnabled,
    String? authToken,
  }) async {
    final source = await _download(subtitleUrl, fileName, authToken);
    if (core != PlayerCoreType.exoPlayer) return source;

    // ExoPlayer：ASS 开了 libass 就保留原文件交原生管线；否则转 SRT 兼容。
    if (isAssSubtitleCodec(codec)) {
      if (exoLibassEnabled) return source;
      final outPath = source.path.replaceFirst(RegExp(r'\.[^.]+$'), '.srt');
      final converted =
          await SubtitleProcessor.convertAssToSrt(source.path, outputPath: outPath);
      return File(converted);
    }
    return source;
  }

  static Future<File> _download(
      String url, String fileName, String? authToken) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$fileName');
    if (!file.existsSync() || await file.length() == 0) {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      if (authToken != null) {
        dio.options.headers['X-Emby-Token'] = authToken;
        dio.options.headers['X-MediaBrowser-Token'] = authToken;
      }
      await dio.download(url, file.path);
    }
    return file;
  }

  // ---- 编解码归一（纯函数，可独立复用）----

  static String embySubtitleCodec(String codec, PlayerCoreType core) {
    final lower = codec.toLowerCase();
    final isPgs = lower == 'pgssub' ||
        lower == 'pgs' ||
        lower == 'sup' ||
        lower.contains('hdmv');
    final isMpv =
        core == PlayerCoreType.mpv || core == PlayerCoreType.nativeMpv;
    if (isMpv) {
      switch (lower) {
        case 'srt' || 'subrip':
          return 'srt';
        case 'vtt' || 'webvtt':
          return 'vtt';
        default:
          return isPgs ? 'pgs' : 'ass';
      }
    }
    switch (lower) {
      case 'srt' || 'subrip':
        return 'srt';
      case 'vtt' || 'webvtt':
        return 'vtt';
      case 'ass' || 'ssa':
        return 'ass';
      case 'pgssub' || 'pgs' || 'sup':
        return 'pgs';
      default:
        return isPgs ? 'pgs' : 'srt';
    }
  }

  static String subtitleFileExtension(String codec, PlayerCoreType core) {
    final lower = codec.toLowerCase();
    if (lower == 'srt' || lower == 'subrip') return 'srt';
    if (lower == 'vtt' || lower == 'webvtt') return 'vtt';
    if (lower == 'ass' || lower == 'ssa') return 'ass';
    if (isGraphicalSubtitleCodec(lower)) return 'sup';
    final isMpv =
        core == PlayerCoreType.mpv || core == PlayerCoreType.nativeMpv;
    return isMpv ? 'ass' : 'srt';
  }

  static bool isAssSubtitleCodec(String codec) {
    final lower = codec.toLowerCase();
    return lower == 'ass' || lower == 'ssa';
  }

  static bool isGraphicalSubtitleCodec(String codec) {
    final lower = codec.toLowerCase();
    return lower == 'pgssub' ||
        lower == 'sup' ||
        lower == 'pgs' ||
        lower == 'dvdsub' ||
        lower == 'vobsub' ||
        lower.contains('hdmv') ||
        lower.contains('pgs');
  }
}
