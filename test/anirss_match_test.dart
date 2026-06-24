import 'package:flutter_test/flutter_test.dart';
import 'package:linplayer_mobile/core/sources/anirss/anirss_match.dart';
import 'package:linplayer_mobile/core/sources/anirss/models/ani.dart';
import 'package:linplayer_mobile/core/sources/anirss/models/torrent_info.dart';

void main() {
  group('parseEpisode', () {
    test('字幕组 "- 12 " 约定', () {
      expect(parseEpisode('[Sub] Title - 12 [1080p].mkv'), 12);
    });
    test('[12] 方括号', () {
      expect(parseEpisode('[Group][Title][12][BIG5].mp4'), 12);
    });
    test('E12 / EP12', () {
      expect(parseEpisode('Title.S01E12.1080p.mkv'), 12);
      expect(parseEpisode('Title EP05 WEB-DL'), 5);
    });
    test('第12话', () {
      expect(parseEpisode('某番剧 第12话'), 12);
    });
    test('x.5 小数集', () {
      expect(parseEpisode('Title - 11.5 [720p].mkv'), 11.5);
    });
    test('无集号返回 null', () {
      expect(parseEpisode('Movie Title 1080p BDRip'), isNull);
    });
  });

  group('matchTorrents', () {
    AniModel ani(String id, String title,
            {List<String>? tags, String? dir, String? tmdbName}) =>
        AniModel({
          'id': id,
          'title': title,
          if (tags != null) 'customTags': tags,
          if (dir != null) 'downloadPath': dir,
          if (tmdbName != null) 'themoviedbName': tmdbName,
        });

    TorrentInfoModel tor(String name,
            {List<String>? tags,
            String? dir,
            double progress = 0.5,
            String state = 'downloading'}) =>
        TorrentInfoModel(
          id: name,
          name: name,
          state: torrentStateFromName(state),
          progress: progress,
          tags: tags ?? const [],
          downloadDir: dir,
        );

    test('标签匹配优先并解析集号', () {
      final anis = [ani('a1', '迷宫饭', tags: ['迷宫饭'])];
      final torrents = [tor('[Sub] 迷宫饭 - 03 [1080p]', tags: ['迷宫饭'])];
      final r = matchTorrents(anis, torrents);
      expect(r.byAni['a1'], hasLength(1));
      expect(r.byAni['a1']!.first.episodeNumber, 3);
      expect(r.unmatched, isEmpty);
    });

    test('目录匹配兜底', () {
      final anis = [ani('a2', 'Foo', dir: '/media/Foo')];
      final torrents = [tor('random release - 01', dir: '/media/Foo/Season 1')];
      final r = matchTorrents(anis, torrents);
      expect(r.byAni['a2'], hasLength(1));
    });

    test('标题模糊兜底', () {
      final anis = [ani('a3', 'SomeAnime')];
      final torrents = [tor('[X] SomeAnime - 07 [WEB]')];
      final r = matchTorrents(anis, torrents);
      expect(r.byAni['a3'], hasLength(1));
      expect(r.byAni['a3']!.first.episodeNumber, 7);
    });

    test('完全不匹配进 unmatched', () {
      final anis = [ani('a4', '甲乙丙')];
      final torrents = [tor('totally unrelated file')];
      final r = matchTorrents(anis, torrents);
      expect(r.byAni, isEmpty);
      expect(r.unmatched, hasLength(1));
    });

    test('每订阅内按集号排序', () {
      final anis = [ani('a5', 'Bar', tags: ['Bar'])];
      final torrents = [
        tor('Bar - 03', tags: ['Bar']),
        tor('Bar - 01', tags: ['Bar']),
        tor('Bar - 02', tags: ['Bar']),
      ];
      final r = matchTorrents(anis, torrents);
      final eps = r.byAni['a5']!.map((e) => e.episodeNumber).toList();
      expect(eps, [1, 2, 3]);
    });
  });

  group('AniModel JSON 往返', () {
    test('toJson 无损保留全部字段', () {
      final raw = {
        'id': 'x',
        'title': '标题',
        'image': 'https://example.com/a.jpg',
        'score': 8.4,
        'currentEpisodeNumber': 5,
        'totalEpisodeNumber': 12,
        'ova': false,
        'extraUnknownField': {'nested': 1},
      };
      final ani = AniModel.fromJson(raw);
      expect(ani.toJson(), equals(raw));
      expect(ani.image, 'https://example.com/a.jpg');
      expect(ani.score, 8.4);
      // copyWithRaw 不丢未知字段
      final edited = ani.copyWithRaw({'enable': false});
      expect(edited.toJson()['extraUnknownField'], equals({'nested': 1}));
      expect(edited.enable, isFalse);
    });
  });
}
