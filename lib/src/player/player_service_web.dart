import 'dart:html' as html;
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'player_service.dart' as def;

/// Web implementation of the [PlayerService].
///
/// This service handles video playback on the web. It uses `file_picker` to get
/// file bytes and creates a blob URL to play them with `VideoPlayerController`.
class PlayerService implements def.PlayerService {
  VideoPlayerController? _controller;
  String? _blobUrl;

  @override
  VideoPlayerController? get controller => _controller;

  @override
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  Duration get position => _controller?.value.position ?? Duration.zero;

  @override
  Future<void> initialize(String? path, {PlatformFile? file, String? networkUrl}) async {
    await _controller?.dispose();
    _revokeBlobUrl(); // Clean up previous blob URL if any

    Uri? videoUri;
    if (file != null && file.bytes != null) {
      final blob = html.Blob([file.bytes]);
      _blobUrl = html.Url.createObjectUrlFromBlob(blob);
      videoUri = Uri.parse(_blobUrl!);
    } else if (networkUrl != null) {
      videoUri = Uri.parse(networkUrl);
    } else {
      // No source provided
      return;
    }
    
    _controller = VideoPlayerController.networkUrl(videoUri);
    await _controller!.initialize();
    play();
  }

  // The initialize method in the abstract class does not have `file` as a parameter.
  // This is a workaround to pass the file bytes on web. A better approach might be
  // to refactor the interface to accept a more generic `MediaSource` object.
  // For now, we will override it with a different signature for web.
  @override
  Future<void> initialize(String? path, {String? networkUrl}) async {
    // This is a stub to satisfy the abstract class, but web will use the
    // method with the `file` parameter. The conditional import will handle this.
    // A better way is to have a unified interface.
    // We will call the network initializer for web.
    await _controller?.dispose();
    _revokeBlobUrl();

    if (networkUrl != null) {
      final videoUri = Uri.parse(networkUrl);
      _controller = VideoPlayerController.networkUrl(videoUri);
      await _controller!.initialize();
      play();
    }
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
    _revokeBlobUrl();
  }
  
  void _revokeBlobUrl() {
    if (_blobUrl != null) {
      html.Url.revokeObjectUrl(_blobUrl!);
      _blobUrl = null;
    }
  }
}

PlayerService getPlayerService() => PlayerService();
