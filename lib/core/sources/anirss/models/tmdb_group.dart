/// TMDB 剧集组（`/api/getThemoviedbGroup` 结果项）。注意它是「剧集组」列表
/// （季度合集），非逐集名/剧照；详情页剧集名退回「第N集」即可，此模型留作进阶用。
class TmdbGroupModel {
  final String id;
  final String? name;
  final String? typeName;
  final String? episodeCount;
  final String? groupCount;
  final String? description;

  const TmdbGroupModel({
    required this.id,
    this.name,
    this.typeName,
    this.episodeCount,
    this.groupCount,
    this.description,
  });

  static TmdbGroupModel fromJson(Map<String, dynamic> m) => TmdbGroupModel(
        id: m['id']?.toString() ?? '',
        name: m['name']?.toString(),
        typeName: m['typeName']?.toString(),
        episodeCount: m['episodeCount']?.toString(),
        groupCount: m['groupCount']?.toString(),
        description: m['description']?.toString(),
      );
}
