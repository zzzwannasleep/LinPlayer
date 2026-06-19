import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linplayer_mobile/core/api/api_interfaces.dart';
import 'package:linplayer_mobile/core/services/watch_history/watch_history_models.dart';
import 'package:linplayer_mobile/core/services/watch_history/watch_history_service.dart';
import 'package:linplayer_mobile/core/services/watch_history/watch_history_store.dart';

void main() {
  group('WatchHistoryService.resolveResumePositionTicks', () {
    test('prefers newer local progress when server progress is behind',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('watch-history-');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = WatchHistoryStore(
        directoryResolver: () async => tempDir,
      );
      final service = WatchHistoryService(store: store);
      final item = MediaItem(
        id: 'movie-1',
        name: 'Castle in the Sky',
        type: 'Movie',
        providerIds: const {'Tmdb': '10515'},
        runTimeTicks: 72000000000,
      );

      await store.saveRecord(
        WatchHistoryRecord(
          recordId: 'local-record',
          scopeKey: 'server:user',
          mediaKind: WatchHistoryMediaKind.movie,
          canonicalKey: 'movie:tmdb:10515',
          tmdbId: '10515',
          title: item.name,
          lastPositionTicks: 28000000000,
          runTimeTicks: item.runTimeTicks,
          played: false,
          playCount: 1,
          lastPlayedAt: DateTime.utc(2026, 6, 14, 9),
          lastWriteSource: WatchHistoryWriteSource.internalPlayer,
          lastEmbyItemId: item.id,
        ),
      );

      final resolved = await service.resolveResumePositionTicks(
        scopeKey: 'server:user',
        api: _FakeApiClientFactory(),
        item: item,
        remotePositionTicks: 12000000000,
      );

      expect(resolved, 28000000000);
    });

    test('keeps server progress when local record is older', () async {
      final tempDir = await Directory.systemTemp.createTemp('watch-history-');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = WatchHistoryStore(
        directoryResolver: () async => tempDir,
      );
      final service = WatchHistoryService(store: store);
      final item = MediaItem(
        id: 'movie-2',
        name: 'Perfect Blue',
        type: 'Movie',
        providerIds: const {'Tmdb': '10494'},
        runTimeTicks: 48000000000,
      );

      await store.saveRecord(
        WatchHistoryRecord(
          recordId: 'local-record',
          scopeKey: 'server:user',
          mediaKind: WatchHistoryMediaKind.movie,
          canonicalKey: 'movie:tmdb:10494',
          tmdbId: '10494',
          title: item.name,
          lastPositionTicks: 10000000000,
          runTimeTicks: item.runTimeTicks,
          played: false,
          playCount: 1,
          lastPlayedAt: DateTime.utc(2026, 6, 14, 9),
          lastWriteSource: WatchHistoryWriteSource.internalPlayer,
          lastEmbyItemId: item.id,
        ),
      );

      final resolved = await service.resolveResumePositionTicks(
        scopeKey: 'server:user',
        api: _FakeApiClientFactory(),
        item: item,
        remotePositionTicks: 22000000000,
      );

      expect(resolved, 22000000000);
    });

    test('does not resume finished items from local history', () async {
      final tempDir = await Directory.systemTemp.createTemp('watch-history-');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = WatchHistoryStore(
        directoryResolver: () async => tempDir,
      );
      final service = WatchHistoryService(store: store);
      final item = MediaItem(
        id: 'movie-3',
        name: 'Paprika',
        type: 'Movie',
        providerIds: const {'Tmdb': '4977'},
        runTimeTicks: 54000000000,
      );

      await store.saveRecord(
        WatchHistoryRecord(
          recordId: 'local-record',
          scopeKey: 'server:user',
          mediaKind: WatchHistoryMediaKind.movie,
          canonicalKey: 'movie:tmdb:4977',
          tmdbId: '4977',
          title: item.name,
          lastPositionTicks: 50000000000,
          runTimeTicks: item.runTimeTicks,
          played: true,
          playCount: 1,
          lastPlayedAt: DateTime.utc(2026, 6, 14, 9),
          lastWriteSource: WatchHistoryWriteSource.internalPlayer,
          lastEmbyItemId: item.id,
        ),
      );

      final resolved = await service.resolveResumePositionTicks(
        scopeKey: 'server:user',
        api: _FakeApiClientFactory(),
        item: item,
        remotePositionTicks: 0,
      );

      expect(resolved, isNull);
    });

    test('resumes from another server record when crossServer enabled',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('watch-history-');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = WatchHistoryStore(
        directoryResolver: () async => tempDir,
      );
      final service = WatchHistoryService(store: store);
      // 同一部影片，在服务器 B 上打开（item.id 与记录所属服务器 A 不同）。
      final item = MediaItem(
        id: 'server-b-movie',
        name: 'Spirited Away',
        type: 'Movie',
        providerIds: const {'Tmdb': '129'},
        runTimeTicks: 75000000000,
      );

      // 进度记录来自另一台服务器（scopeKey = serverA:user）。
      await store.saveRecord(
        WatchHistoryRecord(
          recordId: 'serverA:user:movie:movie:tmdb:129',
          scopeKey: 'serverA:user',
          mediaKind: WatchHistoryMediaKind.movie,
          canonicalKey: 'movie:tmdb:129',
          tmdbId: '129',
          title: item.name,
          lastPositionTicks: 33000000000,
          runTimeTicks: item.runTimeTicks,
          played: false,
          playCount: 1,
          lastPlayedAt: DateTime.utc(2026, 6, 14, 9),
          lastWriteSource: WatchHistoryWriteSource.internalPlayer,
          lastEmbyItemId: 'server-a-movie',
        ),
      );

      // 关闭跨服务器：本服无记录，回退到远端进度。
      final withoutCross = await service.resolveResumePositionTicks(
        scopeKey: 'serverB:user',
        api: _FakeApiClientFactory(),
        item: item,
        remotePositionTicks: 5000000000,
      );
      expect(withoutCross, 5000000000);

      // 开启跨服务器：续播到服务器 A 的更新进度。
      final withCross = await service.resolveResumePositionTicks(
        scopeKey: 'serverB:user',
        api: _FakeApiClientFactory(),
        item: item,
        remotePositionTicks: 5000000000,
        crossServer: true,
      );
      expect(withCross, 33000000000);
    });

    test('crossServer does not resume a record finished on another server',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('watch-history-');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = WatchHistoryStore(
        directoryResolver: () async => tempDir,
      );
      final service = WatchHistoryService(store: store);
      final item = MediaItem(
        id: 'server-b-movie',
        name: 'Princess Mononoke',
        type: 'Movie',
        providerIds: const {'Tmdb': '128'},
        runTimeTicks: 80000000000,
      );

      await store.saveRecord(
        WatchHistoryRecord(
          recordId: 'serverA:user:movie:movie:tmdb:128',
          scopeKey: 'serverA:user',
          mediaKind: WatchHistoryMediaKind.movie,
          canonicalKey: 'movie:tmdb:128',
          tmdbId: '128',
          title: item.name,
          lastPositionTicks: 79000000000,
          runTimeTicks: item.runTimeTicks,
          played: true,
          playCount: 1,
          lastPlayedAt: DateTime.utc(2026, 6, 14, 9),
          lastWriteSource: WatchHistoryWriteSource.internalPlayer,
          lastEmbyItemId: 'server-a-movie',
        ),
      );

      final resolved = await service.resolveResumePositionTicks(
        scopeKey: 'serverB:user',
        api: _FakeApiClientFactory(),
        item: item,
        remotePositionTicks: 0,
        crossServer: true,
      );
      // 在另一服已看完不应强行续播（回退到本服远端进度 0 → null）。
      expect(resolved, isNull);
    });
  });
}

