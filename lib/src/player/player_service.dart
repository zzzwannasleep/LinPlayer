import 'package:video_player/video_player.dart';

/// Abstract definition for a player service.
///
/// This class defines the common interface for video playback, allowing for
/// different implementations on native and web platforms. The concrete
/// implementation will be chosen at compile-time using conditional imports.
abstract class PlayerService {
  VideoPlayerController? get controller;

  /// Initializes the player with a file path.
  ///
  /// On native, this will be a direct file path.
  /// On web, this will involve reading the file bytes and creating a blob URL.
  Future<void> initialize(String? path, {String? networkUrl});

  void play();

  void pause();
  
  void seek(Duration position);

  void dispose();
  
  bool get isInitialized;
  
  bool get isPlaying;
  
  Duration get position;
}
