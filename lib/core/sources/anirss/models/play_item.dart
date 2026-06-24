import 'dart:convert';

/// 一集的一个可播文件（`/api/playList` 的 `PlayItem`）。同一集可能有多个（不同字幕组/清晰度）→ 版本选择。
class PlayItemModel {
  /// 显示标题。
  final String? title;

  /// 「路径+文件名」的 **base64**（取流 `/api/file?filename=` 直接用，勿再编码）。
  final String filename;

  /// 文件名（含后缀）。
  final String? name;

  /// 集数（double，可能是 x.5）。
  final double? episode;
  final String? formatSize;
  final String? extName;
  final List<SubtitleModel> subtitles;

  const PlayItemModel({
    required this.filename,
    this.title,
    this.name,
    this.episode,
    this.formatSize,
    this.extName,
    this.subtitles = const [],
  });

  static PlayItemModel fromJson(Map<String, dynamic> m) => PlayItemModel(
        filename: m['filename']?.toString() ?? '',
        title: m['title']?.toString(),
        name: m['name']?.toString(),
        episode: (m['episode'] as num?)?.toDouble(),
        formatSize: m['formatSize']?.toString(),
        extName: m['extName']?.toString(),
        subtitles: (m['subtitles'] as List?)
                ?.whereType<Map>()
                .map((e) => SubtitleModel.fromJson(e.cast<String, dynamic>()))
                .toList() ??
            const [],
      );

  /// 还原文件名（用于解析字幕组等），失败回 base64 原文。
  String get decodedName {
    if (name != null && name!.isNotEmpty) return name!;
    try {
      return utf8.decode(base64.decode(filename)).split('/').last;
    } catch (_) {
      return filename;
    }
  }

  /// 该集集号（缺失排末尾用 infinity）。
  double get episodeKey => episode ?? double.infinity;
}

/// 外挂/内封字幕（随 PlayItem 返回，无需再调 getSubtitles）。
class SubtitleModel {
  final String? url;
  final String? name;
  final String? content;
  final String? type;
  const SubtitleModel({this.url, this.name, this.content, this.type});

  static SubtitleModel fromJson(Map<String, dynamic> m) => SubtitleModel(
        url: m['url']?.toString(),
        name: m['name']?.toString(),
        content: m['content']?.toString(),
        type: m['type']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        if (url != null) 'url': url,
        if (name != null) 'name': name,
        if (content != null) 'content': content,
        if (type != null) 'type': type,
      };
}
