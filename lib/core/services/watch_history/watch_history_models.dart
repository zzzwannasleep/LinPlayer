import '../../api/api_interfaces.dart';

enum WatchHistoryMediaKind { movie, episode }

enum WatchHistoryWriteSource { internalPlayer, externalMpv }

enum WatchHistoryMatchConfidence { none, weak, possible, strong }

extension WatchHistoryMediaKindWire on WatchHistoryMediaKind {
  String get wireValue {
    switch (this) {
      case WatchHistoryMediaKind.movie:
        return 'movie';
      case WatchHistoryMediaKind.episode:
        return 'episode';
    }
  }

  static WatchHistoryMediaKind? fromWire(dynamic value) {
    switch (value?.toString()) {
      case 'movie':
        return WatchHistoryMediaKind.movie;
      case 'episode':
        return WatchHistoryMediaKind.episode;
      default:
        return null;
    }
  }
}

extension WatchHistoryWriteSourceWire on WatchHistoryWriteSource {
  String get wireValue {
    switch (this) {
      case WatchHistoryWriteSource.internalPlayer:
        return 'internal_player';
      case WatchHistoryWriteSource.externalMpv:
        return 'external_mpv';
    }
  }

  static WatchHistoryWriteSource fromWire(dynamic value) {
    switch (value?.toString()) {
      case 'external_mpv':
        return WatchHistoryWriteSource.externalMpv;
      case 'internal_player':
      default:
        return WatchHistoryWriteSource.internalPlayer;
    }
  }
}

extension WatchHistoryMatchConfidenceWire on WatchHistoryMatchConfidence {
  String get wireValue {
    switch (this) {
      case WatchHistoryMatchConfidence.none:
        return 'none';
      case WatchHistoryMatchConfidence.weak:
        return 'weak';
      case WatchHistoryMatchConfidence.possible:
        return 'possible';
      case WatchHistoryMatchConfidence.strong:
        return 'strong';
    }
  }

  static WatchHistoryMatchConfidence fromWire(dynamic value) {
    switch (value?.toString()) {
      case 'weak':
        return WatchHistoryMatchConfidence.weak;
      case 'possible':
        return WatchHistoryMatchConfidence.possible;
      case 'strong':
        return WatchHistoryMatchConfidence.strong;
      case 'none':
      default:
        return WatchHistoryMatchConfidence.none;
    }
  }
}

class WatchHistoryDocument {
  const WatchHistoryDocument({
    required this.schemaVersion,
    required this.updatedAt,
    required this.records,
  });

  final int schemaVersion;
  final DateTime updatedAt;
  final List<WatchHistoryRecord> records;

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'records': records.map((record) => record.toJson()).toList(),
    };
  }

  factory WatchHistoryDocument.fromJson(Map<String, dynamic> json) {
    final rawRecords = json['records'] as List<dynamic>? ?? const [];
    return WatchHistoryDocument(
      schemaVersion: json['schemaVersion'] as int? ?? 1,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      records: rawRecords
          .whereType<Map<String, dynamic>>()
          .map(WatchHistoryRecord.fromJson)
          .toList(growable: false),
    );
  }

  factory WatchHistoryDocument.empty() {
    return WatchHistoryDocument(
      schemaVersion: 1,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      records: const [],
    );
  }
}

class WatchHistoryRecord {
  const WatchHistoryRecord({
    required this.recordId,
    required this.scopeKey,
    required this.mediaKind,
    required this.canonicalKey,
    required this.title,
    required this.lastPositionTicks,
    required this.played,
    required this.playCount,
    required this.lastPlayedAt,
    required this.lastWriteSource,
    this.firstPlayedAt,
    this.tmdbId,
    this.seriesTmdbId,
    this.seriesTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.year,
    this.runTimeTicks,
    this.lastEmbyItemId,
    this.matchConfidence = WatchHistoryMatchConfidence.none,
    this.restoredAt,
    this.presentationUniqueKey,
    this.mediaPath,
  });

  static const Object _sentinel = Object();

