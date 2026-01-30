import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_config/app_config_scope.dart';
import '../services/emos_api.dart';
import '../state/app_state.dart';

class EmosUploadPage extends StatefulWidget {
  const EmosUploadPage({super.key, required this.appState});

  final AppState appState;

  @override
  State<EmosUploadPage> createState() => _EmosUploadPageState();
}

class _EmosUploadPageState extends State<EmosUploadPage> {
  bool _busy = false;
  String? _error;

  String _type = 'video'; // video/subtitle/image
  String _itemType = 'vl';
  final _itemIdCtrl = TextEditingController();

  String _fileStorage = 'default';
  PlatformFile? _picked;
  int _fileSize = 0;
  String _fileMime = '';
  dynamic _tokenResp;

  final _fileIdCtrl = TextEditingController();

  EmosApi _api() {
    final config = AppConfigScope.of(context);
    final token = widget.appState.emosSession?.token ?? '';
    return EmosApi(baseUrl: config.emosBaseUrl, token: token);
  }

  @override
  void dispose() {
    _itemIdCtrl.dispose();
    _fileIdCtrl.dispose();
    super.dispose();
  }

  String _pretty(dynamic data) {
    try {
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  String _guessMime(PlatformFile f) {
    final ext = (f.extension ?? '').toLowerCase().trim();
    return switch (ext) {
      'mp4' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'm4v' => 'video/x-m4v',
      'srt' => 'application/x-subrip',
      'ass' => 'text/x-ssa',
      'ssa' => 'text/x-ssa',
      'vtt' => 'text/vtt',
      'sub' => 'text/plain',
      'zip' => 'application/zip',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(withData: kIsWeb);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    setState(() {
      _picked = f;
      _fileSize = f.size;
      _fileMime = _guessMime(f);
    });
  }

  Future<void> _getToken() async {
    final f = _picked;
    if (f == null) return;
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resp = await _api().getUploadToken(
        type: _type,
        fileType: _fileMime.isEmpty ? 'application/octet-stream' : _fileMime,
        fileName: f.name,
        fileSize: _fileSize,
        fileStorage: _fileStorage,
      );
      if (!mounted) return;
      setState(() => _tokenResp = resp);

      String? fileId;
      if (resp is Map && resp['file_id'] != null) {
        fileId = resp['file_id'].toString().trim();
      } else if (resp is Map && resp['id'] != null) {
        fileId = resp['id'].toString().trim();
      }
      if (fileId != null && fileId.isNotEmpty) {
        _fileIdCtrl.text = fileId;
      }

      await showDialog<void>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Upload token'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(child: SelectableText(_pretty(resp))),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadVideoBase() async {
    final itemId = _itemIdCtrl.text.trim();
    if (itemId.isEmpty) return;
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final base = await _api().fetchUploadVideoBase(
        itemType: _itemType,
        itemId: itemId,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: const Text('Upload base'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(child: SelectableText(_pretty(base))),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveUpload() async {
    final itemId = _itemIdCtrl.text.trim();
    final fileId = _fileIdCtrl.text.trim();
    if (itemId.isEmpty || fileId.isEmpty) return;

    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_type == 'video') {
        await _api().saveUploadedVideo(
          itemType: _itemType,
          itemId: itemId,
          fileId: fileId,
        );
      } else if (_type == 'subtitle') {
        await _api().saveUploadedSubtitle(
          itemType: _itemType,
          itemId: itemId,
          fileId: fileId,
        );
      } else {
        throw UnsupportedError('No save endpoint for type=$_type');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tryDirectUpload() async {
    if (kIsWeb) return;
    final f = _picked;
    final resp = _tokenResp;
    if (f == null || resp is! Map) return;
    final url = (resp['upload_url'] ?? resp['url'])?.toString().trim() ?? '';
    if (url.isEmpty) return;
    final path = f.path ?? '';
    if (path.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final client = HttpClient();
      final req = await client.putUrl(Uri.parse(url));
      req.headers.set('Content-Type', _fileMime.isEmpty ? 'application/octet-stream' : _fileMime);
      req.add(bytes);
      final resp2 = await req.close();
      if (resp2.statusCode < 200 || resp2.statusCode >= 300) {
        throw HttpException('Upload failed: HTTP ${resp2.statusCode}');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uploaded (direct)')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        if (!widget.appState.hasEmosSession) {
          return const Scaffold(body: Center(child: Text('Not signed in')));
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Upload'),
            actions: [
              IconButton(
                tooltip: 'Pick file',
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.attach_file),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      DropdownMenu<String>(
                        initialSelection: _type,
                        label: const Text('Type'),
                        dropdownMenuEntries: const [
                          DropdownMenuEntry(value: 'video', label: 'Video'),
                          DropdownMenuEntry(value: 'subtitle', label: 'Subtitle'),
                          DropdownMenuEntry(value: 'image', label: 'Image'),
                        ],
                        onSelected: _busy ? null : (v) => setState(() => _type = v ?? 'video'),
                      ),
                      const SizedBox(height: 12),
                      DropdownMenu<String>(
                        initialSelection: _itemType,
                        label: const Text('Item type'),
                        dropdownMenuEntries: const [
                          DropdownMenuEntry(value: 'vl', label: 'vl (video list)'),
                          DropdownMenuEntry(value: 'vs', label: 'vs (season)'),
                          DropdownMenuEntry(value: 've', label: 've (episode)'),
                          DropdownMenuEntry(value: 'vp', label: 'vp (part)'),
                        ],
                        onSelected: _busy ? null : (v) => setState(() => _itemType = v ?? 'vl'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _itemIdCtrl,
                        decoration: const InputDecoration(labelText: 'Item id'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownMenu<String>(
                              initialSelection: _fileStorage,
                              label: const Text('Storage'),
                              dropdownMenuEntries: const [
                                DropdownMenuEntry(value: 'default', label: 'default'),
                                DropdownMenuEntry(value: 'internal', label: 'internal'),
                                DropdownMenuEntry(value: 'global', label: 'global'),
                              ],
                              onSelected: _busy
                                  ? null
                                  : (v) => setState(() => _fileStorage = v ?? 'default'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_type == 'video')
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _loadVideoBase,
                          icon: const Icon(Icons.info_outline),
                          label: const Text('Load upload base'),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _picked == null
                            ? 'No file selected'
                            : 'File: ${_picked!.name}\nSize: $_fileSize bytes\nMIME: ${_fileMime.isEmpty ? '(unknown)' : _fileMime}',
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: (_picked == null || _busy) ? null : _getToken,
                              icon: const Icon(Icons.vpn_key_outlined),
                              label: const Text('Get upload token'),
                            ),
                          ),
                        ],
                      ),
                      if (!kIsWeb) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _tryDirectUpload,
                          icon: const Icon(Icons.cloud_upload_outlined),
                          label: const Text('Try direct upload (best-effort)'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      TextField(
                        controller: _fileIdCtrl,
                        decoration: const InputDecoration(
                          labelText: 'file_id',
                          hintText: 'Paste file_id after upload',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy ? null : _saveUpload,
                              icon: const Icon(Icons.save_outlined),
                              label: const Text('Save upload result'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Note: The server did not provide a sample getUploadToken response in the Postman export. '
                        'This page supports token fetching + save result. Direct upload is best-effort.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
