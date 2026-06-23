import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/api/danmaku/danmaku_service.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/danmaku_filter.dart';
import '../../../core/utils/danmaku_local_parser.dart';
import '../../../core/utils/danmaku_matcher.dart';

/// 弹幕搜索/选择面板（移动端右侧面板、桌面端弹层复用）。
///
/// 交互：顶部搜索框 → 回车/点搜索 → 各源**流式分源**返回（谁快谁先显示）。
/// 结果按「剧 / 电影」区分：电影点一下直接加载；剧点进去选集。同一部剧若有
/// 多个源（danmu_api / 御坂这类聚合器对一部剧会返回多个上游源），点某集后在该
/// 集下面展开**源下拉**让用户挑；弹弹Play 这种单源则点了直接加载。
/// 另提供「本地导入」直接加载用户的 .xml/.json/.ass 弹幕文件。
class DanmakuSearchContent extends ConsumerStatefulWidget {
  final MediaItem? item;
  const DanmakuSearchContent({super.key, this.item});

  @override
  ConsumerState<DanmakuSearchContent> createState() =>
      _DanmakuSearchContentState();
}

class _DanmakuSearchContentState extends ConsumerState<DanmakuSearchContent> {
  final _searchController = TextEditingController();
  final _bgmtvIdController = TextEditingController();

  bool _isAutoMatching = false;
  String? _autoMatchStatus;
  List<DanmakuMatchCandidate> _autoCandidates = [];

  bool _isSearching = false;
  bool _isBgmtvSearching = false;
  bool _isImporting = false;
  StreamSubscription<DanmakuSourceGroup>? _searchSub;

  // 搜索结果按「剧/电影」归组（同标题的多个源合并成一个 show）。
  final List<_DanmakuShow> _shows = [];
  String? _expandedShowKey; // 当前展开的剧
  String? _expandedEpKey; // 当前展开了「源下拉」的集

  String? _loadingEpisodeId; // 正在取评论的集

  static const _white70 = TextStyle(color: Colors.white70, fontSize: 14);
  static const _white54 = TextStyle(color: Colors.white54, fontSize: 13);
  static const _accent = Color(0xFF5B8DEF);

  @override
  void initState() {
    super.initState();
    _runAutoMatch();
  }

  @override
  void dispose() {
    _searchSub?.cancel();
    _searchController.dispose();
    _bgmtvIdController.dispose();
    super.dispose();
  }

  // ============ 智能自动匹配（并行所有源，作为推荐）============

  Future<void> _runAutoMatch() async {
    final item = widget.item;
    if (item == null) return;
    final service = ref.read(danmakuServiceProvider);
    final title = DanmakuMatcher.resolveTitle(item);
    if (title.isEmpty) return;

    setState(() {
      _isAutoMatching = true;
      _autoMatchStatus = '正在匹配弹幕…';
      _autoCandidates = [];
    });

    try {
      final candidates = await DanmakuMatcher.matchAll(service, item);
      if (!mounted) return;
      if (candidates.isNotEmpty) {
        setState(() {
          _isAutoMatching = false;
          _autoCandidates = candidates;
          _autoMatchStatus = '匹配到 ${candidates.length} 个候选，点选加载';
          _searchController.text = title;
        });
        return;
      }
    } catch (_) {}

    // 回退到关键词流式搜索。
    if (!mounted) return;
    _searchController.text = title;
    _search(keyword: title, fromAuto: true);
  }

  // ============ 关键词流式分源搜索 ============

