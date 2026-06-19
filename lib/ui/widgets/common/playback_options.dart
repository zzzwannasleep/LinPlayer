import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';

/// 播放选项组件（线路/版本/音频/字幕/次字幕）
///
/// 选择项不再从底部弹出，而是顺着对应的选择栏就地展开，
/// 列表内嵌在页面滚动里，版本再多（十几个单集版本）也能完整展示。
class PlaybackOptions extends ConsumerStatefulWidget {
  final String itemId;
  final PlaybackInfo info;

  const PlaybackOptions({super.key, required this.itemId, required this.info});

  @override
  ConsumerState<PlaybackOptions> createState() => _PlaybackOptionsState();
}

class _PlaybackOptionsState extends ConsumerState<PlaybackOptions> {
  /// 当前展开的栏目（同一时间只展开一个），null 表示全部收起。
  String? _expanded;

  /// 展开后的选项列表滚动控制器。任一时刻只有一个栏目展开，故共用一个即可。
  final ScrollController _optionsScrollController = ScrollController();

  String get itemId => widget.itemId;
  PlaybackInfo get info => widget.info;

  void _toggle(String key) {
    setState(() {
      _expanded = _expanded == key ? null : key;
      // 切换展开栏目时回到顶部，避免沿用上一个栏目的滚动位置。
      if (_optionsScrollController.hasClients) {
        _optionsScrollController.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    _optionsScrollController.dispose();
    super.dispose();
  }

  MediaSource? _resolveMediaSource(
      PlaybackInfo info, String? selectedSourceId) {
    if (info.mediaSources.isEmpty) {
      return null;
    }
    if (selectedSourceId == null || selectedSourceId.isEmpty) {
      return info.mediaSources.firstOrNull;
    }
    return info.mediaSources
            .where((source) => source.id == selectedSourceId)
            .firstOrNull ??
        info.mediaSources.firstOrNull;
  }

  MediaStream? _resolveSelectedStream(
      List<MediaStream> streams, int? selectedIndex) {
    if (streams.isEmpty) {
      return null;
    }
    if (selectedIndex == null) {
      return streams.where((stream) => stream.isDefault == true).firstOrNull ??
          streams.firstOrNull;
    }
    // 先尝试精确匹配 index，找不到则回退到默认或第一个
    return streams
            .where((stream) => stream.index == selectedIndex)
            .firstOrNull ??
        streams.where((stream) => stream.isDefault == true).firstOrNull ??
        streams.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final server = ref.watch(currentServerProvider);
    final selectedLineIndex = server?.activeLineIndex ?? 0;
    final selectedAudioIndex = ref.watch(audioTrackProvider);
    final selectedSubtitleIndex = ref.watch(subtitleTrackProvider);
    final selectedSecondarySubtitleIndex =
        ref.watch(secondarySubtitleTrackProvider);
    final selectedSourceId = ref.watch(selectedMediaSourceProvider);

    final mediaSource = _resolveMediaSource(info, selectedSourceId);
    if (mediaSource == null) {
      return const SizedBox.shrink();
    }
    if (selectedSourceId != null && selectedSourceId != mediaSource.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(selectedMediaSourceProvider) == selectedSourceId) {
          ref.read(selectedMediaSourceProvider.notifier).state = mediaSource.id;
        }
      });
    } else if (selectedSourceId == null && info.mediaSources.length > 1) {
      // 未显式选择时，按该剧记忆的画质档位自动选回同档媒体源。
      final seriesId =
          ref.read(mediaItemProvider(itemId)).valueOrNull?.seriesId;
      final remembered =
          ref.read(seriesQualityMemoryProvider.notifier).recall(seriesId);
      if (remembered != null) {
        final match = info.mediaSources
            .where((s) => _sourceQualityLabel(s) == remembered)
            .firstOrNull;
        if (match != null && match.id != mediaSource.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ref.read(selectedMediaSourceProvider) == null) {
              ref.read(selectedMediaSourceProvider.notifier).state = match.id;
            }
          });
        }
      }
    }

    final audioStreams =
        mediaSource.mediaStreams.where((s) => s.isAudio).toList();
    final subtitleStreams =
        mediaSource.mediaStreams.where((s) => s.isSubtitle).toList();

    final selectedAudio =
        _resolveSelectedStream(audioStreams, selectedAudioIndex);

    final selectedSubtitle =
        _resolveSelectedStream(subtitleStreams, selectedSubtitleIndex);

    final availableSecondarySubs = subtitleStreams
        .where((s) =>
            selectedSubtitle == null || s.index != selectedSubtitle.index)
        .toList();
    // 次字幕默认为「无」：未显式选择时不回退到默认轨，避免误显示“已选第二条字幕”。
    final selectedSecondarySubtitle = selectedSecondarySubtitleIndex == null
        ? null
        : availableSecondarySubs
            .where((s) => s.index == selectedSecondarySubtitleIndex)
            .firstOrNull;
    if (selectedAudioIndex == null && selectedAudio?.index != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(audioTrackProvider) == null) {
          ref.read(audioTrackProvider.notifier).state = selectedAudio!.index;
        }
      });
    }
    if (selectedSubtitleIndex == null && selectedSubtitle?.index != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ref.read(subtitleTrackProvider) == null) {
          ref.read(subtitleTrackProvider.notifier).state =
              selectedSubtitle!.index;
        }
      });
    }

    final currentLine = server?.lines.isNotEmpty == true
        ? server!.lines[selectedLineIndex.clamp(0, server.lines.length - 1)]
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSection(
            sectionKey: 'line',
            icon: Icons.route,
            title: '线路选择',
            value: currentLine?.name ?? '当前线路',
            options: _buildLineOptions,
          ),
          if (info.mediaSources.length > 1)
            _buildSection(
              sectionKey: 'version',
              icon: Icons.layers,
              title: '版本选择',
              value: _sourceTitle(mediaSource),
              options: () => _buildVersionOptions(mediaSource.id),
            ),
          _buildSection(
            sectionKey: 'audio',
            icon: Icons.audiotrack,
            title: '音频选择',
            value: selectedAudio == null
                ? '默认音轨'
                : selectedAudio.readableLabel(siblings: audioStreams),
            options: () => _buildAudioOptions(audioStreams),
          ),
          _buildSection(
            sectionKey: 'subtitle',
            icon: Icons.subtitles,
            title: '字幕选择',
            value: selectedSubtitle == null
                ? '无字幕'
                : selectedSubtitle.readableLabel(siblings: subtitleStreams),
            options: () => _buildSubtitleOptions(subtitleStreams),
          ),
          _buildSection(
            sectionKey: 'secondary',
            icon: Icons.subtitles_outlined,
            title: '次字幕选择',
            value: selectedSecondarySubtitle == null
                ? '无'
                : selectedSecondarySubtitle.readableLabel(
                    siblings: availableSecondarySubs),
            options: () => _buildSecondarySubtitleOptions(availableSecondarySubs),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 各栏目展开后的选项列表
  // ---------------------------------------------------------------------------

  List<Widget> _buildLineOptions() {
    final server = ref.watch(currentServerProvider);
    if (server == null || server.lines.isEmpty) {
      return const [_EmptyOption(text: '无可用线路')];
    }
    return server.lines.asMap().entries.map((entry) {
      final idx = entry.key;
      final line = entry.value;
      return _OptionRow(
        title: line.name,
        subtitle: '',
        selected: idx == server.activeLineIndex,
        onTap: () {
          ref
              .read(serverListProvider.notifier)
              .setActiveLine(server.id, idx);
          final updatedServer = ref
              .read(serverListProvider)
              .firstWhere((s) => s.id == server.id);
          ref.read(currentServerProvider.notifier).state = updatedServer;
          ref.read(selectedMediaSourceProvider.notifier).state = null;
          ref.read(audioTrackProvider.notifier).state = null;
          ref.read(subtitleTrackProvider.notifier).state = null;
          ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          ref.invalidate(playbackInfoProvider(itemId));
          setState(() => _expanded = null);
        },
      );
    }).toList();
  }

  List<Widget> _buildVersionOptions(String currentSourceId) {
    final selectedSourceId =
        ref.watch(selectedMediaSourceProvider) ?? currentSourceId;
    return info.mediaSources.map((source) {
      return _OptionRow(
        title: _sourceTitle(source),
        subtitle: _sourceSummary(source),
        selected: source.id == selectedSourceId,
        onTap: () {
          ref.read(selectedMediaSourceProvider.notifier).state = source.id;
          // 记忆该剧画质：按视频分辨率档位记住，进入同剧其它分集自动选回。
          final seriesId =
              ref.read(mediaItemProvider(itemId)).valueOrNull?.seriesId;
          final label = _sourceQualityLabel(source);
          if (seriesId != null && label.isNotEmpty) {
            ref
                .read(seriesQualityMemoryProvider.notifier)
                .remember(seriesId, label);
          }
          ref.read(audioTrackProvider.notifier).state = null;
          ref.read(subtitleTrackProvider.notifier).state = null;
          ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          setState(() => _expanded = null);
        },
      );
    }).toList();
  }

  /// 媒体源的画质档位标签（取视频流分辨率，如 "1080p"/"4K"）。
  static String _sourceQualityLabel(MediaSource source) {
    final v = source.mediaStreams.where((s) => s.isVideo).firstOrNull;
    return v?.resolution ?? '';
  }

  List<Widget> _buildAudioOptions(List<MediaStream> streams) {
    if (streams.isEmpty) {
      return const [_EmptyOption(text: '无可用音轨')];
    }
    final currentIndex = ref.watch(audioTrackProvider);
    return streams.map((stream) {
      return _OptionRow(
        title: stream.readableLabel(siblings: streams),
        subtitle: _audioSummary(stream),
        selected: currentIndex == stream.index,
        onTap: () {
          ref.read(audioTrackProvider.notifier).state = stream.index;
          setState(() => _expanded = null);
        },
      );
    }).toList();
  }

  List<Widget> _buildSubtitleOptions(List<MediaStream> streams) {
    final currentIndex = ref.watch(subtitleTrackProvider);
    final secondaryIndex = ref.watch(secondarySubtitleTrackProvider);
    final rows = <Widget>[
      _OptionRow(
        title: '无字幕',
        subtitle: '',
        selected: currentIndex == null,
        onTap: () {
          ref.read(subtitleTrackProvider.notifier).state = null;
          setState(() => _expanded = null);
        },
      ),
    ];
    if (streams.isEmpty) {
      rows.add(const _EmptyOption(text: '无可用字幕'));
      return rows;
    }
    rows.addAll(streams.map((stream) {
      return _OptionRow(
        title: stream.readableLabel(siblings: streams),
        subtitle: _subtitleSummary(stream),
        selected: currentIndex == stream.index,
        onTap: () {
          ref.read(subtitleTrackProvider.notifier).state = stream.index;
          if (secondaryIndex == stream.index) {
            ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          }
          setState(() => _expanded = null);
        },
      );
    }));
    return rows;
  }

  List<Widget> _buildSecondarySubtitleOptions(List<MediaStream> streams) {
    final secondaryIndex = ref.watch(secondarySubtitleTrackProvider);
    final rows = <Widget>[
      _OptionRow(
        title: '关闭次字幕',
        subtitle: '',
        selected: secondaryIndex == null,
        onTap: () {
          ref.read(secondarySubtitleTrackProvider.notifier).state = null;
          setState(() => _expanded = null);
        },
      ),
    ];
    if (streams.isEmpty) {
      rows.add(const _EmptyOption(text: '无可用次字幕'));
      return rows;
    }
    rows.addAll(streams.map((stream) {
      return _OptionRow(
        title: stream.readableLabel(siblings: streams),
        subtitle: _subtitleSummary(stream),
        selected: secondaryIndex == stream.index,
        onTap: () {
          ref.read(secondarySubtitleTrackProvider.notifier).state =
              stream.index;
          setState(() => _expanded = null);
        },
      );
    }));
    return rows;
  }

  // ---------------------------------------------------------------------------
  // 展开式选择栏外壳
  // ---------------------------------------------------------------------------

  Widget _buildSection({
    required String sectionKey,
    required IconData icon,
    required String title,
    required String value,
    required List<Widget> Function() options,
  }) {
    final expanded = _expanded == sectionKey;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => _toggle(sectionKey),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                children: [
                  Icon(icon, size: 19),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 第一行：选项名称
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 1),
                        // 第二行：当前选中内容（缩小字体）
                        Text(
                          value,
                          style: TextStyle(
                            fontSize: 11.5,
                            color:
                                Theme.of(context).textTheme.bodySmall?.color,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more, size: 20),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1),
                      // 选项较多（如十几个版本）时不再撑长整页，限定高度内部滚动，
                      // 项目少时按内容自适应、不会出现多余空白或滚动条。
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: Scrollbar(
                          controller: _optionsScrollController,
                          child: SingleChildScrollView(
                            controller: _optionsScrollController,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: options(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 文案格式化
  // ---------------------------------------------------------------------------

  /// 版本标题：取 mediaSource 文件名，去掉容器后缀。
  static String _sourceTitle(MediaSource source) {
    final name = source.name?.trim();
    if (name != null && name.isNotEmpty) return _stripExtension(name);
    final path = source.path?.trim();
    if (path != null && path.isNotEmpty) {
      final seg = path.split(RegExp(r'[\\/]')).last;
      if (seg.isNotEmpty) return _stripExtension(seg);
    }
    return '默认版本';
  }

  /// 版本副标题：清晰度 / 码率 / 大小 / 容器格式。
  static String _sourceSummary(MediaSource source) {
    final video = source.mediaStreams.where((s) => s.isVideo).firstOrNull;
    final parts = <String>[];
    final res = video?.resolution ?? '';
    if (res.isNotEmpty) parts.add(res);

    int? bitrate = video?.bitRate;
    if ((bitrate == null || bitrate <= 0) &&
        source.size != null &&
        source.runTimeTicks != null &&
        source.runTimeTicks! > 0) {
      // ticks 为 100ns 单位：10,000,000 ticks = 1 秒
      final seconds = source.runTimeTicks! / 10000000;
      if (seconds > 0) {
        bitrate = (source.size! * 8 / seconds).round();
      }
    }
    final br = _formatBitrate(bitrate);
    if (br.isNotEmpty) parts.add(br);

    final size = _formatSize(source.size);
    if (size.isNotEmpty) parts.add(size);

    final container = source.container?.trim();
    if (container != null && container.isNotEmpty) {
      parts.add(container.toUpperCase());
    }
    return parts.join(' / ');
  }

  /// 音频副标题：编码 / 声道 / 码率 / 内封·外挂。
  static String _audioSummary(MediaStream s) {
    final parts = <String>[];
    final codec = s.codec?.trim();
    if (codec != null && codec.isNotEmpty) parts.add(codec.toUpperCase());
    if (s.channels != null && s.channels! > 0) parts.add('${s.channels}声道');
    final br = _formatBitrate(s.bitRate);
    if (br.isNotEmpty) parts.add(br);
    parts.add(s.isExternal == true ? '外挂' : '内封');
    return parts.join(' / ');
  }

  /// 字幕副标题：编码 / 内封·外挂。
  static String _subtitleSummary(MediaStream s) {
    final parts = <String>[];
    final codec = s.codec?.trim();
    if (codec != null && codec.isNotEmpty) parts.add(codec.toUpperCase());
    parts.add(s.isExternal == true ? '外挂' : '内封');
    return parts.join(' / ');
  }

  static const _containerExtensions = {
    'mkv', 'mp4', 'avi', 'ts', 'm2ts', 'mov', 'flv', 'wmv', 'webm',
    'rmvb', 'rm', 'm4v', 'mpg', 'mpeg', 'iso', 'vob', '3gp', 'ogm',
  };

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return name;
    final ext = name.substring(dot + 1).toLowerCase();
    // 仅去掉已知容器后缀，避免误删形如 "S01.1080p" 这类名称里的小数点段
    if (_containerExtensions.contains(ext)) return name.substring(0, dot);
    return name;
  }

  static String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    return '${(bytes / mb).toStringAsFixed(0)} MB';
  }

  static String _formatBitrate(int? bps) {
    if (bps == null || bps <= 0) return '';
    final mbps = bps / 1000000;
    if (mbps >= 1) return '${mbps.toStringAsFixed(1)} Mbps';
    return '${(bps / 1000).toStringAsFixed(0)} Kbps';
  }
}

/// 展开后的单个可选项：第一行加粗放大，第二行简略信息缩小。
class _OptionRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _OptionRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  static const _accent = Color(0xFF5B8DEF);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 第一行：文件名（无后缀）/ 轨道名
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? _accent : null,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    // 第二行：清晰度 / 码率 / 大小 / 容器，正常稍小
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 10),
              const Icon(Icons.check, color: _accent, size: 17),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyOption extends StatelessWidget {
  final String text;
  const _EmptyOption({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).textTheme.bodySmall?.color,
        ),
      ),
    );
  }
}
