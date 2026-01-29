import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'services/emby_api.dart';
import 'state/app_state.dart';
import 'state/server_profile.dart';
import 'state/preferences.dart';
import 'play_network_page.dart';
import 'play_network_page_exo.dart';
import 'src/ui/app_components.dart';
import 'src/ui/app_style.dart';
import 'src/ui/frosted_card.dart';
import 'src/ui/glass_blur.dart';

class ShowDetailPage extends StatefulWidget {
  const ShowDetailPage({
    super.key,
    required this.itemId,
    required this.title,
    required this.appState,
    this.server,
    this.isTv = false,
  });

  final String itemId;
  final String title;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;

  @override
  State<ShowDetailPage> createState() => _ShowDetailPageState();
}

class _ShowDetailPageState extends State<ShowDetailPage> {
  MediaItem? _detail;
  List<MediaItem> _seasons = [];
  bool _seasonsVirtual = false;
  List<MediaItem> _similar = [];
  bool _loading = true;
  String? _error;
  MediaItem? _featuredEpisode;
  String? _selectedSeasonId;
  final Map<String, List<MediaItem>> _episodesCache = {};
  List<String> _album = [];
  PlaybackInfoResult? _playInfo;
  List<ChapterInfo> _chapters = [];
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex; // null = default
  int? _selectedSubtitleStreamIndex; // null = default, -1 = off

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _refreshProgressAfterReturn(
      {Duration delay = const Duration(milliseconds: 350)}) async {
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) return;

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      serverType: widget.server?.serverType ?? widget.appState.serverType,
      deviceId: widget.appState.deviceId,
    );

    final before = _detail?.playbackPositionTicks;
    for (var attempt = 0; attempt < 3; attempt++) {
      final attemptDelay =
          attempt == 0 ? delay : const Duration(milliseconds: 300);
      if (attemptDelay > Duration.zero) {
        await Future<void>.delayed(attemptDelay);
      }

      try {
        final detail = await api.fetchItemDetail(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          itemId: widget.itemId,
        );
        if (!mounted) return;
        setState(() => _detail = detail);
        if (before == null || detail.playbackPositionTicks != before) return;
      } catch (_) {
        // Best-effort refresh. Keep existing state on failure.
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() {
        _error = '未连接服务器';
      });
      return;
    }

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      serverType: widget.server?.serverType ?? widget.appState.serverType,
      deviceId: widget.appState.deviceId,
    );
    try {
      final detail = await api.fetchItemDetail(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        itemId: widget.itemId,
      );
      final isSeries = detail.type.toLowerCase() == 'series';

      final seasons = isSeries
          ? await api.fetchSeasons(
              token: token,
              baseUrl: baseUrl,
              userId: userId,
              seriesId: widget.itemId,
            )
          : PagedResult<MediaItem>(const [], 0);

      final seasonItems = isSeries
          ? seasons.items
              .where((s) => s.type.toLowerCase() == 'season')
              .toList()
          : <MediaItem>[];
      seasonItems.sort((a, b) {
        final aNo = a.seasonNumber ?? a.episodeNumber ?? 0;
        final bNo = b.seasonNumber ?? b.episodeNumber ?? 0;
        return aNo.compareTo(bNo);
      });

      final virtualSeason = isSeries && seasonItems.isEmpty;
      final seasonsForUi = isSeries
          ? (virtualSeason
              ? [
                  MediaItem(
                    id: widget.itemId,
                    name: '第1季',
                    type: 'Season',
                    overview: '',
                    communityRating: null,
                    premiereDate: null,
                    genres: const [],
                    runTimeTicks: null,
                    sizeBytes: null,
                    container: null,
                    providerIds: const {},
                    seriesId: widget.itemId,
                    seriesName: detail.name,
                    seasonName: '第1季',
                    seasonNumber: 1,
                    episodeNumber: null,
                    hasImage: detail.hasImage,
                    playbackPositionTicks: 0,
                    people: const [],
                    parentId: widget.itemId,
                  ),
                ]
              : seasonItems)
          : <MediaItem>[];

      MediaItem? firstEp;
      if (isSeries) {
        final previousSeasonId = _selectedSeasonId;
        final defaultSeasonId = (virtualSeason
                ? widget.itemId
                : (seasonItems.isNotEmpty ? seasonItems.first.id : null)) ??
            '';
        final selectedSeasonId = (previousSeasonId != null &&
                seasonsForUi.any((s) => s.id == previousSeasonId))
            ? previousSeasonId
            : defaultSeasonId;

        if (selectedSeasonId.isNotEmpty) {
          try {
            final eps = await api.fetchEpisodes(
              token: token,
              baseUrl: baseUrl,
              userId: userId,
              seasonId: selectedSeasonId,
            );
            final items = List<MediaItem>.from(eps.items);
            items.sort((a, b) {
              final aNo = a.episodeNumber ?? 0;
              final bNo = b.episodeNumber ?? 0;
              return aNo.compareTo(bNo);
            });
            _episodesCache[selectedSeasonId] = items;
            if (items.isNotEmpty) firstEp = items.first;
          } catch (_) {}
        }
      }
      PagedResult<MediaItem> similar = PagedResult(const [], 0);
      try {
        similar = await api.fetchSimilar(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          itemId: widget.itemId,
          limit: 12,
        );
      } catch (_) {}

      PlaybackInfoResult? playInfo;
      List<ChapterInfo> chaps = const [];
      String? selectedMediaSourceId = _selectedMediaSourceId;
      int? selectedAudioStreamIndex = _selectedAudioStreamIndex;
      int? selectedSubtitleStreamIndex = _selectedSubtitleStreamIndex;
      if (!isSeries) {
        try {
          playInfo = await api.fetchPlaybackInfo(
            token: token,
            baseUrl: baseUrl,
            userId: userId,
            deviceId: widget.appState.deviceId,
            itemId: widget.itemId,
          );
          final sources = playInfo.mediaSources.cast<Map<String, dynamic>>();
          if (sources.isNotEmpty) {
            final validSelection = selectedMediaSourceId != null &&
                sources.any(
                    (s) => (s['Id'] as String? ?? '') == selectedMediaSourceId);
            if (!validSelection) {
              selectedMediaSourceId = _pickPreferredMediaSourceId(
                    sources,
                    widget.appState.preferredVideoVersion,
                  ) ??
                  (sources.first['Id'] as String?);
              selectedAudioStreamIndex = null;
              selectedSubtitleStreamIndex = null;
            }
          }
        } catch (_) {
          // PlaybackInfo is optional for the detail UI.
        }
        try {
          chaps = await api.fetchChapters(
            token: token,
            baseUrl: baseUrl,
            userId: userId,
            itemId: widget.itemId,
          );
        } catch (_) {
          // Chapters are optional; hide section when unavailable.
        }
      }
      _album = [
        EmbyApi.imageUrl(
          baseUrl: baseUrl,
          itemId: widget.itemId,
          token: token,
          apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
          imageType: 'Primary',
          maxWidth: 800,
        ),
        EmbyApi.imageUrl(
          baseUrl: baseUrl,
          itemId: widget.itemId,
          token: token,
          apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
          imageType: 'Backdrop',
          maxWidth: 1200,
        ),
      ];
      setState(() {
        _detail = detail;
        _seasons = seasonsForUi;
        _seasonsVirtual = virtualSeason;
        _featuredEpisode = firstEp;
        _selectedSeasonId = isSeries && seasonsForUi.isNotEmpty
            ? ((_selectedSeasonId != null &&
                    seasonsForUi.any((s) => s.id == _selectedSeasonId))
                ? _selectedSeasonId
                : seasonsForUi.first.id)
            : null;
        _similar = similar.items;
        _playInfo = playInfo;
        _chapters = chaps;
        _selectedMediaSourceId = selectedMediaSourceId;
        _selectedAudioStreamIndex = selectedAudioStreamIndex;
        _selectedSubtitleStreamIndex = selectedSubtitleStreamIndex;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _seasonLabel(MediaItem season, int index) {
    final name = season.name.trim();
    final seasonNo = season.seasonNumber ?? season.episodeNumber;
    return seasonNo != null
        ? '第$seasonNo季'
        : (name.isNotEmpty ? name : '第${index + 1}季');
  }

  MediaItem? get _selectedSeason {
    if (_seasons.isEmpty) return null;
    final selectedId = _selectedSeasonId;
    if (selectedId == null || selectedId.isEmpty) return _seasons.first;
    for (final s in _seasons) {
      if (s.id == selectedId) return s;
    }
    return _seasons.first;
  }

  String _selectedSeasonLabel() {
    if (_seasons.isEmpty) return '选择季';
    final selectedId = _selectedSeasonId;
    for (int i = 0; i < _seasons.length; i++) {
      final s = _seasons[i];
      if (selectedId != null && s.id == selectedId) return _seasonLabel(s, i);
    }
    return _seasonLabel(_seasons.first, 0);
  }

  Future<List<MediaItem>> _episodesForSeason(MediaItem season) async {
    final cached = _episodesCache[season.id];
    if (cached != null) return cached;
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) return const [];

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      serverType: widget.server?.serverType ?? widget.appState.serverType,
      deviceId: widget.appState.deviceId,
    );
    final eps = await api.fetchEpisodes(
      token: token,
      baseUrl: baseUrl,
      userId: userId,
      seasonId: season.id,
    );
    final items = List<MediaItem>.from(eps.items);
    items.sort((a, b) {
      final aNo = a.episodeNumber ?? 0;
      final bNo = b.episodeNumber ?? 0;
      return aNo.compareTo(bNo);
    });
    _episodesCache[season.id] = items;
    return items;
  }

  Future<void> _pickSeason(BuildContext context) async {
    if (_seasons.isEmpty) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('季选择')),
              ..._seasons.asMap().entries.map((entry) {
                final idx = entry.key;
                final s = entry.value;
                final selectedNow = s.id == _selectedSeasonId;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_seasonLabel(s, idx)),
                  onTap: () => Navigator.of(ctx).pop(s.id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.isEmpty || selected == _selectedSeasonId) {
      return;
    }

    setState(() {
      _selectedSeasonId = selected;
      _featuredEpisode = null;
    });

    final season = _selectedSeason;
    if (season == null) return;
    try {
      final episodes = await _episodesForSeason(season);
      if (!mounted || _selectedSeasonId != selected) return;
      setState(() {
        _featuredEpisode = episodes.isNotEmpty ? episodes.first : null;
      });
    } catch (_) {
      // Episode list is optional for the detail UI.
    }
  }

  String _episodeLabel(MediaItem episode, int index) {
    final epNo = episode.episodeNumber ?? (index + 1);
    final epName = episode.name.trim();
    return epName.isNotEmpty ? '$epNo. $epName' : '$epNo. 第$epNo集';
  }

  Future<void> _pickEpisode(BuildContext context) async {
    final season = _selectedSeason;
    if (season == null) return;

    final seasonLabel = _selectedSeasonLabel();
    final selectedEp = await showModalBottomSheet<MediaItem>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: widget.isTv ? 0.9 : 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              return FutureBuilder<List<MediaItem>>(
                future: _episodesForSeason(season),
                builder: (ctx, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        SizedBox(height: 24),
                        Center(child: CircularProgressIndicator()),
                      ],
                    );
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      controller: controller,
                      children: [
                        const ListTile(title: Text('选集')),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('加载失败：${snapshot.error}'),
                        ),
                      ],
                    );
                  }
                  final eps = snapshot.data ?? const <MediaItem>[];
                  if (eps.isEmpty) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无剧集'),
                        ),
                      ],
                    );
                  }

                  return ListView.separated(
                    controller: controller,
                    itemCount: eps.length + 1,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, index) {
                      if (index == 0) {
                        return ListTile(title: Text('选集（$seasonLabel）'));
                      }
                      final epIndex = index - 1;
                      final ep = eps[epIndex];
                      return ListTile(
                        leading: const Icon(Icons.play_circle_outline),
                        title: Text(_episodeLabel(ep, epIndex)),
                        onTap: () => Navigator.of(ctx).pop(ep),
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );

    if (!context.mounted) return;
    if (selectedEp == null) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EpisodeDetailPage(
          episode: selectedEp,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
        ),
      ),
    );
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static Map<String, dynamic>? _findMediaSource(
      PlaybackInfoResult info, String? id) {
    final sources = info.mediaSources.cast<Map<String, dynamic>>();
    if (sources.isEmpty) return null;
    if (id != null && id.isNotEmpty) {
      for (final s in sources) {
        if ((s['Id'] as String? ?? '') == id) return s;
      }
    }
    return sources.first;
  }

  static List<Map<String, dynamic>> _streamsOfType(
      Map<String, dynamic> ms, String type) {
    final streams = (ms['MediaStreams'] as List?) ?? const [];
    return streams
        .where((e) => (e as Map)['Type'] == type)
        .map((e) => e as Map<String, dynamic>)
        .toList();
  }

  static Map<String, dynamic>? _defaultStream(
      List<Map<String, dynamic>> streams) {
    for (final s in streams) {
      if (s['IsDefault'] == true) return s;
    }
    return streams.isNotEmpty ? streams.first : null;
  }

  static String _streamLabel(Map<String, dynamic> stream,
      {bool includeCodec = true}) {
    final title = (stream['DisplayTitle'] as String?) ??
        (stream['Title'] as String?) ??
        (stream['Language'] as String?) ??
        '未知';
    final codec = (stream['Codec'] as String?) ?? '';
    return includeCodec && codec.isNotEmpty ? '$title ($codec)' : title;
  }

  static String _mediaSourceTitle(Map<String, dynamic> ms) {
    return (ms['Name'] as String?) ?? (ms['Container'] as String?) ?? '默认版本';
  }

  static String? _pickPreferredMediaSourceId(
    List<Map<String, dynamic>> sources,
    VideoVersionPreference pref,
  ) {
    if (pref == VideoVersionPreference.defaultVersion) return null;

    int heightOf(Map<String, dynamic> ms) {
      final videos = _streamsOfType(ms, 'Video');
      final video = videos.isNotEmpty ? videos.first : null;
      return _asInt(video?['Height']) ?? 0;
    }

    int bitrateOf(Map<String, dynamic> ms) => _asInt(ms['Bitrate']) ?? 0;

    String codecOf(Map<String, dynamic> ms) {
      final videos = _streamsOfType(ms, 'Video');
      final video = videos.isNotEmpty ? videos.first : null;
      return ((ms['VideoCodec'] as String?) ??
              (video?['Codec'] as String?) ??
              '')
          .toLowerCase();
    }

    bool isHevc(Map<String, dynamic> ms) {
      final c = codecOf(ms);
      return c.contains('hevc') || c.contains('h265') || c.contains('x265');
    }

    bool isAvc(Map<String, dynamic> ms) {
      final c = codecOf(ms);
      return c.contains('h264') || c.contains('avc') || c.contains('x264');
    }

    Map<String, dynamic> pickBest(
      Iterable<Map<String, dynamic>> list, {
      required int Function(Map<String, dynamic>) primary,
      required int Function(Map<String, dynamic>) secondary,
      required bool higherIsBetter,
    }) {
      return list.reduce((a, b) {
        final ap = primary(a);
        final bp = primary(b);
        if (ap != bp) {
          return (higherIsBetter ? ap > bp : ap < bp) ? a : b;
        }
        final as = secondary(a);
        final bs = secondary(b);
        if (as != bs) {
          return (higherIsBetter ? as > bs : as < bs) ? a : b;
        }
        return a;
      });
    }

    Map<String, dynamic>? chosen;
    switch (pref) {
      case VideoVersionPreference.highestResolution:
        chosen = pickBest(
          sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.lowestBitrate:
        chosen = pickBest(
          sources,
          primary: (ms) => bitrateOf(ms) == 0 ? 1 << 30 : bitrateOf(ms),
          secondary: heightOf,
          higherIsBetter: false,
        );
        break;
      case VideoVersionPreference.preferHevc:
        final hevc = sources.where(isHevc).toList();
        chosen = pickBest(
          hevc.isNotEmpty ? hevc : sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.preferAvc:
        final avc = sources.where(isAvc).toList();
        chosen = pickBest(
          avc.isNotEmpty ? avc : sources,
          primary: heightOf,
          secondary: bitrateOf,
          higherIsBetter: true,
        );
        break;
      case VideoVersionPreference.defaultVersion:
        break;
    }

    final id = chosen?['Id']?.toString();
    return (id == null || id.trim().isEmpty) ? null : id.trim();
  }

  String _mediaSourceSubtitle(Map<String, dynamic> ms) {
    final size = ms['Size'];
    final sizeGb =
        size is num ? (size / (1024 * 1024 * 1024)).toStringAsFixed(1) : null;
    final bitrate = _asInt(ms['Bitrate']);
    final bitrateMbps =
        bitrate != null ? (bitrate / 1000000).toStringAsFixed(1) : null;

    final videoStreams = _streamsOfType(ms, 'Video');
    final video = videoStreams.isNotEmpty ? videoStreams.first : null;
    final height = _asInt(video?['Height']);
    final vCodec =
        (ms['VideoCodec'] as String?) ?? (video?['Codec'] as String?);

    final parts = <String>[];
    if (height != null) parts.add('${height}p');
    if (vCodec != null && vCodec.isNotEmpty) parts.add(vCodec.toUpperCase());
    if (sizeGb != null) parts.add('$sizeGb GB');
    if (bitrateMbps != null) parts.add('$bitrateMbps Mbps');
    return parts.isEmpty ? '直连播放' : parts.join(' / ');
  }

  Widget _floatingPlaybackSettingsDock(
    BuildContext context,
    PlaybackInfoResult info, {
    required bool enableBlur,
  }) {
    final ms = _findMediaSource(info, _selectedMediaSourceId);
    if (ms == null) return const SizedBox.shrink();

    final audioStreams = _streamsOfType(ms, 'Audio');
    final subtitleStreams = _streamsOfType(ms, 'Subtitle');

    final defaultAudio = _defaultStream(audioStreams);
    final selectedAudio = _selectedAudioStreamIndex != null
        ? audioStreams.firstWhere(
            (s) => _asInt(s['Index']) == _selectedAudioStreamIndex,
            orElse: () => defaultAudio ?? const <String, dynamic>{},
          )
        : defaultAudio;

    final audioText = selectedAudio != null && selectedAudio.isNotEmpty
        ? _streamLabel(selectedAudio, includeCodec: false) +
            (selectedAudio == defaultAudio ? ' (默认)' : '')
        : '默认';

    final defaultSub = _defaultStream(subtitleStreams);
    final Map<String, dynamic>? selectedSub;
    if (_selectedSubtitleStreamIndex == -1) {
      selectedSub = null;
    } else if (_selectedSubtitleStreamIndex != null) {
      selectedSub = subtitleStreams.firstWhere(
        (s) => _asInt(s['Index']) == _selectedSubtitleStreamIndex,
        orElse: () => defaultSub ?? const <String, dynamic>{},
      );
    } else {
      selectedSub = defaultSub;
    }

    final hasSubs = subtitleStreams.isNotEmpty;
    final subtitleText = _selectedSubtitleStreamIndex == -1
        ? '关闭'
        : selectedSub != null && selectedSub.isNotEmpty
            ? _streamLabel(selectedSub, includeCodec: false)
            : hasSubs
                ? '默认'
                : '关闭';

    final scheme = Theme.of(context).colorScheme;
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);

    const radius = 24.0;
    final dividerColor = scheme.outlineVariant.withValues(alpha: 0.35);

    Widget divider() => Container(width: 1, height: 26, color: dividerColor);

    Widget segment({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onTap,
      required BorderRadius borderRadius,
    }) {
      final enabled = onTap != null;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Icon(
              icon,
              size: 20,
              color: enabled ? scheme.onSurface : disabledColor,
            ),
          ),
        ),
      );
    }

    return FrostedCard(
      enableBlur: enableBlur,
      borderRadius: radius,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            segment(
              icon: Icons.video_file_outlined,
              tooltip:
                  '版本：${_mediaSourceTitle(ms)}\n${_mediaSourceSubtitle(ms)}',
              onTap: () => _pickMediaSource(context, info),
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(radius)),
            ),
            divider(),
            segment(
              icon: Icons.audiotrack,
              tooltip: '音轨：$audioText',
              onTap: audioStreams.isEmpty
                  ? null
                  : () => _pickAudioStream(context, ms),
              borderRadius: BorderRadius.zero,
            ),
            divider(),
            segment(
              icon: Icons.subtitles,
              tooltip: '字幕：$subtitleText',
              onTap: hasSubs ? () => _pickSubtitleStream(context, ms) : null,
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(radius)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moviePlaybackOptionsCard(
      BuildContext context, PlaybackInfoResult info) {
    final ms = _findMediaSource(info, _selectedMediaSourceId);
    if (ms == null) return const SizedBox.shrink();

    final audioStreams = _streamsOfType(ms, 'Audio');
    final subtitleStreams = _streamsOfType(ms, 'Subtitle');

    final defaultAudio = _defaultStream(audioStreams);
    final selectedAudio = _selectedAudioStreamIndex != null
        ? audioStreams.firstWhere(
            (s) => _asInt(s['Index']) == _selectedAudioStreamIndex,
            orElse: () => defaultAudio ?? const <String, dynamic>{},
          )
        : defaultAudio;

    final defaultSub = _defaultStream(subtitleStreams);
    final Map<String, dynamic>? selectedSub;
    if (_selectedSubtitleStreamIndex == -1) {
      selectedSub = null;
    } else if (_selectedSubtitleStreamIndex != null) {
      selectedSub = subtitleStreams.firstWhere(
        (s) => _asInt(s['Index']) == _selectedSubtitleStreamIndex,
        orElse: () => defaultSub ?? const <String, dynamic>{},
      );
    } else {
      selectedSub = defaultSub;
    }

    final hasSubs = subtitleStreams.isNotEmpty;
    final subtitleText = _selectedSubtitleStreamIndex == -1
        ? '关闭'
        : selectedSub != null && selectedSub.isNotEmpty
            ? _streamLabel(selectedSub, includeCodec: false)
            : hasSubs
                ? '默认'
                : '关闭';

    final audioText = selectedAudio != null && selectedAudio.isNotEmpty
        ? _streamLabel(selectedAudio, includeCodec: false) +
            (selectedAudio == defaultAudio ? ' (默认)' : '')
        : '默认';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.video_file),
            title: Text(_mediaSourceTitle(ms)),
            subtitle: Text(_mediaSourceSubtitle(ms)),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: () => _pickMediaSource(context, info),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.audiotrack),
            title: Text(audioText),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: audioStreams.isEmpty
                ? null
                : () => _pickAudioStream(context, ms),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.subtitles),
            title: Text(subtitleText),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: hasSubs ? () => _pickSubtitleStream(context, ms) : null,
          ),
        ],
      ),
    );
  }

  Future<void> _pickMediaSource(
      BuildContext context, PlaybackInfoResult info) async {
    final sources = info.mediaSources.cast<Map<String, dynamic>>();
    if (sources.isEmpty) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('版本选择')),
              ...sources.map((ms) {
                final id = ms['Id'] as String? ?? '';
                final selectedNow =
                    id.isNotEmpty && id == _selectedMediaSourceId;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_mediaSourceTitle(ms)),
                  subtitle: Text(_mediaSourceSubtitle(ms)),
                  onTap: () => Navigator.of(ctx).pop(id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.isEmpty) return;
    setState(() {
      _selectedMediaSourceId = selected;
      // Streams differ between sources; reset to defaults.
      _selectedAudioStreamIndex = null;
      _selectedSubtitleStreamIndex = null;
    });
  }

  Future<void> _pickAudioStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final audioStreams = _streamsOfType(ms, 'Audio');
    if (audioStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _defaultStream(audioStreams);
        final defIndex = _asInt(def?['Index']);
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('音轨选择')),
              ListTile(
                leading: Icon(_selectedAudioStreamIndex == null
                    ? Icons.check
                    : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...audioStreams.map((s) {
                final idx = _asInt(s['Index']);
                final selectedNow =
                    idx != null && idx == _selectedAudioStreamIndex;
                final title = _streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedAudioStreamIndex = selected);
  }

  Future<void> _pickSubtitleStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final subtitleStreams = _streamsOfType(ms, 'Subtitle');
    if (subtitleStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _defaultStream(subtitleStreams);
        final defIndex = _asInt(def?['Index']);
        final isOff = _selectedSubtitleStreamIndex == -1;
        final isDefault = _selectedSubtitleStreamIndex == null;
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('字幕选择')),
              ListTile(
                leading: Icon(isOff ? Icons.check : Icons.circle_outlined),
                title: const Text('关闭'),
                onTap: () => Navigator.of(ctx).pop(-1),
              ),
              ListTile(
                leading: Icon(isDefault ? Icons.check : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...subtitleStreams.map((s) {
                final idx = _asInt(s['Index']);
                final selectedNow =
                    idx != null && idx == _selectedSubtitleStreamIndex;
                final title = _streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedSubtitleStreamIndex = selected);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    if (_error != null || _detail == null) {
      return Scaffold(
        appBar: GlassAppBar(
          enableBlur: enableBlur,
          child: AppBar(title: Text(widget.title)),
        ),
        body: Center(child: Text(_error ?? '加载失败')),
      );
    }
    final item = _detail!;
    final isSeries = item.type.toLowerCase() == 'series';
    final playInfo = _playInfo;
    final showFloatingSettings = !widget.isTv &&
        !isSeries &&
        playInfo != null &&
        _findMediaSource(playInfo, _selectedMediaSourceId) != null;
    final runtime = item.runTimeTicks != null
        ? Duration(microseconds: item.runTimeTicks! ~/ 10)
        : null;
    final hero = EmbyApi.imageUrl(
      baseUrl: _baseUrl!,
      itemId: item.id,
      token: _token!,
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      imageType: 'Primary',
      maxWidth: 1200,
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.extension<AppStyle>() ?? const AppStyle();
    final template = style.template;
    final isDark = scheme.brightness == Brightness.dark;

    const grayscale = ColorFilter.matrix(<double>[
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);

    final heroFilter = switch (template) {
      UiTemplate.mangaStoryboard => grayscale,
      UiTemplate.neonHud => ColorFilter.mode(
          scheme.primary.withValues(alpha: isDark ? 0.18 : 0.12),
          BlendMode.overlay,
        ),
      UiTemplate.pixelArcade => ColorFilter.mode(
          scheme.secondary.withValues(alpha: isDark ? 0.18 : 0.12),
          BlendMode.overlay,
        ),
      UiTemplate.candyGlass => ColorFilter.mode(
          scheme.secondary.withValues(alpha: isDark ? 0.10 : 0.08),
          BlendMode.softLight,
        ),
      UiTemplate.stickerJournal => ColorFilter.mode(
          scheme.secondary.withValues(alpha: isDark ? 0.10 : 0.08),
          BlendMode.softLight,
        ),
      UiTemplate.washiWatercolor => ColorFilter.mode(
          scheme.tertiary.withValues(alpha: isDark ? 0.10 : 0.08),
          BlendMode.softLight,
        ),
      UiTemplate.proTool => null,
      UiTemplate.minimalCovers => null,
    };

    final scrimBottom = switch (template) {
      UiTemplate.neonHud =>
        Color.lerp(Colors.black, scheme.primary, 0.22)!.withValues(
          alpha: isDark ? 0.74 : 0.62,
        ),
      UiTemplate.pixelArcade =>
        Color.lerp(Colors.black, scheme.secondary, 0.18)!.withValues(
          alpha: isDark ? 0.74 : 0.62,
        ),
      UiTemplate.stickerJournal =>
        Color.lerp(Colors.black, scheme.secondary, 0.14)!.withValues(
          alpha: isDark ? 0.70 : 0.60,
        ),
      UiTemplate.candyGlass =>
        Color.lerp(Colors.black, scheme.primary, 0.12)!.withValues(
          alpha: isDark ? 0.68 : 0.58,
        ),
      UiTemplate.washiWatercolor =>
        Color.lerp(Colors.black, scheme.tertiary, 0.10)!.withValues(
          alpha: isDark ? 0.66 : 0.56,
        ),
      UiTemplate.mangaStoryboard => isDark
          ? Colors.black.withValues(alpha: 0.76)
          : Colors.white.withValues(alpha: 0.82),
      UiTemplate.proTool =>
        Colors.black.withValues(alpha: isDark ? 0.68 : 0.58),
      UiTemplate.minimalCovers =>
        Colors.black.withValues(alpha: isDark ? 0.64 : 0.55),
    };

    final heroTitleColor = (template == UiTemplate.mangaStoryboard && !isDark)
        ? Colors.black
        : Colors.white;

    Widget heroImage = Image.network(
      hero,
      fit: BoxFit.cover,
      headers: {'User-Agent': EmbyApi.userAgent},
      errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26),
    );
    if (heroFilter != null) {
      heroImage = ColorFiltered(colorFilter: heroFilter, child: heroImage);
    }

    return Scaffold(
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _load,
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 320,
                  flexibleSpace: FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        heroImage,
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, scrimBottom],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 16,
                          bottom: 16,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.name,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                          color: heroTitleColor,
                                          fontWeight: FontWeight.w700)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  if (item.communityRating != null)
                                    _pill(context,
                                        '★ ${item.communityRating!.toStringAsFixed(1)}'),
                                  if (item.premiereDate != null)
                                    _pill(context,
                                        item.premiereDate!.split('T').first),
                                  if (item.genres.isNotEmpty)
                                    _pill(context, item.genres.first),
                                  if (isSeries)
                                    _pill(context, '${_seasons.length} 季')
                                  else if (runtime != null)
                                    _pill(context, _fmt(runtime)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_featuredEpisode != null)
                          _playButton(
                            context,
                            label:
                                '播放 S${_featuredEpisode!.seasonNumber ?? 1}:E${_featuredEpisode!.episodeNumber ?? 1}',
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => EpisodeDetailPage(
                                    episode: _featuredEpisode!,
                                    appState: widget.appState,
                                    server: widget.server,
                                    isTv: widget.isTv,
                                  ),
                                ),
                              );
                            },
                          ),
                        if (!isSeries) ...[
                          if (playInfo != null && !showFloatingSettings)
                            _moviePlaybackOptionsCard(context, playInfo),
                          if (playInfo != null && !showFloatingSettings)
                            const SizedBox(height: 12),
                          _playButton(
                            context,
                            label: item.playbackPositionTicks > 0
                                ? '继续播放（${_fmtClock(_ticksToDuration(item.playbackPositionTicks))}）'
                                : '播放',
                            onTap: () async {
                              final start = item.playbackPositionTicks > 0
                                  ? _ticksToDuration(item.playbackPositionTicks)
                                  : null;
                              final useExoCore = !kIsWeb &&
                                  defaultTargetPlatform ==
                                      TargetPlatform.android &&
                                  widget.appState.playerCore == PlayerCore.exo;
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => useExoCore
                                      ? ExoPlayNetworkPage(
                                          title: item.name,
                                          itemId: item.id,
                                          appState: widget.appState,
                                          server: widget.server,
                                          isTv: widget.isTv,
                                          startPosition: start,
                                          mediaSourceId: _selectedMediaSourceId,
                                          audioStreamIndex:
                                              _selectedAudioStreamIndex,
                                          subtitleStreamIndex:
                                              _selectedSubtitleStreamIndex,
                                        )
                                      : PlayNetworkPage(
                                          title: item.name,
                                          itemId: item.id,
                                          appState: widget.appState,
                                          server: widget.server,
                                          isTv: widget.isTv,
                                          startPosition: start,
                                          mediaSourceId: _selectedMediaSourceId,
                                          audioStreamIndex:
                                              _selectedAudioStreamIndex,
                                          subtitleStreamIndex:
                                              _selectedSubtitleStreamIndex,
                                        ),
                                ),
                              );
                              if (!mounted) return;
                              await _refreshProgressAfterReturn();
                            },
                          ),
                        ],
                        if (isSeries && _seasons.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          AppPanel(
                            enableBlur: enableBlur,
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => _pickSeason(context),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const Icon(Icons.layers_outlined,
                                            size: 18),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            '季：${_selectedSeasonLabel()}',
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Icon(Icons.arrow_drop_down),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _selectedSeason == null
                                        ? null
                                        : () => _pickEpisode(context),
                                    child: const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.format_list_numbered,
                                            size: 18),
                                        SizedBox(width: 8),
                                        Text('选集'),
                                        SizedBox(width: 4),
                                        Icon(Icons.arrow_drop_down),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ] else
                          const SizedBox(height: 12),
                        Text(item.overview,
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 16),
                        if (_chapters.isNotEmpty) ...[
                          _chaptersSection(context, _chapters),
                          const SizedBox(height: 16),
                        ],
                        if (item.people.isNotEmpty) ...[
                          _peopleSection(
                            context,
                            item.people,
                            baseUrl: _baseUrl!,
                            token: _token!,
                            apiPrefix: widget.server?.apiPrefix ??
                                widget.appState.apiPrefix,
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_album.isNotEmpty) ...[
                          Text('相册',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 140,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _album.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 10),
                              itemBuilder: (context, index) {
                                final url = _album[index];
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.network(
                                    url,
                                    width: 220,
                                    height: 140,
                                    fit: BoxFit.cover,
                                    headers: {'User-Agent': EmbyApi.userAgent},
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox(
                                      width: 220,
                                      height: 140,
                                      child: ColoredBox(color: Colors.black26),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_seasons.isNotEmpty) ...[
                          Text('季',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: widget.isTv ? 260 : 220,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _seasons.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (context, index) {
                                final s = _seasons[index];
                                final label = _seasonLabel(s, index);
                                final img = EmbyApi.imageUrl(
                                  baseUrl: _baseUrl!,
                                  itemId: s.hasImage ? s.id : item.id,
                                  token: _token!,
                                  apiPrefix: widget.server?.apiPrefix ??
                                      widget.appState.apiPrefix,
                                  maxWidth: widget.isTv ? 600 : 400,
                                );
                                return SizedBox(
                                  width: widget.isTv ? 200 : 140,
                                  child: MediaPosterTile(
                                    title: label,
                                    imageUrl: img,
                                    onTap: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => SeasonEpisodesPage(
                                            season: s,
                                            appState: widget.appState,
                                            server: widget.server,
                                            isTv: widget.isTv,
                                            isVirtual: _seasonsVirtual,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (_similar.isNotEmpty) ...[
                          Text('更多类似',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 240,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: _similar.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (context, index) {
                                final s = _similar[index];
                                final img = s.hasImage
                                    ? EmbyApi.imageUrl(
                                        baseUrl: _baseUrl!,
                                        itemId: s.id,
                                        token: _token!,
                                        apiPrefix: widget.server?.apiPrefix ??
                                            widget.appState.apiPrefix,
                                        maxWidth: 400,
                                      )
                                    : null;
                                final date = (s.premiereDate ?? '').trim();
                                final parsed = date.isEmpty
                                    ? null
                                    : DateTime.tryParse(date);
                                final year = parsed != null
                                    ? parsed.year.toString()
                                    : (date.length >= 4
                                        ? date.substring(0, 4)
                                        : '');
                                final badge = s.type == 'Movie'
                                    ? '电影'
                                    : (s.type == 'Series' ? '剧集' : '');

                                return SizedBox(
                                  width: 140,
                                  child: MediaPosterTile(
                                    title: s.name,
                                    titleMaxLines: 2,
                                    imageUrl: img,
                                    year: year,
                                    rating: s.communityRating,
                                    badgeText: badge,
                                    onTap: () {
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => ShowDetailPage(
                                            itemId: s.id,
                                            title: s.name,
                                            appState: widget.appState,
                                            server: widget.server,
                                            isTv: widget.isTv,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        _externalLinksSection(context, item, widget.appState),
                        if (showFloatingSettings) const SizedBox(height: 88),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (showFloatingSettings)
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                left: false,
                right: false,
                minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _floatingPlaybackSettingsDock(
                  context,
                  playInfo,
                  enableBlur: enableBlur,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SeasonEpisodesPage extends StatefulWidget {
  const SeasonEpisodesPage({
    super.key,
    required this.season,
    required this.appState,
    this.server,
    this.isTv = false,
    this.isVirtual = false,
  });

  final MediaItem season;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;
  final bool isVirtual;

  @override
  State<SeasonEpisodesPage> createState() => _SeasonEpisodesPageState();
}

class _SeasonEpisodesPageState extends State<SeasonEpisodesPage> {
  List<MediaItem> _episodes = [];
  bool _loading = true;
  String? _error;
  MediaItem? _detailSeason;

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() {
        _error = '未连接服务器';
        _loading = false;
      });
      return;
    }

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      serverType: widget.server?.serverType ?? widget.appState.serverType,
      deviceId: widget.appState.deviceId,
    );
    try {
      final eps = await api.fetchEpisodes(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        seasonId: widget.season.id,
      );
      final items = List<MediaItem>.from(eps.items);
      items.sort((a, b) {
        final aNo = a.episodeNumber ?? 0;
        final bNo = b.episodeNumber ?? 0;
        return aNo.compareTo(bNo);
      });
      MediaItem? detail;
      if (!widget.isVirtual) {
        try {
          detail = await api.fetchItemDetail(
            token: token,
            baseUrl: baseUrl,
            userId: userId,
            itemId: widget.season.id,
          );
        } catch (_) {}
      }
      setState(() {
        _episodes = items;
        _detailSeason = detail;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seasonName = _detailSeason?.name ?? widget.season.name;
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    return Scaffold(
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(title: Text(seasonName)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _episodes.isEmpty
                  ? const Center(child: Text('暂无剧集'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _episodes.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final e = _episodes[index];
                        final epNo = e.episodeNumber ?? (index + 1);
                        final epName = e.name.trim();
                        final titleText = epName.isNotEmpty
                            ? '$epNo. $epName'
                            : '$epNo. 第$epNo集';
                        final dur = e.runTimeTicks != null
                            ? Duration(
                                microseconds: (e.runTimeTicks! / 10).round())
                            : null;
                        final img = EmbyApi.imageUrl(
                          baseUrl: _baseUrl!,
                          itemId: e.hasImage ? e.id : widget.season.id,
                          token: _token!,
                          apiPrefix: widget.server?.apiPrefix ??
                              widget.appState.apiPrefix,
                          maxWidth: widget.isTv ? 900 : 700,
                        );
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => EpisodeDetailPage(
                                    episode: e,
                                    appState: widget.appState,
                                    server: widget.server,
                                    isTv: widget.isTv,
                                  ),
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: widget.isTv ? 260 : 170,
                                        child: AspectRatio(
                                          aspectRatio: 16 / 9,
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            child: Image.network(
                                              img,
                                              fit: BoxFit.cover,
                                              headers: {
                                                'User-Agent': EmbyApi.userAgent
                                              },
                                              errorBuilder: (_, __, ___) =>
                                                  const ColoredBox(
                                                      color: Colors.black26),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              titleText,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700),
                                            ),
                                            if (dur != null) ...[
                                              const SizedBox(height: 6),
                                              Text(
                                                _fmt(dur),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (e.overview.isNotEmpty) ...[
                                    const SizedBox(height: 10),
                                    Text(
                                      e.overview,
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class EpisodeDetailPage extends StatefulWidget {
  const EpisodeDetailPage({
    super.key,
    required this.episode,
    required this.appState,
    this.server,
    this.isTv = false,
  });

  final MediaItem episode;
  final AppState appState;
  final ServerProfile? server;
  final bool isTv;

  @override
  State<EpisodeDetailPage> createState() => _EpisodeDetailPageState();
}

class _EpisodeDetailPageState extends State<EpisodeDetailPage> {
  PlaybackInfoResult? _playInfo;
  String? _selectedMediaSourceId;
  int? _selectedAudioStreamIndex; // null = default
  int? _selectedSubtitleStreamIndex; // null = default, -1 = off
  String? _error;
  bool _loading = true;
  MediaItem? _detail;
  List<ChapterInfo> _chapters = [];
  String? _seriesId;
  String _seriesName = '';
  List<MediaItem> _seasons = [];
  bool _seasonsVirtual = false;
  String? _selectedSeasonId;
  final Map<String, List<MediaItem>> _episodesCache = {};
  String? _seriesError;
  bool _seriesLoading = false;

  String? get _baseUrl => widget.server?.baseUrl ?? widget.appState.baseUrl;
  String? get _token => widget.server?.token ?? widget.appState.token;
  String? get _userId => widget.server?.userId ?? widget.appState.userId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _refreshProgressAfterReturn(
      {Duration delay = const Duration(milliseconds: 350)}) async {
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) return;

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      serverType: widget.server?.serverType ?? widget.appState.serverType,
      deviceId: widget.appState.deviceId,
    );

    final before = _detail?.playbackPositionTicks;
    for (var attempt = 0; attempt < 3; attempt++) {
      final attemptDelay =
          attempt == 0 ? delay : const Duration(milliseconds: 300);
      if (attemptDelay > Duration.zero) {
        await Future<void>.delayed(attemptDelay);
      }

      try {
        final detail = await api.fetchItemDetail(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          itemId: widget.episode.id,
        );
        if (!mounted) return;
        setState(() => _detail = detail);
        if (before == null || detail.playbackPositionTicks != before) return;
      } catch (_) {
        // Best-effort refresh. Keep existing state on failure.
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) {
      setState(() {
        _error = '未连接服务器';
        _loading = false;
      });
      return;
    }

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      serverType: widget.server?.serverType ?? widget.appState.serverType,
      deviceId: widget.appState.deviceId,
    );
    try {
      final detail = await api.fetchItemDetail(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        itemId: widget.episode.id,
      );

      final resolvedSeriesId =
          (detail.seriesId ?? widget.episode.seriesId ?? '').trim();
      final resolvedSeriesName = detail.seriesName.trim().isNotEmpty
          ? detail.seriesName.trim()
          : widget.episode.seriesName.trim();

      if (resolvedSeriesId.isNotEmpty) {
        setState(() {
          _seriesId = resolvedSeriesId;
          _seriesName = resolvedSeriesName;
          _seriesLoading = true;
        });
        unawaited(
          _loadSeriesEpisodes(
            api: api,
            token: token,
            baseUrl: baseUrl,
            userId: userId,
            episodeDetail: detail,
            seriesId: resolvedSeriesId,
            seriesName: resolvedSeriesName,
          ),
        );
      }
      final info = await api.fetchPlaybackInfo(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        deviceId: widget.appState.deviceId,
        itemId: widget.episode.id,
      );
      final sources = info.mediaSources.cast<Map<String, dynamic>>();
      final preferred = sources.isEmpty
          ? null
          : _ShowDetailPageState._pickPreferredMediaSourceId(
              sources,
              widget.appState.preferredVideoVersion,
            );

      final serverId = widget.server?.id ?? widget.appState.activeServerId;
      final seriesId = resolvedSeriesId.trim();

      String? selectedMediaSourceId = _selectedMediaSourceId;
      if ((selectedMediaSourceId ?? '').trim().isEmpty &&
          serverId != null &&
          serverId.trim().isNotEmpty &&
          seriesId.isNotEmpty &&
          sources.isNotEmpty) {
        final idx = widget.appState
            .seriesMediaSourceIndex(serverId: serverId.trim(), seriesId: seriesId);
        if (idx != null && idx >= 0 && idx < sources.length) {
          selectedMediaSourceId = sources[idx]['Id']?.toString();
        }
      }
      selectedMediaSourceId = (selectedMediaSourceId ?? '').trim();
      if (selectedMediaSourceId.isEmpty) {
        selectedMediaSourceId = (preferred ?? '').trim();
      }
      if (selectedMediaSourceId.isEmpty && sources.isNotEmpty) {
        selectedMediaSourceId = (sources.first['Id']?.toString() ?? '').trim();
      }
      if (selectedMediaSourceId.isEmpty) selectedMediaSourceId = null;

      int? selectedAudioStreamIndex = _selectedAudioStreamIndex;
      int? selectedSubtitleStreamIndex = _selectedSubtitleStreamIndex;
      if (serverId != null &&
          serverId.trim().isNotEmpty &&
          seriesId.isNotEmpty) {
        selectedAudioStreamIndex ??= widget.appState
            .seriesAudioStreamIndex(serverId: serverId.trim(), seriesId: seriesId);
        selectedSubtitleStreamIndex ??= widget.appState.seriesSubtitleStreamIndex(
          serverId: serverId.trim(),
          seriesId: seriesId,
        );
      }
      List<ChapterInfo> chaps = const [];
      try {
        chaps = await api.fetchChapters(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          itemId: widget.episode.id,
        );
      } catch (_) {
        // Chapters are optional; hide section when unavailable.
      }
      setState(() {
        _playInfo = info;
        _detail = detail;
        _chapters = chaps;
        _selectedMediaSourceId = selectedMediaSourceId;
        _selectedAudioStreamIndex = selectedAudioStreamIndex;
        _selectedSubtitleStreamIndex = selectedSubtitleStreamIndex;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _mediaSourceSubtitle(Map<String, dynamic> ms) {
    final size = ms['Size'];
    final sizeGb =
        size is num ? (size / (1024 * 1024 * 1024)).toStringAsFixed(1) : null;
    final bitrate = _ShowDetailPageState._asInt(ms['Bitrate']);
    final bitrateMbps =
        bitrate != null ? (bitrate / 1000000).toStringAsFixed(1) : null;

    final videoStreams = _ShowDetailPageState._streamsOfType(ms, 'Video');
    final video = videoStreams.isNotEmpty ? videoStreams.first : null;
    final height = _ShowDetailPageState._asInt(video?['Height']);
    final vCodec =
        (ms['VideoCodec'] as String?) ?? (video?['Codec'] as String?);

    final parts = <String>[];
    if (height != null) parts.add('${height}p');
    if (vCodec != null && vCodec.isNotEmpty) parts.add(vCodec.toUpperCase());
    if (sizeGb != null) parts.add('$sizeGb GB');
    if (bitrateMbps != null) parts.add('$bitrateMbps Mbps');
    return parts.isEmpty ? '直连播放' : parts.join(' / ');
  }

  Widget _episodePlaybackOptionsCard(
      BuildContext context, PlaybackInfoResult info) {
    final ms = _ShowDetailPageState._findMediaSource(info, _selectedMediaSourceId);
    if (ms == null) return const SizedBox.shrink();

    final audioStreams = _ShowDetailPageState._streamsOfType(ms, 'Audio');
    final subtitleStreams = _ShowDetailPageState._streamsOfType(ms, 'Subtitle');

    final defaultAudio = _ShowDetailPageState._defaultStream(audioStreams);
    final selectedAudio = _selectedAudioStreamIndex != null
        ? audioStreams.firstWhere(
            (s) =>
                _ShowDetailPageState._asInt(s['Index']) == _selectedAudioStreamIndex,
            orElse: () => defaultAudio ?? const <String, dynamic>{},
          )
        : defaultAudio;

    final defaultSub = _ShowDetailPageState._defaultStream(subtitleStreams);
    final Map<String, dynamic>? selectedSub;
    if (_selectedSubtitleStreamIndex == -1) {
      selectedSub = null;
    } else if (_selectedSubtitleStreamIndex != null) {
      selectedSub = subtitleStreams.firstWhere(
        (s) =>
            _ShowDetailPageState._asInt(s['Index']) == _selectedSubtitleStreamIndex,
        orElse: () => defaultSub ?? const <String, dynamic>{},
      );
    } else {
      selectedSub = defaultSub;
    }

    final hasSubs = subtitleStreams.isNotEmpty;
    final subtitleText = _selectedSubtitleStreamIndex == -1
        ? '关闭'
        : selectedSub != null && selectedSub.isNotEmpty
            ? _ShowDetailPageState._streamLabel(selectedSub, includeCodec: false)
            : hasSubs
                ? '默认'
                : '关闭';

    final audioText = selectedAudio != null && selectedAudio.isNotEmpty
        ? _ShowDetailPageState._streamLabel(selectedAudio, includeCodec: false) +
            (selectedAudio == defaultAudio ? ' (默认)' : '')
        : '默认';

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.video_file),
                title: Text(_ShowDetailPageState._mediaSourceTitle(ms)),
                subtitle: Text(_mediaSourceSubtitle(ms)),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: () => _pickMediaSource(context, info),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.audiotrack),
                title: Text(audioText),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: audioStreams.isEmpty
                    ? null
                    : () => _pickAudioStream(context, ms),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.subtitles),
                title: Text(subtitleText),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: hasSubs ? () => _pickSubtitleStream(context, ms) : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '提示：以上选择会应用到本剧后续集数',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _pickMediaSource(
      BuildContext context, PlaybackInfoResult info) async {
    final sources = info.mediaSources.cast<Map<String, dynamic>>();
    if (sources.isEmpty) return;

    final current = (_selectedMediaSourceId ?? '').trim();
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('版本选择')),
              ...sources.map((ms) {
                final id = (ms['Id']?.toString() ?? '').trim();
                final selectedNow = id.isNotEmpty && id == current;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_ShowDetailPageState._mediaSourceTitle(ms)),
                  subtitle: Text(_mediaSourceSubtitle(ms)),
                  onTap: id.isEmpty ? null : () => Navigator.of(ctx).pop(id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    final picked = (selected ?? '').trim();
    if (picked.isEmpty || picked == current) return;

    setState(() {
      _selectedMediaSourceId = picked;
    });

    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    final sid = (_seriesId ?? '').trim();
    if (serverId == null || serverId.trim().isEmpty || sid.isEmpty) return;
    final idx =
        sources.indexWhere((ms) => (ms['Id']?.toString() ?? '').trim() == picked);
    if (idx < 0) return;
    unawaited(
      widget.appState.setSeriesMediaSourceIndex(
        serverId: serverId.trim(),
        seriesId: sid,
        mediaSourceIndex: idx,
      ),
    );
  }

  Future<void> _pickAudioStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final audioStreams = _ShowDetailPageState._streamsOfType(ms, 'Audio');
    if (audioStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _ShowDetailPageState._defaultStream(audioStreams);
        final defIndex = _ShowDetailPageState._asInt(def?['Index']);
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('音轨选择')),
              ListTile(
                leading: Icon(_selectedAudioStreamIndex == null
                    ? Icons.check
                    : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...audioStreams.map((s) {
                final idx = _ShowDetailPageState._asInt(s['Index']);
                final selectedNow = idx != null && idx == _selectedAudioStreamIndex;
                final title =
                    _ShowDetailPageState._streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedAudioStreamIndex = selected);

    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    final sid = (_seriesId ?? '').trim();
    if (serverId == null || serverId.trim().isEmpty || sid.isEmpty) return;
    unawaited(
      widget.appState.setSeriesAudioStreamIndex(
        serverId: serverId.trim(),
        seriesId: sid,
        audioStreamIndex: selected,
      ),
    );
  }

  Future<void> _pickSubtitleStream(
      BuildContext context, Map<String, dynamic> ms) async {
    final subtitleStreams = _ShowDetailPageState._streamsOfType(ms, 'Subtitle');
    if (subtitleStreams.isEmpty) return;

    final selected = await showModalBottomSheet<int?>(
      context: context,
      builder: (ctx) {
        final def = _ShowDetailPageState._defaultStream(subtitleStreams);
        final defIndex = _ShowDetailPageState._asInt(def?['Index']);
        final isOff = _selectedSubtitleStreamIndex == -1;
        final isDefault = _selectedSubtitleStreamIndex == null;
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('字幕选择')),
              ListTile(
                leading: Icon(isOff ? Icons.check : Icons.circle_outlined),
                title: const Text('关闭'),
                onTap: () => Navigator.of(ctx).pop(-1),
              ),
              ListTile(
                leading: Icon(isDefault ? Icons.check : Icons.circle_outlined),
                title: const Text('默认'),
                onTap: () => Navigator.of(ctx).pop(null),
              ),
              ...subtitleStreams.map((s) {
                final idx = _ShowDetailPageState._asInt(s['Index']);
                final selectedNow =
                    idx != null && idx == _selectedSubtitleStreamIndex;
                final title =
                    _ShowDetailPageState._streamLabel(s, includeCodec: false);
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(idx == defIndex ? '$title (默认)' : title),
                  subtitle: (s['Codec'] as String?)?.isNotEmpty == true
                      ? Text(s['Codec'] as String)
                      : null,
                  onTap: idx == null ? null : () => Navigator.of(ctx).pop(idx),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    setState(() => _selectedSubtitleStreamIndex = selected);

    final serverId = widget.server?.id ?? widget.appState.activeServerId;
    final sid = (_seriesId ?? '').trim();
    if (serverId == null || serverId.trim().isEmpty || sid.isEmpty) return;
    unawaited(
      widget.appState.setSeriesSubtitleStreamIndex(
        serverId: serverId.trim(),
        seriesId: sid,
        subtitleStreamIndex: selected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final enableBlur = !widget.isTv && widget.appState.enableBlurEffects;
    return Scaffold(
      appBar: GlassAppBar(
        enableBlur: enableBlur,
        child: AppBar(title: Text(ep.name)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ep.name,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 6),
                      if (_detail?.overview.isNotEmpty == true)
                        Text(_detail!.overview),
                      const SizedBox(height: 12),
                      if (_playInfo != null)
                        _episodePlaybackOptionsCard(context, _playInfo!),
                      const SizedBox(height: 12),
                      _playButton(
                        context,
                        label: (_detail?.playbackPositionTicks ?? 0) > 0
                            ? '继续播放（${_fmtClock(_ticksToDuration(_detail!.playbackPositionTicks))}）'
                            : '播放',
                        onTap: () async {
                          final start = (_detail?.playbackPositionTicks ?? 0) >
                                  0
                              ? _ticksToDuration(_detail!.playbackPositionTicks)
                              : null;
                          final useExoCore = !kIsWeb &&
                              defaultTargetPlatform == TargetPlatform.android &&
                              widget.appState.playerCore == PlayerCore.exo;
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => useExoCore
                                  ? ExoPlayNetworkPage(
                                      title: ep.name,
                                      itemId: ep.id,
                                      appState: widget.appState,
                                      server: widget.server,
                                      isTv: widget.isTv,
                                      seriesId: _seriesId,
                                      startPosition: start,
                                      mediaSourceId: _selectedMediaSourceId,
                                      audioStreamIndex: _selectedAudioStreamIndex,
                                      subtitleStreamIndex:
                                          _selectedSubtitleStreamIndex,
                                    )
                                  : PlayNetworkPage(
                                      title: ep.name,
                                      itemId: ep.id,
                                      appState: widget.appState,
                                      server: widget.server,
                                      isTv: widget.isTv,
                                      seriesId: _seriesId,
                                      startPosition: start,
                                      mediaSourceId: _selectedMediaSourceId,
                                      audioStreamIndex: _selectedAudioStreamIndex,
                                      subtitleStreamIndex:
                                          _selectedSubtitleStreamIndex,
                                    ),
                            ),
                          );
                          if (!mounted) return;
                          await _refreshProgressAfterReturn();
                        },
                      ),
                      const SizedBox(height: 16),
                      if ((_seriesId ?? '').trim().isNotEmpty) ...[
                        _otherEpisodesSection(context),
                        const SizedBox(height: 16),
                      ],
                      if (_detail?.people.isNotEmpty == true)
                        _peopleSection(
                          context,
                          _detail!.people,
                          baseUrl: _baseUrl!,
                          token: _token!,
                          apiPrefix: widget.server?.apiPrefix ??
                              widget.appState.apiPrefix,
                        ),
                      if (_playInfo != null) ...[
                        const SizedBox(height: 16),
                        _mediaInfo(
                          context,
                          _playInfo!,
                          selectedMediaSourceId: _selectedMediaSourceId,
                        ),
                      ],
                      if (_chapters.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text('章节',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _chapters
                              .map((c) => Chip(
                                    label: Text('${c.name} ${_fmt(c.start)}'),
                                  ))
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Future<void> _loadSeriesEpisodes({
    required EmbyApi api,
    required String token,
    required String baseUrl,
    required String userId,
    required MediaItem episodeDetail,
    required String seriesId,
    required String seriesName,
  }) async {
    try {
      final seasons = await api.fetchSeasons(
        token: token,
        baseUrl: baseUrl,
        userId: userId,
        seriesId: seriesId,
      );
      final seasonItems =
          seasons.items.where((s) => s.type.toLowerCase() == 'season').toList();
      seasonItems.sort((a, b) {
        final aNo = a.seasonNumber ?? a.episodeNumber ?? 0;
        final bNo = b.seasonNumber ?? b.episodeNumber ?? 0;
        return aNo.compareTo(bNo);
      });

      final seasonsVirtual = seasonItems.isEmpty;
      final seasonsForUi = seasonsVirtual
          ? [
              MediaItem(
                id: seriesId,
                name: '全部剧集',
                type: 'Season',
                overview: '',
                communityRating: null,
                premiereDate: null,
                genres: const [],
                runTimeTicks: null,
                sizeBytes: null,
                container: null,
                providerIds: const {},
                seriesId: seriesId,
                seriesName: seriesName,
                seasonName: '全部剧集',
                seasonNumber: null,
                episodeNumber: null,
                hasImage: episodeDetail.hasImage,
                playbackPositionTicks: 0,
                people: const [],
                parentId: seriesId,
              ),
            ]
          : seasonItems;

      final currentSeasonId =
          (episodeDetail.parentId ?? widget.episode.parentId ?? '').trim();
      final previousSeasonId = _selectedSeasonId;
      final selectedSeasonId = currentSeasonId.isNotEmpty &&
              seasonsForUi.any((s) => s.id == currentSeasonId)
          ? currentSeasonId
          : (previousSeasonId != null &&
                  seasonsForUi.any((s) => s.id == previousSeasonId))
              ? previousSeasonId
              : (seasonsForUi.isNotEmpty ? seasonsForUi.first.id : null);

      final episodesCacheForUi = <String, List<MediaItem>>{};
      if (selectedSeasonId != null && selectedSeasonId.isNotEmpty) {
        final eps = await api.fetchEpisodes(
          token: token,
          baseUrl: baseUrl,
          userId: userId,
          seasonId: selectedSeasonId,
        );
        final items = List<MediaItem>.from(eps.items);
        items.sort((a, b) {
          final aNo = a.episodeNumber ?? 0;
          final bNo = b.episodeNumber ?? 0;
          return aNo.compareTo(bNo);
        });
        episodesCacheForUi[selectedSeasonId] = items;
      }

      if (!mounted) return;
      setState(() {
        _seasons = seasonsForUi;
        _seasonsVirtual = seasonsVirtual;
        _selectedSeasonId = selectedSeasonId;
        _episodesCache
          ..clear()
          ..addAll(episodesCacheForUi);
        _seriesError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _seriesError = e.toString();
        _seasons = const [];
        _seasonsVirtual = false;
        _selectedSeasonId = null;
        _episodesCache.clear();
      });
    } finally {
      if (mounted) {
        setState(() {
          _seriesLoading = false;
        });
      }
    }
  }

  String _seasonLabel(MediaItem season, int index) {
    final name = season.name.trim();
    final seasonNo = season.seasonNumber ?? season.episodeNumber;
    return seasonNo != null
        ? '第$seasonNo季'
        : (name.isNotEmpty ? name : '第${index + 1}季');
  }

  MediaItem? get _selectedSeason {
    if (_seasons.isEmpty) return null;
    final selectedId = _selectedSeasonId;
    if (selectedId == null || selectedId.isEmpty) return _seasons.first;
    for (final s in _seasons) {
      if (s.id == selectedId) return s;
    }
    return _seasons.first;
  }

  String _selectedSeasonLabel() {
    if (_seasons.isEmpty) return '选择季';
    final selectedId = _selectedSeasonId;
    for (int i = 0; i < _seasons.length; i++) {
      final s = _seasons[i];
      if (selectedId != null && s.id == selectedId) return _seasonLabel(s, i);
    }
    return _seasonLabel(_seasons.first, 0);
  }

  Future<List<MediaItem>> _episodesForSeason(MediaItem season) async {
    final cached = _episodesCache[season.id];
    if (cached != null) return cached;
    final baseUrl = _baseUrl;
    final token = _token;
    final userId = _userId;
    if (baseUrl == null || token == null || userId == null) return const [];

    final api = EmbyApi(
      hostOrUrl: baseUrl,
      preferredScheme: 'https',
      apiPrefix: widget.server?.apiPrefix ?? widget.appState.apiPrefix,
      serverType: widget.server?.serverType ?? widget.appState.serverType,
      deviceId: widget.appState.deviceId,
    );
    final eps = await api.fetchEpisodes(
      token: token,
      baseUrl: baseUrl,
      userId: userId,
      seasonId: season.id,
    );
    final items = List<MediaItem>.from(eps.items);
    items.sort((a, b) {
      final aNo = a.episodeNumber ?? 0;
      final bNo = b.episodeNumber ?? 0;
      return aNo.compareTo(bNo);
    });
    _episodesCache[season.id] = items;
    return items;
  }

  Future<void> _pickSeason(BuildContext context) async {
    if (_seasons.isEmpty) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            children: [
              const ListTile(title: Text('季选择')),
              ..._seasons.asMap().entries.map((entry) {
                final idx = entry.key;
                final s = entry.value;
                final selectedNow = s.id == _selectedSeasonId;
                return ListTile(
                  leading: Icon(
                      selectedNow ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(_seasonLabel(s, idx)),
                  onTap: () => Navigator.of(ctx).pop(s.id),
                );
              }),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (selected == null || selected.isEmpty || selected == _selectedSeasonId) {
      return;
    }

    setState(() {
      _selectedSeasonId = selected;
    });

    final season = _selectedSeason;
    if (season == null) return;
    try {
      await _episodesForSeason(season);
    } catch (_) {
      // Episode list is optional for the UI.
    }
  }

  String _episodeLabel(MediaItem episode, int index) {
    final epNo = episode.episodeNumber ?? (index + 1);
    final epName = episode.name.trim();
    return epName.isNotEmpty ? '$epNo. $epName' : '第$epNo集';
  }

  Future<void> _pickEpisode(BuildContext context) async {
    final season = _selectedSeason;
    if (season == null) return;

    final seasonLabel = _selectedSeasonLabel();
    final selectedEp = await showModalBottomSheet<MediaItem>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: widget.isTv ? 0.9 : 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (ctx, controller) {
              return FutureBuilder<List<MediaItem>>(
                future: _episodesForSeason(season),
                builder: (ctx, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        SizedBox(height: 24),
                        Center(child: CircularProgressIndicator()),
                      ],
                    );
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      controller: controller,
                      children: [
                        const ListTile(title: Text('选集')),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('加载失败：${snapshot.error}'),
                        ),
                      ],
                    );
                  }
                  final eps = snapshot.data ?? const [];
                  if (eps.isEmpty) {
                    return ListView(
                      controller: controller,
                      children: const [
                        ListTile(title: Text('选集')),
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无剧集'),
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    controller: controller,
                    itemCount: eps.length + 1,
                    itemBuilder: (ctx, idx) {
                      if (idx == 0) {
                        return ListTile(title: Text('选集（$seasonLabel）'));
                      }
                      final epIndex = idx - 1;
                      final ep = eps[epIndex];
                      final isCurrent = ep.id == widget.episode.id;
                      return ListTile(
                        leading: Icon(
                          isCurrent
                              ? Icons.check_circle
                              : Icons.play_circle_outline,
                        ),
                        title: Text(_episodeLabel(ep, epIndex)),
                        onTap: () => Navigator.of(ctx).pop(ep),
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );

    if (!mounted || !context.mounted || selectedEp == null || selectedEp.id.isEmpty) return;
    if (selectedEp.id == widget.episode.id) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => EpisodeDetailPage(
          episode: selectedEp,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
        ),
      ),
    );
  }

  void _openSeasonEpisodesPage(BuildContext context, MediaItem season) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeasonEpisodesPage(
          season: season,
          appState: widget.appState,
          server: widget.server,
          isTv: widget.isTv,
          isVirtual: _seasonsVirtual,
        ),
      ),
    );
  }

  Widget _otherEpisodesSection(BuildContext context) {
    final theme = Theme.of(context);
    final season = _selectedSeason;
    final title = (_seriesName).trim().isNotEmpty ? '剧集 · $_seriesName' : '剧集';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_seriesError != null) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '加载剧集失败：$_seriesError',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _seasons.isEmpty ? null : () => _pickSeason(context),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.video_library_outlined, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '季：${_selectedSeasonLabel()}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: season == null ? null : () => _pickEpisode(context),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.format_list_numbered, size: 18),
                    SizedBox(width: 8),
                    Text('选集'),
                    SizedBox(width: 4),
                    Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (season == null && _seriesLoading) ...[
          const SizedBox(height: 8),
          const Center(child: CircularProgressIndicator()),
        ],
        if (season != null) ...[
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _openSeasonEpisodesPage(context, season),
              child: const Text('查看全部'),
            ),
          ),
          SizedBox(
            height: widget.isTv ? 230 : 200,
            child: FutureBuilder<List<MediaItem>>(
              future: _episodesForSeason(season),
              builder: (ctx, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('加载剧集失败：${snapshot.error}'));
                }
                final eps = snapshot.data ?? const [];
                if (eps.isEmpty) {
                  return const Center(child: Text('暂无剧集'));
                }
                return ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: eps.length,
                  padding: const EdgeInsets.only(bottom: 8),
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final e = eps[index];
                    final isCurrent = e.id == widget.episode.id;
                    final epNo = e.episodeNumber ?? (index + 1);
                    final img = EmbyApi.imageUrl(
                      baseUrl: _baseUrl!,
                      itemId: e.hasImage ? e.id : season.id,
                      token: _token!,
                      apiPrefix:
                          widget.server?.apiPrefix ?? widget.appState.apiPrefix,
                      maxWidth: widget.isTv ? 900 : 640,
                    );
                    return SizedBox(
                      width: widget.isTv ? 360 : 260,
                      child: MediaBackdropTile(
                        title: _episodeLabel(e, index),
                        subtitle: isCurrent ? '当前' : '第$epNo集',
                        badgeText: isCurrent ? '当前' : null,
                        imageUrl: img,
                        onTap: () {
                          if (isCurrent) return;
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) => EpisodeDetailPage(
                                episode: e,
                                appState: widget.appState,
                                server: widget.server,
                                isTv: widget.isTv,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m ${s}s';
  return '${m}m ${s}s';
}

Duration _ticksToDuration(int ticks) =>
    Duration(microseconds: (ticks / 10).round());

String _fmtClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

Widget _chaptersSection(BuildContext context, List<ChapterInfo> chapters) {
  final width = MediaQuery.of(context).size.width;
  final crossAxisCount = width >= 900 ? 4 : (width >= 600 ? 3 : 2);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('章节', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 16 / 9,
        ),
        itemCount: chapters.length,
        itemBuilder: (context, index) {
          final c = chapters[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.menu_book, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name.isNotEmpty ? c.name : 'Chapter ${index + 1}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fmt(c.start),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ],
  );
}

Widget _pill(BuildContext context, String text) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final style = theme.extension<AppStyle>() ?? const AppStyle();
  final isDark = scheme.brightness == Brightness.dark;

  final pillRadius = switch (style.template) {
    UiTemplate.neonHud => 12.0,
    UiTemplate.pixelArcade => 10.0,
    UiTemplate.mangaStoryboard => 10.0,
    _ => 20.0,
  };

  final (Color bg, Color fg, BorderSide border) = switch (style.template) {
    UiTemplate.neonHud => (
        Colors.black.withValues(alpha: isDark ? 0.28 : 0.24),
        Colors.white,
        BorderSide(
          color: scheme.primary.withValues(alpha: isDark ? 0.75 : 0.85),
          width: 1.1,
        ),
      ),
    UiTemplate.pixelArcade => (
        Colors.black.withValues(alpha: isDark ? 0.30 : 0.24),
        Colors.white,
        BorderSide(
          color: scheme.secondary.withValues(alpha: isDark ? 0.75 : 0.85),
          width: 1.2,
        ),
      ),
    UiTemplate.mangaStoryboard => (
        Colors.white.withValues(alpha: isDark ? 0.24 : 0.88),
        isDark ? Colors.white : Colors.black,
        BorderSide(
          color: (isDark ? Colors.white : Colors.black)
              .withValues(alpha: isDark ? 0.55 : 0.85),
          width: 1.2,
        ),
      ),
    UiTemplate.stickerJournal => (
        Color.lerp(Colors.black, scheme.secondary, 0.18)!.withValues(
          alpha: isDark ? 0.30 : 0.24,
        ),
        Colors.white,
        BorderSide(
          color: scheme.secondary.withValues(alpha: isDark ? 0.50 : 0.70),
          width: 1.0,
        ),
      ),
    UiTemplate.candyGlass => (
        Color.lerp(Colors.black, scheme.primary, 0.12)!.withValues(
          alpha: isDark ? 0.28 : 0.22,
        ),
        Colors.white,
        BorderSide.none,
      ),
    UiTemplate.washiWatercolor => (
        Color.lerp(Colors.black, scheme.tertiary, 0.10)!.withValues(
          alpha: isDark ? 0.26 : 0.20,
        ),
        Colors.white,
        BorderSide.none,
      ),
    UiTemplate.proTool => (
        Colors.black.withValues(alpha: isDark ? 0.28 : 0.22),
        Colors.white,
        BorderSide(
          color: Colors.white.withValues(alpha: isDark ? 0.22 : 0.18),
          width: 1.0,
        ),
      ),
    UiTemplate.minimalCovers => (
        Colors.black.withValues(alpha: isDark ? 0.26 : 0.20),
        Colors.white,
        BorderSide.none,
      ),
  };

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(pillRadius),
      border: border == BorderSide.none ? null : Border.fromBorderSide(border),
    ),
    child: Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
            color: fg,
            fontWeight: FontWeight.w700,
            letterSpacing: style.template == UiTemplate.neonHud ? 0.2 : null,
          ) ??
          TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
          ),
    ),
  );
}

Widget _playButton(BuildContext context,
    {required String label, required VoidCallback onTap}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final style = theme.extension<AppStyle>() ?? const AppStyle();
  final isDark = scheme.brightness == Brightness.dark;

  final radius = switch (style.template) {
    UiTemplate.neonHud => 14.0,
    UiTemplate.pixelArcade => 12.0,
    UiTemplate.mangaStoryboard => 12.0,
    UiTemplate.proTool => 16.0,
    UiTemplate.stickerJournal => 20.0,
    _ => 30.0,
  };

  final (Color bg, Color fg, BorderSide border, Color glow) =
      switch (style.template) {
    UiTemplate.neonHud => (
        scheme.surface.withValues(alpha: isDark ? 0.55 : 0.90),
        scheme.primary,
        BorderSide(
          color: scheme.primary.withValues(alpha: isDark ? 0.85 : 0.95),
          width: 1.4,
        ),
        scheme.primary.withValues(alpha: isDark ? 0.22 : 0.14),
      ),
    UiTemplate.pixelArcade => (
        scheme.surface.withValues(alpha: isDark ? 0.70 : 0.92),
        scheme.secondary,
        BorderSide(
          color: scheme.secondary.withValues(alpha: isDark ? 0.85 : 0.95),
          width: 1.8,
        ),
        Colors.transparent,
      ),
    UiTemplate.mangaStoryboard => (
        scheme.surface,
        scheme.onSurface,
        BorderSide(
          color: scheme.onSurface.withValues(alpha: isDark ? 0.70 : 0.90),
          width: 1.8,
        ),
        Colors.transparent,
      ),
    UiTemplate.stickerJournal => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        BorderSide(
          color: scheme.secondary.withValues(alpha: isDark ? 0.55 : 0.75),
          width: 1.2,
        ),
        Colors.transparent,
      ),
    UiTemplate.candyGlass => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        BorderSide.none,
        Colors.transparent,
      ),
    UiTemplate.washiWatercolor => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        BorderSide.none,
        Colors.transparent,
      ),
    UiTemplate.proTool => (
        scheme.surfaceContainerHigh,
        scheme.onSurface,
        BorderSide(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.55 : 0.70),
          width: 1.1,
        ),
        Colors.transparent,
      ),
    UiTemplate.minimalCovers => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        BorderSide.none,
        Colors.transparent,
      ),
  };

  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: Ink(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(radius),
          border:
              border == BorderSide.none ? null : Border.fromBorderSide(border),
          boxShadow: glow == Colors.transparent
              ? null
              : [
                  BoxShadow(
                    color: glow,
                    blurRadius: 22,
                    spreadRadius: 1,
                  ),
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_arrow, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    letterSpacing:
                        style.template == UiTemplate.neonHud ? 0.25 : null,
                  ) ??
                  TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _peopleSection(
  BuildContext context,
  List<MediaPerson> people, {
  required String baseUrl,
  required String token,
  required String apiPrefix,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('演职人员', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      SizedBox(
        height: 150,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: people.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final p = people[index];
            final img = EmbyApi.personImageUrl(
              baseUrl: baseUrl,
              personId: p.id,
              token: token,
              apiPrefix: apiPrefix,
              maxWidth: 200,
            );
            return Column(
              children: [
                CircleAvatar(
                  radius: 42,
                  backgroundImage: img.isNotEmpty ? NetworkImage(img) : null,
                  backgroundColor: Colors.white24,
                  child: img.isEmpty
                      ? Text(p.name.isNotEmpty ? p.name[0] : '?')
                      : null,
                ),
                const SizedBox(height: 6),
                Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(p.role, style: Theme.of(context).textTheme.bodySmall),
              ],
            );
          },
        ),
      ),
    ],
  );
}

Widget _mediaInfo(
  BuildContext context,
  PlaybackInfoResult info, {
  String? selectedMediaSourceId,
}) {
  final map =
      _ShowDetailPageState._findMediaSource(info, selectedMediaSourceId) ??
          (info.mediaSources.first as Map<String, dynamic>);
  final streams = (map['MediaStreams'] as List?) ?? const [];
  final video = streams
      .where((e) => (e as Map)['Type'] == 'Video')
      .map((e) => e as Map)
      .toList();
  final audio = streams
      .where((e) => (e as Map)['Type'] == 'Audio')
      .map((e) => e as Map)
      .toList();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('媒体信息', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _infoCard(
              '视频',
              video
                  .map((v) {
                    final title = (v['DisplayTitle'] ?? '').toString().trim();
                    final codec = (v['Codec'] ?? '').toString().trim();
                    final aspect =
                        _formatVideoAspectRatio(v.cast<String, dynamic>());
                    final parts = <String>[
                      if (title.isNotEmpty) title,
                      if (codec.isNotEmpty) codec,
                      if (aspect != null) '视频比例：$aspect',
                    ];
                    return parts.join('\n');
                  })
                  .join('\n\n')),
          _infoCard(
              '音频',
              audio
                  .map((a) => '${a['DisplayTitle'] ?? ''}\n${a['Codec'] ?? ''}')
                  .join('\n')),
        ],
      ),
    ],
  );
}

String? _formatVideoAspectRatio(Map<String, dynamic> stream) {
  final raw = stream['AspectRatio'];
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains(':')) return trimmed;
    final n = double.tryParse(trimmed);
    if (n != null && n.isFinite && n > 0) return _formatAspectRatioValue(n);
    return trimmed;
  }

  final width = _ShowDetailPageState._asInt(stream['Width']);
  final height = _ShowDetailPageState._asInt(stream['Height']);
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return _formatAspectRatioValue(width / height, width: width, height: height);
}

String _formatAspectRatioValue(
  double ratio, {
  int? width,
  int? height,
}) {
  const known = <String, double>{
    '1:1': 1.0,
    '4:3': 4 / 3,
    '3:2': 3 / 2,
    '16:9': 16 / 9,
    '21:9': 21 / 9,
    '2:1': 2.0,
    '1.85:1': 1.85,
    '2.39:1': 2.39,
  };
  const tol = 0.03;
  for (final e in known.entries) {
    if ((ratio - e.value).abs() <= tol) return e.key;
  }

  if (width != null &&
      height != null &&
      width > 0 &&
      height > 0 &&
      width < 100000 &&
      height < 100000) {
    final g = _gcd(width, height);
    if (g > 0) {
      final a = (width / g).round();
      final b = (height / g).round();
      if (a > 0 && b > 0 && a <= 100 && b <= 100) return '$a:$b';
    }
  }

  return ratio.toStringAsFixed(2);
}

int _gcd(int a, int b) {
  var x = a.abs();
  var y = b.abs();
  while (y != 0) {
    final t = x % y;
    x = y;
    y = t;
  }
  return x;
}

Widget _infoCard(String title, String body) => SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(body, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );

Widget _externalLinksSection(
    BuildContext context, MediaItem item, AppState appState) {
  final tmdbId = item.providerIds.entries
      .firstWhere((e) => e.key.toLowerCase().contains('tmdb'),
          orElse: () => const MapEntry('', ''))
      .value;
  if (tmdbId.isEmpty) return const SizedBox.shrink();
  final isSeries = item.type.toLowerCase() == 'series';
  final url = isSeries
      ? 'https://www.themoviedb.org/tv/$tmdbId'
      : 'https://www.themoviedb.org/movie/$tmdbId';
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('外部链接', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          ActionChip(
            avatar: const Icon(Icons.link),
            label: const Text('TMDB'),
            onPressed: () async {
              final opened = await launchUrlString(url);
              if (!opened && context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('无法打开链接')));
              }
            },
          ),
        ],
      )
    ],
  );
}