  final String recordId;
  final String scopeKey;
  final WatchHistoryMediaKind mediaKind;
  final String canonicalKey;
  final String? tmdbId;
  final String? seriesTmdbId;
  final String title;
  final String? seriesTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? year;
  final int lastPositionTicks;
  final int? runTimeTicks;
  final bool played;
  final int playCount;
  final DateTime lastPlayedAt;
  /// 该 scope（服务器）首次记录此内容的时间。旧记录可能为 null，
  /// 此时回退到 [lastPlayedAt]（见 [effectiveFirstPlayedAt]）。
  final DateTime? firstPlayedAt;
  final String? lastEmbyItemId;
  final WatchHistoryMatchConfidence matchConfidence;
  final DateTime? restoredAt;
  final WatchHistoryWriteSource lastWriteSource;
  final String? presentationUniqueKey;
  final String? mediaPath;

  /// 首次观看时间，旧记录缺失时回退到 [lastPlayedAt]。
  DateTime get effectiveFirstPlayedAt => firstPlayedAt ?? lastPlayedAt;

  Map<String, dynamic> toJson() {
    return {
      'recordId': recordId,
      'scopeKey': scopeKey,
      'mediaKind': mediaKind.wireValue,
      'canonicalKey': canonicalKey,
      'tmdbId': tmdbId,
      'seriesTmdbId': seriesTmdbId,
      'title': title,
      'seriesTitle': seriesTitle,
      'seasonNumber': seasonNumber,
      'episodeNumber': episodeNumber,
      'year': year,
      'lastPositionTicks': lastPositionTicks,
      'runTimeTicks': runTimeTicks,
      'played': played,
      'playCount': playCount,
      'lastPlayedAt': lastPlayedAt.toUtc().toIso8601String(),
      'firstPlayedAt': firstPlayedAt?.toUtc().toIso8601String(),
      'lastEmbyItemId': lastEmbyItemId,
      'matchConfidence': matchConfidence.wireValue,
      'restoredAt': restoredAt?.toUtc().toIso8601String(),
      'lastWriteSource': lastWriteSource.wireValue,
      'presentationUniqueKey': presentationUniqueKey,
      'mediaPath': mediaPath,
    };
  }

