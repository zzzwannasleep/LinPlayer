import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';

/// Abstract definition for a player service.
///
/// This class defines the common interface for video playback, allowing for
/// different implementations on native and web platforms. The concrete
/// implementation will be chosen at compile-time using conditional imports.
abstract class PlayerService {
  VideoPlayerController? get controller;

  /// Initializes the player.
  ///
  /// [path]: local file path (native).
  /// [file]: picked file with in‑memory bytes (web).
  /// [networkUrl]: remote media URL.
  Future<void> initialize(String? path, {PlatformFile? file, String? networkUrl});

  void play();

  void pause();
  
  void seek(Duration position);

  void dispose();
  
  bool get isInitialized;
  
  bool get isPlaying;
  
  Duration get position;
}
