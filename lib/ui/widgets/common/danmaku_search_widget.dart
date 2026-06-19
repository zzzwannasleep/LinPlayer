import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/api/danmaku/danmaku_service.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/danmaku_filter.dart';
import '../../../core/utils/danmaku_matcher.dart';

/// 弹幕搜索/匹配面板：并行向所有启用源查询、**分源展示**，用户自己挑。
/// 移动端在播放器右侧面板使用，桌面端在弹层中复用。
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
  List<DanmakuSourceGroup> _groups = [];

  // 当前展开的作品（携带来源）。
  DanmakuAnime? _selectedAnime;
  String? _selectedSourceId;
  String? _selectedSourceName;
  List<DanmakuEpisode> _selectedEpisodes = [];

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
    _searchController.dispose();
    _bgmtvIdController.dispose();
    super.dispose();
  }

  // ============ 智能自动匹配（并行所有源）============

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

    // 回退到关键词分源搜索。
    if (!mounted) return;
    _searchController.text = title;
    await _search(keyword: title, fromAuto: true);
  }

  // ============ 关键词分源搜索 ============

  Future<void> _search({String? keyword, bool fromAuto = false}) async {
    final kw = (keyword ?? _searchController.text).trim();
    if (kw.isEmpty) return;
    setState(() {
      _isSearching = true;
      if (!fromAuto) _isAutoMatching = false;
      _selectedAnime = null;
      _selectedEpisodes = [];
    });
    try {
      final service = ref.read(danmakuServiceProvider);
      final groups = await service.searchAllGrouped(kw);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _isSearching = false;
        _isAutoMatching = false;
        if (fromAuto) {
          final any = groups.any((g) => g.animes.isNotEmpty);
          _autoMatchStatus = any ? null : '未找到弹幕，请手动搜索或填 Bangumi ID';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _isAutoMatching = false;
        });
      }
    }
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
        _selectedAnime = anime;
        _selectedSourceId = anime.sourceId ?? 'dandanplay';
        _selectedSourceName = anime.sourceName ?? '弹弹Play';
        _selectedEpisodes = anime.episodes ?? [];
        _groups = [];
        _autoCandidates = [];
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isBgmtvSearching = false);
        _toast('Bangumi 搜索失败: $e');
      }
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
        if (_isAutoMatching) _buildAutoMatchingRow(),
        if (_autoCandidates.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('推荐匹配（按可信度）', style: _white54),
          const SizedBox(height: 4),
          ..._autoCandidates.take(8).map(_buildCandidateTile),
          const Divider(color: Colors.white12),
        ],
        _buildSearchBox(),
        const SizedBox(height: 6),
        _buildBgmtvBox(),
        if (_autoMatchStatus != null && !_isAutoMatching)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(_autoMatchStatus!, style: _white54),
          ),
        if (_isSearching)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
        ..._buildGroupedResults(),
        if (_selectedEpisodes.isNotEmpty) _buildEpisodePicker(),
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
      leading: _sourceChip(c.sourceName),
      title: Text(c.animeTitle,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: Text(c.episodeTitle, style: _white54),
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
      decoration: InputDecoration(
        hintText: '搜索动漫/剧集名称',
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
          onPressed:
              _isBgmtvSearching ? null : () => _searchByBgmtvId(_bgmtvIdController.text),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ],
    );
  }

  List<Widget> _buildGroupedResults() {
    if (_groups.isEmpty) return const [];
    final widgets = <Widget>[];
    for (final g in _groups) {
      if (g.animes.isEmpty && g.error == null) continue;
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Row(
          children: [
            _sourceChip(g.sourceName),
            const SizedBox(width: 8),
            Text(
              g.error != null
                  ? '请求失败'
                  : '${g.animes.length} 个结果',
              style: _white54,
            ),
          ],
        ),
      ));
      for (final anime in g.animes) {
        final selected = _selectedAnime?.animeId == anime.animeId &&
            _selectedSourceId == g.sourceId;
        widgets.add(ListTile(
          dense: true,
          title: Text(anime.animeTitle,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
          subtitle: Text(
            '${anime.typeDescription ?? ''} ${anime.year?.toString() ?? ''}'
                .trim(),
            style: _white54,
          ),
          trailing: Icon(
            selected ? Icons.expand_less : Icons.chevron_right,
            color: Colors.white38,
          ),
          selected: selected,
          selectedTileColor: Colors.white10,
          onTap: () {
            setState(() {
              _selectedAnime = anime;
              _selectedSourceId = g.sourceId;
              _selectedSourceName = g.sourceName;
              _selectedEpisodes = anime.episodes ?? [];
            });
          },
        ));
      }
    }
    return widgets;
  }

  Widget _buildEpisodePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(color: Colors.white12),
        Row(
          children: [
            const Text('选择集数', style: _white54),
            const SizedBox(width: 8),
            if (_selectedSourceName != null) _sourceChip(_selectedSourceName!),
          ],
        ),
        const SizedBox(height: 4),
        ..._selectedEpisodes.map((ep) {
          final loading = _loadingEpisodeId == ep.episodeId;
          return ListTile(
            dense: true,
            title: Text(ep.episodeTitle,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            trailing: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download, color: _accent, size: 20),
            onTap: loading
                ? null
                : () => _loadComments(
                      episodeId: ep.episodeId,
                      sourceId: ep.sourceId ?? _selectedSourceId,
                      animeTitle: _selectedAnime?.animeTitle ?? '',
                    ),
          );
        }),
      ],
    );
  }

  Widget _sourceChip(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(name,
          style: const TextStyle(color: _accent, fontSize: 11)),
    );
  }
}