  factory WatchHistoryRecord.fromJson(Map<String, dynamic> json) {
    return WatchHistoryRecord(
      recordId: json['recordId']?.toString() ?? '',
      scopeKey: json['scopeKey']?.toString() ?? '',
      mediaKind: WatchHistoryMediaKindWire.fromWire(json['mediaKind']) ??
          WatchHistoryMediaKind.movie,
      canonicalKey: json['canonicalKey']?.toString() ?? '',
      tmdbId: _readNullableString(json['tmdbId']),
      seriesTmdbId: _readNullableString(json['seriesTmdbId']),
      title: json['title']?.toString() ?? '',
      seriesTitle: _readNullableString(json['seriesTitle']),
      seasonNumber: _readNullableInt(json['seasonNumber']),
      episodeNumber: _readNullableInt(json['episodeNumber']),
      year: _readNullableInt(json['year']),
      lastPositionTicks: _readNullableInt(json['lastPositionTicks']) ?? 0,
      runTimeTicks: _readNullableInt(json['runTimeTicks']),
      played: json['played'] as bool? ?? false,
      playCount: _readNullableInt(json['playCount']) ?? 0,
      lastPlayedAt: DateTime.tryParse(json['lastPlayedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      firstPlayedAt: DateTime.tryParse(json['firstPlayedAt']?.toString() ?? ''),
      lastEmbyItemId: _readNullableString(json['lastEmbyItemId']),
      matchConfidence:
          WatchHistoryMatchConfidenceWire.fromWire(json['matchConfidence']),
      restoredAt: DateTime.tryParse(json['restoredAt']?.toString() ?? ''),
      lastWriteSource:
          WatchHistoryWriteSourceWire.fromWire(json['lastWriteSource']),
      presentationUniqueKey: _readNullableString(json['presentationUniqueKey']),
      mediaPath: _readNullableString(json['mediaPath']),
    );
  }

  WatchHistoryRecord copyWith({
    String? recordId,
    String? scopeKey,
    WatchHistoryMediaKind? mediaKind,
    String? canonicalKey,
    Object? tmdbId = _sentinel,
    Object? seriesTmdbId = _sentinel,
    String? title,
    Object? seriesTitle = _sentinel,
    Object? seasonNumber = _sentinel,
    Object? episodeNumber = _sentinel,
    Object? year = _sentinel,
    int? lastPositionTicks,
    Object? runTimeTicks = _sentinel,
    bool? played,
    int? playCount,
    DateTime? lastPlayedAt,
    Object? firstPlayedAt = _sentinel,
    Object? lastEmbyItemId = _sentinel,
    WatchHistoryMatchConfidence? matchConfidence,
    Object? restoredAt = _sentinel,
    WatchHistoryWriteSource? lastWriteSource,
    Object? presentationUniqueKey = _sentinel,
    Object? mediaPath = _sentinel,
  }) {
    return WatchHistoryRecord(
      recordId: recordId ?? this.recordId,
      scopeKey: scopeKey ?? this.scopeKey,
      mediaKind: mediaKind ?? this.mediaKind,
      canonicalKey: canonicalKey ?? this.canonicalKey,
      tmdbId: identical(tmdbId, _sentinel) ? this.tmdbId : tmdbId as String?,
      seriesTmdbId: identical(seriesTmdbId, _sentinel)
          ? this.seriesTmdbId
          : seriesTmdbId as String?,
      title: title ?? this.title,
      seriesTitle: identical(seriesTitle, _sentinel)
          ? this.seriesTitle
          : seriesTitle as String?,
      seasonNumber: identical(seasonNumber, _sentinel)
          ? this.seasonNumber
          : seasonNumber as int?,
      episodeNumber: identical(episodeNumber, _sentinel)
          ? this.episodeNumber
          : episodeNumber as int?,
      year: identical(year, _sentinel) ? this.year : year as int?,
      lastPositionTicks: lastPositionTicks ?? this.lastPositionTicks,
      runTimeTicks: identical(runTimeTicks, _sentinel)
          ? this.runTimeTicks
          : runTimeTicks as int?,
      played: played ?? this.played,
      playCount: playCount ?? this.playCount,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      firstPlayedAt: identical(firstPlayedAt, _sentinel)
          ? this.firstPlayedAt
          : firstPlayedAt as DateTime?,
      lastEmbyItemId: identical(lastEmbyItemId, _sentinel)
          ? this.lastEmbyItemId
          : lastEmbyItemId as String?,
      matchConfidence: matchConfidence ?? this.matchConfidence,
      restoredAt: identical(restoredAt, _sentinel)
          ? this.restoredAt
          : restoredAt as DateTime?,
      lastWriteSource: lastWriteSource ?? this.lastWriteSource,
      presentationUniqueKey: identical(presentationUniqueKey, _sentinel)
          ? this.presentationUniqueKey
          : presentationUniqueKey as String?,
      mediaPath: identical(mediaPath, _sentinel)
          ? this.mediaPath
          : mediaPath as String?,
    );
  }
}

class WatchHistoryRestoreCandidate {
  const WatchHistoryRestoreCandidate({
    required this.record,
    required this.matchedItem,
    required this.confidence,
    required this.reason,
  });

  final WatchHistoryRecord record;
  final MediaItem matchedItem;
  final WatchHistoryMatchConfidence confidence;
  final String reason;
}

class WatchHistoryRestoreScanResult {
  const WatchHistoryRestoreScanResult({
    required this.promptCandidates,
    required this.autoRestoredCount,
  });

  final List<WatchHistoryRestoreCandidate> promptCandidates;
  final int autoRestoredCount;
}

String? _readNullableString(dynamic value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text;
}

int? _readNullableInt(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  return int.tryParse(value.toString());
}
