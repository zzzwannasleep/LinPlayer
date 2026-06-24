import 'tmdb.dart';

/// 一部番剧订阅（`/api/listAni` 的 `weekList[].items[]`，也是 playList/addAni/setAni 的 body）。
///
/// **内部存原始 `Map`**：`playList/addAni/setAni/previewAni/getThemoviedbGroup` 都拿整个
/// `Ani` 当 body 且字段敏感（Ani 有 55 字段），存原 map 才能无损回传，仅对 UI 读的字段
/// 暴露类型化 getter。`toJson()` 返回原 map（可经 [copyWith] 改字段后回传）。
class AniModel {
  final Map<String, dynamic> raw;
  final TmdbModel? tmdb;

  AniModel(this.raw) : tmdb = TmdbModel.fromJson(raw['tmdb']);

  static AniModel fromJson(Object? json) {
    if (json is Map) return AniModel(json.cast<String, dynamic>());
    return AniModel(<String, dynamic>{});
  }

  Map<String, dynamic> toJson() => raw;

  String get id => raw['id']?.toString() ?? '';
  String get title => raw['title']?.toString() ?? '未命名';
  String? get jpTitle => _nonEmpty(raw['jpTitle']);

  /// 唯一可直接用的 https 封面（cover 是服务端本地路径，不可取）。
  String? get image => _http(raw['image']);

  /// BGM 评分（double）。
  double? get score => (raw['score'] as num?)?.toDouble();
  String? get bgmUrl => _nonEmpty(raw['bgmUrl']);
  String? get subgroup => _nonEmpty(raw['subgroup']);
  String? get type => _nonEmpty(raw['type']);
  String? get themoviedbName => _nonEmpty(raw['themoviedbName']);

  int? get currentEpisodeNumber => (raw['currentEpisodeNumber'] as num?)?.toInt();
  int? get totalEpisodeNumber => (raw['totalEpisodeNumber'] as num?)?.toInt();
  int? get season => (raw['season'] as num?)?.toInt();
  String? get releaseDate => _nonEmpty(raw['releaseDate']);
  String? get downloadPath => _nonEmpty(raw['downloadPath']);

  bool get ova => raw['ova'] == true;
  bool get enable => raw['enable'] != false; // 缺省视为启用

  List<String> get tags {
    final t = raw['customTags'];
    if (t is List) return t.map((e) => e.toString()).toList();
    return const [];
  }

  /// 是否电影/剧场版：tmdbType==MOVIE，或 OVA 且仅一个文件（由调用方传集数判断后覆盖）。
  bool get isMovie => tmdb?.isMovie == true || ova;

  /// 详情页评分（优先 BGM，其次 TMDB voteAverage）。
  double? get rating {
    if (score != null && score! > 0) return score;
    final v = double.tryParse(tmdb?.voteAverage ?? '');
    return (v != null && v > 0) ? v : null;
  }

  /// 复制并覆盖若干字段（回传 setAni/addAni 用）。
  AniModel copyWithRaw(Map<String, dynamic> overrides) {
    final next = Map<String, dynamic>.from(raw)..addAll(overrides);
    return AniModel(next);
  }

  // 按 id 做值相等：可作 Riverpod family 的稳定 key（详情 provider 用）。
  @override
  bool operator ==(Object other) =>
      other is AniModel && other.id.isNotEmpty && other.id == id;

  @override
  int get hashCode => id.hashCode;

  static String? _nonEmpty(Object? v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  static String? _http(Object? v) {
    final s = v?.toString();
    if (s == null || s.isEmpty) return null;
    return s.startsWith('http') ? s : null;
  }
}
