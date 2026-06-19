import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'watch_history_models.dart';

typedef WatchHistoryDirectoryResolver = Future<Directory> Function();

class WatchHistoryStore {
  WatchHistoryStore({
    WatchHistoryDirectoryResolver? directoryResolver,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final WatchHistoryDirectoryResolver _directoryResolver;

  Future<void> _pendingWrite = Future<void>.value();

  Future<WatchHistoryDocument> loadDocument() async {
    final file = await _resolveFile();
    if (!await file.exists()) {
      return WatchHistoryDocument.empty();
    }

    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return WatchHistoryDocument.empty();
      }
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return WatchHistoryDocument.empty();
      }
      return WatchHistoryDocument.fromJson(decoded);
    } catch (_) {
      return WatchHistoryDocument.empty();
    }
  }

  Future<List<WatchHistoryRecord>> loadScope(String scopeKey) async {
    final document = await loadDocument();
    final records = document.records
        .where((record) => record.scopeKey == scopeKey)
        .toList(growable: false);
    records
        .sort((left, right) => right.lastPlayedAt.compareTo(left.lastPlayedAt));
    return records;
  }

  /// 加载全部观看记录（跨服务器，不按 scopeKey 过滤）。
  /// 用于跨服务器续播匹配与设置页统计/清理。
  Future<List<WatchHistoryRecord>> loadAll() async {
    final document = await loadDocument();
    final records = document.records.toList();
    records
        .sort((left, right) => right.lastPlayedAt.compareTo(left.lastPlayedAt));
    return records;
  }

  /// 清空全部本地观看记录。
  Future<void> clearAll() {
    return _enqueueWrite(() async {
      await _writeDocument(
        WatchHistoryDocument(
          schemaVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          records: const [],
        ),
      );
    });
  }

  Future<void> saveRecord(
    WatchHistoryRecord record, {
    Iterable<String> replaceRecordIds = const [],
  }) {
    return _enqueueWrite(() async {
      final document = await loadDocument();
      final records = document.records
          .where((entry) =>
              entry.recordId != record.recordId &&
              !replaceRecordIds.contains(entry.recordId))
          .toList();
      records.add(record);
      await _writeDocument(
        WatchHistoryDocument(
          schemaVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          records: _sortRecords(records),
        ),
      );
    });
  }

  Future<void> saveRecords(Iterable<WatchHistoryRecord> records) {
    return _enqueueWrite(() async {
      final document = await loadDocument();
      final incoming = {for (final record in records) record.recordId: record};
      final merged = document.records
          .where((entry) => !incoming.containsKey(entry.recordId))
          .toList();
      merged.addAll(incoming.values);
      await _writeDocument(
        WatchHistoryDocument(
          schemaVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          records: _sortRecords(merged),
        ),
      );
    });
  }

  Future<void> deleteRecord(String recordId) {
    return _enqueueWrite(() async {
      final document = await loadDocument();
      final records = document.records
          .where((entry) => entry.recordId != recordId)
          .toList(growable: false);
      await _writeDocument(
        WatchHistoryDocument(
          schemaVersion: 1,
          updatedAt: DateTime.now().toUtc(),
          records: records,
        ),
      );
    });
  }

  Future<File> _resolveFile() async {
    final directory = await _directoryResolver();
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'watch_history.json'));
  }

  Future<void> _writeDocument(WatchHistoryDocument document) async {
    final file = await _resolveFile();
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(document.toJson())}\n');
  }

  Future<void> _enqueueWrite(Future<void> Function() action) {
    _pendingWrite = _pendingWrite.catchError((_) {}).then((_) => action());
    return _pendingWrite;
  }

  List<WatchHistoryRecord> _sortRecords(List<WatchHistoryRecord> records) {
    records
        .sort((left, right) => right.lastPlayedAt.compareTo(left.lastPlayedAt));
    return records;
  }
}
