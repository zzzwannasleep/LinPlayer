/// Ani-rss 内 `Ani.tmdb` 的类型化子集（仅取详情页要用的字段）。
/// 完整 Tmdb 有 24 字段，这里只暴露 UI 需要的；海报/背景/头像为 TMDB 相对路径，
/// 经 `AniRssApi.proxyImageUrl` 走 ani-rss 服务端代理取（免用户配 TMDB Key）。
class TmdbModel {
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final String? voteAverage;
  final String? tagline;
  final int? runtime;
  final String? originalName;
  final String? date;

  /// "MOVIE" | "TV"。
  final String? tmdbType;

  final List<TmdbGenre> genres;
  final List<TmdbCast> cast;
  final List<TmdbNetwork> networks;
  final List<TmdbVideo> videos;

  const TmdbModel({
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.voteAverage,
    this.tagline,
    this.runtime,
    this.originalName,
    this.date,
    this.tmdbType,
    this.genres = const [],
    this.cast = const [],
    this.networks = const [],
    this.videos = const [],
  });

  bool get isMovie => (tmdbType ?? '').toUpperCase() == 'MOVIE';

  static TmdbModel? fromJson(Object? json) {
    if (json is! Map) return null;
    final m = json.cast<String, dynamic>();
    final credits = m['credits'];
    final castList = credits is Map ? (credits['cast'] as List?) : null;
    return TmdbModel(
      overview: m['overview']?.toString(),
      posterPath: m['posterPath']?.toString(),
      backdropPath: m['backdropPath']?.toString(),
      voteAverage: m['voteAverage']?.toString(),
      tagline: m['tagline']?.toString(),
      runtime: (m['runtime'] as num?)?.toInt(),
      originalName: m['originalName']?.toString(),
      date: m['date']?.toString(),
      tmdbType: m['tmdbType']?.toString(),
      genres: _list(m['genres'], TmdbGenre.fromJson),
      cast: _list(castList, TmdbCast.fromJson),
      networks: _list(m['networks'], TmdbNetwork.fromJson),
      videos: _list(m['videos'], TmdbVideo.fromJson),
    );
  }

  static List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) f) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => f(e.cast<String, dynamic>()))
        .toList();
  }
}

class TmdbGenre {
  final String name;
  const TmdbGenre(this.name);
  static TmdbGenre fromJson(Map<String, dynamic> m) =>
      TmdbGenre(m['name']?.toString() ?? '');
}

class TmdbCast {
  final String name;
  final String? originalName;
  final String? character;
  final String? profilePath;
  const TmdbCast({
    required this.name,
    this.originalName,
    this.character,
    this.profilePath,
  });
  static TmdbCast fromJson(Map<String, dynamic> m) => TmdbCast(
        name: m['name']?.toString() ?? '',
        originalName: m['originalName']?.toString(),
        character: m['character']?.toString(),
        profilePath: m['profilePath']?.toString(),
      );
}

class TmdbNetwork {
  final String name;
  final String? logoPath;
  const TmdbNetwork({required this.name, this.logoPath});
  static TmdbNetwork fromJson(Map<String, dynamic> m) => TmdbNetwork(
        name: m['name']?.toString() ?? '',
        logoPath: m['logoPath']?.toString(),
      );
}

class TmdbVideo {
  final String? name;
  final String? key;
  final String? site;
  final String? type;
  const TmdbVideo({this.name, this.key, this.site, this.type});
  static TmdbVideo fromJson(Map<String, dynamic> m) => TmdbVideo(
        name: m['name']?.toString(),
        key: m['key']?.toString(),
        site: m['site']?.toString(),
        type: m['type']?.toString(),
      );
}
