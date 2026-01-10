import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:lin_player/player_service.dart';
import 'package:video_player/video_player.dart';

// An ugly hack to make the web implementation work with a different signature
// A better way would be a more robust interface like a MediaSource class.
import 'src/player/player_service_web.dart' if (dart.library.io) 'src/player/player_service_native.dart' as service_impl;


void main() {
  runApp(const LinPlayerApp());
}

class LinPlayerApp extends StatelessWidget {
  const LinPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LinPlayer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        colorScheme: const ColorScheme.dark().copyWith(
          primary: Colors.blue,
          secondary: Colors.blueAccent,
        ),
      ),
      home: const PlayerScreen(),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final PlayerService _playerService = getPlayerService();
  final List<PlatformFile> _playlist = [];
  int _currentlyPlayingIndex = -1;

  @override
  void initState() {
    super.initState();
    // Listen to player state changes to rebuild the UI
    // This is a bit of a workaround to get the UI to update.
    // A more robust solution would use a state management library.
    _playerService.controller?.addListener(() {
      if (mounted) setState(() {});
    });
  }
  
  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
      withData: kIsWeb, // On web, we need the file bytes.
    );

    if (result != null) {
      setState(() {
        _playlist.addAll(result.files);
      });
      // If nothing is playing, play the first selected file.
      if (_currentlyPlayingIndex == -1 && _playlist.isNotEmpty) {
        _playFile(_playlist.first, 0);
      }
    }
  }

  Future<void> _playFile(PlatformFile file, int index) async {
    setState(() {
      _currentlyPlayingIndex = index;
    });

    // The web implementation has a different signature.
    if (kIsWeb) {
      await (getPlayerService() as service_impl.PlayerService).initialize(null, file: file);
    } else {
      await _playerService.initialize(file.path);
    }
    
    _playerService.controller?.addListener(() {
      if (mounted) setState(() {});
    });

    setState(() {}); // Rebuild to show the player
  }

  @override
  void dispose() {
    _playerService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentFileName = _currentlyPlayingIndex != -1 
      ? _playlist[_currentlyPlayingIndex].name 
      : 'LinPlayer';

    return Scaffold(
      appBar: AppBar(
        title: Text(currentFileName),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _pickFile,
          ),
        ],
      ),
      body: Column(
        children: [
          // Video Player Area
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: _playerService.isInitialized
                  ? VideoPlayer(_playerService.controller!)
                  : const Center(
                      child: Text('Select a video to play'),
                    ),
            ),
          ),
          // Playback Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10),
                onPressed: !_playerService.isInitialized ? null : () {
                  final newPosition = _playerService.position - const Duration(seconds: 10);
                  _playerService.seek(newPosition);
                },
              ),
              IconButton(
                icon: Icon(
                  _playerService.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                onPressed: !_playerService.isInitialized ? null : () {
                  setState(() {
                    _playerService.isPlaying
                        ? _playerService.pause()
                        : _playerService.play();
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.forward_10),
                onPressed: !_playerService.isInitialized ? null : () {
                  final newPosition = _playerService.position + const Duration(seconds: 10);
                  _playerService.seek(newPosition);
                },
              ),
            ],
          ),
          // Video Progress Bar
          if (_playerService.isInitialized)
            VideoProgressIndicator(_playerService.controller!, allowScrubbing: true),
          
          // Playlist Area
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text(
              'Playlist',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _playlist.length,
              itemBuilder: (context, index) {
                final file = _playlist[index];
                final isPlaying = index == _currentlyPlayingIndex;
                return ListTile(
                  leading: Icon(isPlaying ? Icons.play_circle_filled : Icons.movie),
                  title: Text(
                    file.name,
                    style: TextStyle(
                      color: isPlaying ? Colors.blue : null,
                    ),
                  ),
                  onTap: () {
                    _playFile(file, index);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