  void _search({String? keyword, bool fromAuto = false}) {
    final kw = (keyword ?? _searchController.text).trim();
    if (kw.isEmpty) return;
    _searchSub?.cancel();
    setState(() {
      _isSearching = true;
      _isAutoMatching = false;
      _shows.clear();
      _expandedShowKey = null;
      _expandedEpKey = null;
      if (!fromAuto) {
        _autoCandidates = [];
        _autoMatchStatus = null;
      }
    });
    final service = ref.read(danmakuServiceProvider);
    _searchSub = service.searchAllStreamed(kw).listen(
      (group) {
        if (!mounted) return;
        if (group.animes.isEmpty) return;
        setState(() => _mergeAnimes(group.animes));
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _isSearching = false;
          if (_shows.isEmpty) {
            _autoMatchStatus = '未找到弹幕，请换关键词或填 Bangumi ID';
          }
        });
      },
      onError: (_) {
        if (mounted) setState(() => _isSearching = false);
      },
    );
  }

  /// 把一批 anime 合并进 [_shows]：按归一化标题聚成「剧」，同剧的不同源累加。
  void _mergeAnimes(List<DanmakuAnime> animes) {
    for (final a in animes) {
      final key = _normalizeTitle(a.animeTitle);
      if (key.isEmpty) continue;
      final existing = _findShow(key);
      if (existing != null) {
        final dup = existing.sources.any(
            (x) => x.animeId == a.animeId && x.sourceId == a.sourceId);
        if (!dup) existing.sources.add(a);
      } else {
        _shows.add(_DanmakuShow(
          key: key,
          title: _baseTitle(a.animeTitle),
          sources: [a],
        ));
      }
    }
  }

  _DanmakuShow? _findShow(String key) {
    for (final s in _shows) {
      if (s.key == key) return s;
    }
    return null;
  }

  Future<void> _searchByBgmtvId(String idStr) async {
    final bgmtvId = int.tryParse(idStr.trim());
    if (bgmtvId == null) {
      _toast('请输入有效的 Bangumi 数字 ID');
      return;
    }
    setState(() => _isBgmtvSearching = true);
    try {
      final service = ref.read(danmakuServiceProvider);
      final dandanplay = service.dandanplay;
      if (dandanplay == null || !dandanplay.hasCredentials) {
        if (mounted) {
          setState(() => _isBgmtvSearching = false);
          _toast('Bangumi 联动仅支持已配置凭据的弹弹Play 源');
        }
        return;
      }
      final anime = await dandanplay.getBangumiByBgmtvId(bgmtvSubjectId: bgmtvId);
      if (!mounted) return;
      setState(() {
        _isBgmtvSearching = false;
        _shows.clear();
        _mergeAnimes([anime]);
        _expandedShowKey = _normalizeTitle(anime.animeTitle);
        _autoCandidates = [];
        _autoMatchStatus = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isBgmtvSearching = false);
        _toast('Bangumi 搜索失败: $e');
      }
    }
  }

  // ============ 本地导入 ============

  Future<void> _importLocal() async {
    if (_isImporting) return;
    setState(() => _isImporting = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: DanmakuLocalParser.supportedExtensions,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        if (mounted) setState(() => _isImporting = false);
        return;
      }
      final f = result.files.first;
      String content;
      if (f.bytes != null) {
        content = utf8.decode(f.bytes!, allowMalformed: true);
      } else if (f.path != null) {
        content = await File(f.path!).readAsString();
      } else {
        if (mounted) setState(() => _isImporting = false);
        _toast('无法读取文件内容');
        return;
      }
      var items = DanmakuLocalParser.parse(f.name, content);
      items = _applyFilterAndDedup(items);
      if (!mounted) return;
      setState(() => _isImporting = false);
      if (items.isEmpty) {
        _toast('该文件没有可用弹幕');
      } else {
        ref.read(loadedDanmakuProvider.notifier).state = items;
        _toast('已导入 ${items.length} 条本地弹幕 · ${f.name}');
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => _isImporting = false);
      _toast('解析失败: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _isImporting = false);
      _toast('导入失败: $e');
    }
  }

  // ============ 取评论（带缓存 + 过滤 + 去重）============

  Future<void> _loadComments({
    required String episodeId,
    required String? sourceId,
    required String animeTitle,
  }) async {
    setState(() => _loadingEpisodeId = episodeId);
    try {
      final service = ref.read(danmakuServiceProvider);
      var items = await service.getComments(episodeId, sourceId: sourceId);
      items = _applyFilterAndDedup(items);
      if (!mounted) return;
      setState(() => _loadingEpisodeId = null);
      if (items.isEmpty) {
        _toast('该集没有弹幕');
      } else {
        ref.read(loadedDanmakuProvider.notifier).state = items;
        _toast('已加载 ${items.length} 条弹幕 · $animeTitle');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loadingEpisodeId = null);
        _toast('加载弹幕失败: $e');
      }
    }
  }

  List<DanmakuItem> _applyFilterAndDedup(List<DanmakuItem> input) {
    var items = input;
    final blockwords = ref.read(danmakuBlockwordsProvider);
    if (blockwords.isNotEmpty) {
      final filter = DanmakuFilter()..importBlockwords(blockwords);
      items = items
          .where((it) => !filter.shouldFilter(it.text, userId: it.userId))
          .toList();
    }
    if (ref.read(danmakuDedupProvider)) {
      items = _deduplicateDanmaku(items, ref.read(danmakuDedupWindowProvider));
    }
    return items;
  }

  List<DanmakuItem> _deduplicateDanmaku(
      List<DanmakuItem> items, double windowSeconds) {
    items.sort((a, b) => a.time.compareTo(b.time));
    final result = <DanmakuItem>[];
    final used = List<bool>.filled(items.length, false);
    for (var i = 0; i < items.length; i++) {
      if (used[i]) continue;
      var count = 1;
      for (var j = i + 1; j < items.length; j++) {
        if (used[j]) continue;
        if (items[j].time - items[i].time > windowSeconds) break;
        if (items[j].text == items[i].text && items[j].type == items[i].type) {
          count++;
          used[j] = true;
        }
      }
      result.add(DanmakuItem(
        time: items[i].time,
        text: items[i].text,
        type: items[i].type,
        color: items[i].color,
        size: items[i].size,
        source: items[i].source,
        cid: items[i].cid,
        userId: items[i].userId,
        count: count,
      ));
    }
    return result;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBox(),
        const SizedBox(height: 8),
        _buildLocalImportButton(),
        const SizedBox(height: 8),
        _buildBgmtvBox(),
        if (_isAutoMatching) _buildAutoMatchingRow(),
        if (_autoCandidates.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Text('推荐匹配（按可信度）', style: _white54),
          const SizedBox(height: 2),
          ..._autoCandidates.take(8).map(_buildCandidateTile),
          const Divider(color: Colors.white12),
        ],
        if (_autoMatchStatus != null && !_isAutoMatching && _shows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(_autoMatchStatus!, style: _white54),
          ),
        if (_isSearching)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('搜索中，结果陆续显示…', style: _white54),
              ],
            ),
          ),
        ..._shows.map(_buildShowTile),
      ],
    );
  }

  Widget _buildAutoMatchingRow() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text(_autoMatchStatus ?? '匹配中…', style: _white70)),
        ],
      ),
    );
  }

  Widget _buildCandidateTile(DanmakuMatchCandidate c) {
    final loading = _loadingEpisodeId == c.episodeId;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      isThreeLine: true,
      leading: _sourceChip(c.sourceName),
      title: Text(c.animeTitle,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      subtitle: Text(c.episodeTitle,
          style: _white54, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.play_circle_outline, color: _accent),
      onTap: loading
          ? null
          : () => _loadComments(
                episodeId: c.episodeId,
                sourceId: c.sourceId,
                animeTitle: c.animeTitle,
              ),
    );
  }

  Widget _buildSearchBox() {
    return TextField(
      controller: _searchController,
      style: const TextStyle(color: Colors.white),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索剧 / 电影名称',
        hintStyle: const TextStyle(color: Colors.white38),
        prefixIcon: const Icon(Icons.search, color: Colors.white54),
        suffixIcon: _isSearching
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(
                icon: const Icon(Icons.send, color: _accent),
                onPressed: () => _search(),
              ),
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      onSubmitted: (_) => _search(),
    );
  }

  Widget _buildLocalImportButton() {
    return OutlinedButton.icon(
      onPressed: _isImporting ? null : _importLocal,
      icon: _isImporting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.upload_file, color: _accent, size: 20),
      label: const Text('本地导入弹幕（.xml/.json/.ass）',
          style: TextStyle(color: _accent, fontSize: 13)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: _accent),
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
    );
  }

  Widget _buildBgmtvBox() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _bgmtvIdController,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Bangumi 条目ID（弹弹Play 联动，如 975）',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
              filled: true,
              fillColor: Colors.white10,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide.none,
              ),
            ),
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _searchByBgmtvId(_bgmtvIdController.text),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: _isBgmtvSearching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link, color: _accent, size: 20),
          onPressed: _isBgmtvSearching
              ? null
              : () => _searchByBgmtvId(_bgmtvIdController.text),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ],
    );
  }

  // ---- 结果：剧 / 电影 ----

  Widget _buildShowTile(_DanmakuShow show) {
    final isMovie = show.isMovie;
    final expanded = _expandedShowKey == show.key;
    final multiSource = show.sources.length > 1;
    final subtitle = [
      isMovie ? '电影' : '剧集',
      if (multiSource) '${show.sources.length} 个源',
      if (show.sources.first.year != null) '${show.sources.first.year}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          leading: _kindChip(isMovie),
          title: Text(show.title,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          subtitle: Text(subtitle, style: _white54),
          trailing: Icon(
            isMovie && !multiSource
                ? Icons.play_circle_outline
                : (expanded ? Icons.expand_less : Icons.chevron_right),
            color: isMovie && !multiSource ? _accent : Colors.white38,
          ),
          selected: expanded,
          selectedTileColor: Colors.white10,
          onTap: () {
            if (isMovie && !multiSource) {
              _loadMovie(show.sources.first);
            } else {
              setState(() {
                _expandedShowKey = expanded ? null : show.key;
                _expandedEpKey = null;
              });
            }
          },
        ),
        if (expanded && isMovie && multiSource) ..._buildMovieSources(show),
        if (expanded && !isMovie) ..._buildEpisodeList(show),
      ],
    );
  }

  /// 电影多源：每个源点一下直接加载。
  List<Widget> _buildMovieSources(_DanmakuShow show) {
    return [
      for (final a in show.sources)
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.subdirectory_arrow_right,
                color: Colors.white38, size: 18),
            title: Text(_sourceLabel(a),
                style: const TextStyle(color: Colors.white, fontSize: 13)),
            trailing: _loadingEpisodeId == _movieEpisodeId(a)
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download, color: _accent, size: 20),
            onTap: () => _loadMovie(a),
          ),
        ),
    ];
  }

  List<Widget> _buildEpisodeList(_DanmakuShow show) {
    final options = _buildEpisodeOptions(show);
    if (options.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('该剧暂无可选集', style: _white54),
        ),
      ];
    }
    final widgets = <Widget>[];
    for (final opt in options) {
      final multi = opt.sources.length > 1;
      final epExpanded = _expandedEpKey == opt.key;
      final single = opt.sources.first;
      final loading = !multi && _loadingEpisodeId == single.episode.episodeId;
      widgets.add(Padding(
        padding: const EdgeInsets.only(left: 8),
        child: ListTile(
          dense: true,
          title: Text(opt.label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          subtitle: multi ? Text('${opt.sources.length} 个源', style: _white54) : null,
          trailing: loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(
                  multi
                      ? (epExpanded ? Icons.expand_less : Icons.arrow_drop_down)
                      : Icons.download,
                  color: _accent,
                  size: 20),
          onTap: () {
            if (multi) {
              setState(() => _expandedEpKey = epExpanded ? null : opt.key);
            } else {
              _loadComments(
                episodeId: single.episode.episodeId,
                sourceId: single.anime.sourceId,
                animeTitle: single.anime.animeTitle,
              );
            }
          },
        ),
      ));
      // 多源：在该集下面展开源下拉
      if (multi && epExpanded) {
        for (final s in opt.sources) {
          final sLoading = _loadingEpisodeId == s.episode.episodeId;
          widgets.add(Padding(
            padding: const EdgeInsets.only(left: 32),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.subdirectory_arrow_right,
                  color: Colors.white38, size: 18),
              title: Text(_sourceLabel(s.anime),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
              trailing: sLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download, color: _accent, size: 20),
              onTap: () => _loadComments(
                episodeId: s.episode.episodeId,
                sourceId: s.anime.sourceId,
                animeTitle: s.anime.animeTitle,
              ),
            ),
          ));
        }
      }
    }
    return widgets;
  }

  void _loadMovie(DanmakuAnime a) {
    final epId = _movieEpisodeId(a);
    if (epId == null) {
      _toast('该源无可加载的弹幕');
      return;
    }
    _loadComments(
      episodeId: epId,
      sourceId: a.sourceId,
      animeTitle: a.animeTitle,
    );
  }

  String? _movieEpisodeId(DanmakuAnime a) {
    final eps = a.episodes;
    if (eps == null || eps.isEmpty) return null;
    return eps.first.episodeId;
  }

  /// 合并一部剧各源的分集，按集号归并；同一集号下各源即为可选「源」。
  List<_EpOption> _buildEpisodeOptions(_DanmakuShow show) {
    final map = <String, _EpOption>{};
    final order = <String>[];
    for (final a in show.sources) {
      for (final ep in a.episodes ?? const <DanmakuEpisode>[]) {
        final num = ep.episodeNumber?.trim();
        final key = (num != null && num.isNotEmpty)
            ? 'n:$num'
            : 't:${ep.episodeTitle}';
        final opt = map.putIfAbsent(key, () {
          order.add(key);
          return _EpOption(
            key: key,
            number: num,
            label: ep.episodeTitle.isNotEmpty
                ? ep.episodeTitle
                : '第 ${num ?? '?'} 集',
            sources: [],
          );
        });
        opt.sources.add(_EpSource(anime: a, episode: ep));
      }
    }
    final list = order.map((k) => map[k]!).toList();
    list.sort((x, y) {
      final nx = int.tryParse(
          RegExp(r'\d+').firstMatch(x.number ?? '')?.group(0) ?? '');
      final ny = int.tryParse(
          RegExp(r'\d+').firstMatch(y.number ?? '')?.group(0) ?? '');
      if (nx != null && ny != null) return nx.compareTo(ny);
      return 0;
    });
    return list;
  }

  // ---- 小工具 ----

  Widget _kindChip(bool isMovie) {
    final color = isMovie ? const Color(0xFFE5A23B) : _accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(isMovie ? '电影' : '剧',
          style: TextStyle(color: color, fontSize: 12)),
    );
  }

  Widget _sourceChip(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(name, style: const TextStyle(color: _accent, fontSize: 11)),
    );
  }

  /// 源标签：优先取标题括号里的平台名（聚合器常写成「剧名（腾讯视频）」），
  /// 没有则退回后端源名。
  String _sourceLabel(DanmakuAnime a) {
    final m = RegExp(r'[（(\[【]([^）)\]】]+)[）)\]】]').firstMatch(a.animeTitle);
    if (m != null) return m.group(1)!.trim();
    return a.sourceName ?? a.animeTitle;
  }

  /// 归一化标题用于聚组：去掉括号内容（平台名等）与常见分隔符后比较。
  String _normalizeTitle(String t) {
    var s = t.replaceAll(RegExp(r'[（(\[【][^）)\]】]*[）)\]】]'), '');
    s = s.replaceAll(RegExp(r'[\s·:：\-—_、,，.。!！?？]'), '');
    return s.toLowerCase().trim();
  }

  /// 展示标题：把括号内的平台名折叠掉，保留可读主名。
  String _baseTitle(String t) {
    final s = t.replaceAll(RegExp(r'\s*[（(\[【][^）)\]】]*[）)\]】]\s*'), ' ').trim();
    return s.isEmpty ? t : s;
  }
}

bool _animeIsMovie(DanmakuAnime a) {
  final t = a.type?.toLowerCase().trim();
  if (t != null && t.isNotEmpty) return t == 'movie';
  final ec = a.episodeCount ?? a.episodes?.length ?? 0;
  return ec == 1;
}

/// 一部剧（或电影），可包含来自多个源的多个 anime 结果。
class _DanmakuShow {
  final String key;
  final String title;
  final List<DanmakuAnime> sources;

  _DanmakuShow({
    required this.key,
    required this.title,
    required this.sources,
  });

  /// 所有源都判定为电影才算电影（聚合器里偶有混入，从众取剧更安全）。
  bool get isMovie => sources.isNotEmpty && sources.every(_animeIsMovie);
}

/// 归并后的「一集」：可能对应多个源的同一集。
class _EpOption {
  final String key;
  final String? number;
  final String label;
  final List<_EpSource> sources;

  _EpOption({
    required this.key,
    required this.number,
    required this.label,
    required this.sources,
  });
}

class _EpSource {
  final DanmakuAnime anime;
  final DanmakuEpisode episode;
  _EpSource({required this.anime, required this.episode});
}
