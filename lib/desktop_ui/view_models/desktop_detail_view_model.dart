import 'package:flutter/foundation.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';
import 'package:lin_player_state/lin_player_state.dart';

import '../../server_adapters/server_access.dart';

class DesktopDetailViewModel extends ChangeNotifier {
  DesktopDetailViewModel({
    required this.appState,
    required MediaItem item,
    this.server,
  })  : _seedItem = item,
        _detail = item;

  final AppState appState;
  final ServerProfile? server;
  final MediaItem _seedItem;

  MediaItem _detail;
  List<MediaItem> _seasons = const <MediaItem>[];
  List<MediaItem> _episodes = const <MediaItem>[];
  List<MediaItem> _similar = const <MediaItem>[];
  List<MediaPerson> _people = const <MediaPerson>[];
  bool _loading = false;
  String? _error;
  bool _favorite = false;
  ServerAccess? _access;

  MediaItem get detail => _detail;
  List<MediaItem> get seasons => _seasons;
  List<MediaItem> get episodes => _episodes;
  List<MediaItem> get similar => _similar;
  List<MediaPerson> get people => _people;
  bool get loading => _loading;
  String? get error => _error;
  bool get favorite => _favorite;
  ServerAccess? get access => _access;

  void toggleFavorite() {
    _favorite = !_favorite;
    notifyListeners();
  }

  String? itemImageUrl(
    MediaItem item, {
    String imageType = 'Primary',
    int maxWidth = 900,
  }) {
    final currentAccess = _access;
    if (currentAccess == null) return null;
    if (!item.hasImage && imageType == 'Primary') return null;
    return currentAccess.adapter.imageUrl(
      currentAccess.auth,
      itemId: item.id,
      imageType: imageType,
      maxWidth: maxWidth,
    );
  }

  String? personImageUrl(MediaPerson person, {int maxWidth = 300}) {
    final currentAccess = _access;
    if (currentAccess == null) return null;
    if (person.id.trim().isEmpty) return null;
    return currentAccess.adapter.personImageUrl(
      currentAccess.auth,
      personId: person.id,
      maxWidth: maxWidth,
    );
  }

  Future<void> load({bool forceRefresh = false}) async {
    if (_loading && !forceRefresh) return;

    _loading = true;
    _error = null;
    notifyListeners();

    final currentAccess = resolveServerAccess(appState: appState, server: server);
    if (currentAccess == null) {
      _loading = false;
      _error = 'No active media server session';
      notifyListeners();
      return;
    }

    _access = currentAccess;

    try {
      var detailItem = _seedItem;
      try {
        detailItem = await currentAccess.adapter.fetchItemDetail(
          currentAccess.auth,
          itemId: _seedItem.id,
        );
      } catch (_) {
        // Keep seed item as fallback when detail API partially fails.
      }

      final similarFuture = currentAccess.adapter
          .fetchSimilar(
            currentAccess.auth,
            itemId: detailItem.id,
            limit: 30,
          )
          .then((result) => result.items)
          .catchError((_) => const <MediaItem>[]);

      List<MediaItem> seasons = const <MediaItem>[];
      List<MediaItem> episodes = const <MediaItem>[];

      final type = detailItem.type.trim().toLowerCase();
      final seriesId = type == 'series'
          ? detailItem.id
          : (detailItem.seriesId ?? '').trim();

      if (seriesId.isNotEmpty) {
        try {
          final seasonResult = await currentAccess.adapter.fetchSeasons(
            currentAccess.auth,
            seriesId: seriesId,
          );
          seasons = seasonResult.items;
        } catch (_) {
          seasons = const <MediaItem>[];
        }

        final firstSeasonId =
            seasons.isNotEmpty ? seasons.first.id : detailItem.parentId;
        if ((firstSeasonId ?? '').trim().isNotEmpty) {
          try {
            final episodeResult = await currentAccess.adapter.fetchEpisodes(
              currentAccess.auth,
              seasonId: firstSeasonId!.trim(),
            );
            episodes = episodeResult.items.take(24).toList(growable: false);
          } catch (_) {
            episodes = const <MediaItem>[];
          }
        }
      } else if (type == 'episode' &&
          (detailItem.parentId ?? '').trim().isNotEmpty) {
        try {
          final episodeResult = await currentAccess.adapter.fetchEpisodes(
            currentAccess.auth,
            seasonId: detailItem.parentId!.trim(),
          );
          episodes = episodeResult.items.take(24).toList(growable: false);
        } catch (_) {
          episodes = const <MediaItem>[];
        }
      }

      final similarItems = await similarFuture;

      _detail = detailItem;
      _seasons = seasons;
      _episodes = episodes;
      _similar = similarItems.where((item) => item.id != detailItem.id).toList();
      _people = detailItem.people;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
