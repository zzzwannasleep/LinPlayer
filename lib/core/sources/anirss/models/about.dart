/// `/api/about` 返回（版本/更新信息）。
class AboutModel {
  final String? version;
  final String? latest;
  final bool update;
  final bool autoUpdate;
  final String? downloadUrl;
  final String? markdownBody;
  final String? formatSize;
  final String? date;

  const AboutModel({
    this.version,
    this.latest,
    this.update = false,
    this.autoUpdate = false,
    this.downloadUrl,
    this.markdownBody,
    this.formatSize,
    this.date,
  });

  static AboutModel fromJson(Object? json) {
    if (json is! Map) return const AboutModel();
    final m = json.cast<String, dynamic>();
    return AboutModel(
      version: m['version']?.toString(),
      latest: m['latest']?.toString(),
      update: m['update'] == true,
      autoUpdate: m['autoUpdate'] == true,
      downloadUrl: m['downloadUrl']?.toString(),
      markdownBody: m['markdownBody']?.toString(),
      formatSize: m['formatSize']?.toString(),
      date: m['date']?.toString(),
    );
  }
}