class _FakeApiClientFactory implements ApiClientFactory {
  @override
  AuthApi get auth => throw UnimplementedError();

  @override
  UserApi get user => throw UnimplementedError();

  @override
  ServerApi get server => throw UnimplementedError();

  @override
  HomeApi get home => throw UnimplementedError();

  @override
  LibraryApi get library => throw UnimplementedError();

  @override
  MediaApi get media => _FakeMediaApi();

  @override
  SearchApi get search => throw UnimplementedError();

  @override
  PlaybackApi get playback => throw UnimplementedError();

  @override
  FavoriteApi get favorite => throw UnimplementedError();

  @override
  SessionApi get session => throw UnimplementedError();

  @override
  ImageApi get image => throw UnimplementedError();

  @override
  void switchLine(String lineUrl) => throw UnimplementedError();

  @override
  String get currentLine => throw UnimplementedError();

  @override
  void setAuthToken(String token) => throw UnimplementedError();

  @override
  void clearAuth() => throw UnimplementedError();
}

class _FakeMediaApi implements MediaApi {
  @override
  Future<MediaItem> getItemDetails(String itemId) {
    throw UnimplementedError();
  }

  @override
  Future<List<MediaItem>> getSimilarItems(String itemId) {
    throw UnimplementedError();
  }

  @override
  Future<List<Season>> getSeasons(String seriesId) {
    throw UnimplementedError();
  }

  @override
  Future<List<Episode>> getEpisodes(String seriesId, {String? seasonId}) {
    throw UnimplementedError();
  }

  @override
  Future<List<Person>> getPersonItems(String personName) {
    throw UnimplementedError();
  }
}
