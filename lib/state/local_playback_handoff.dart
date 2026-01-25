class LocalPlaybackItem {
  final String name;
  final String path;
  final int size;

  const LocalPlaybackItem({
    required this.name,
    required this.path,
    this.size = 0,
  });
}

class LocalPlaybackHandoff {
  final List<LocalPlaybackItem> playlist;
  final int index;
  final Duration position;
  final bool wasPlaying;

  const LocalPlaybackHandoff({
    required this.playlist,
    required this.index,
    required this.position,
    required this.wasPlaying,
  });
}
