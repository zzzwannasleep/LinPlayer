/// Bangumi 番剧条目（`/api/searchBgm` 结果），用于「添加订阅」搜索。
class BgmInfoModel {
  final String id;
  final String? url;
  final String name;
  final String? nameCn;
  final int? eps;
  final String? date;
  final int? season;
  final String? platform;
  final String? image;
  final double? score;

  const BgmInfoModel({
    required this.id,
    required this.name,
    this.url,
    this.nameCn,
    this.eps,
    this.date,
    this.season,
    this.platform,
    this.image,
    this.score,
  });

  /// 优先中文名。
  String get displayName =>
      (nameCn != null && nameCn!.isNotEmpty) ? nameCn! : name;

  static BgmInfoModel fromJson(Map<String, dynamic> m) {
    final images = m['images'];
    String? img;
    if (images is Map) {
      img = (images['large'] ??
              images['common'] ??
              images['medium'] ??
              images['grid'] ??
              images['small'])
          ?.toString();
    }
    final rating = m['rating'];
    final score =
        rating is Map ? (rating['score'] as num?)?.toDouble() : null;
    return BgmInfoModel(
      id: m['id']?.toString() ?? '',
      url: m['url']?.toString(),
      name: m['name']?.toString() ?? '',
      nameCn: m['nameCn']?.toString(),
      eps: (m['eps'] as num?)?.toInt(),
      date: m['date']?.toString(),
      season: (m['season'] as num?)?.toInt(),
      platform: m['platform']?.toString(),
      image: (img != null && img.startsWith('http')) ? img : null,
      score: score,
    );
  }
}
