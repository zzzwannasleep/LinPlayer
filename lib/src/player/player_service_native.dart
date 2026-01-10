import 'dart:io';
import 'package:video_player/video_player.dart';
import 'player_service.dart' as def;

/// Native implementation of the [PlayerService].
///
/// This service uses `VideoPlayerController.file` to play videos from the
/// local file system.
class PlayerService implements def.PlayerService {
  VideoPlayerController? _controller;

  @override
  VideoPlayerController? get controller => _controller;
  
  @override
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  
  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  Duration get position => _controller?.value.position ?? Duration.zero;


  @override
  Future<void> initialize(String? path, {String? networkUrl}) async {
    await _controller?.dispose();
    
    if (path != null) {
      _controller = VideoPlayerController.file(File(path));
    } else if (networkUrl != null) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(networkUrl));
    } else {
      // No source provided
      return;
    }
    
    await _controller!.initialize();
    play();
  }

  @override
  void play() {
    _controller?.play();
  }

  @override
  void pause() {
    _controller?.pause();
  }

  @override
  void seek(Duration position) {
    _controller?.seekTo(position);
  }

  @override
  void dispose() {
    _controller?.dispose();
  }
}

PlayerService getPlayerService() => PlayerService();
