import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/models/play_item.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../screens/source/source_player_screen.dart';

/// 把一个 [PlayItemModel] 构造成播放后端认识的 [SourceEntry]（与 AniRssBackend.resolvePlay 对齐）。
SourceEntry sourceEntryFor(PlayItemModel item) => SourceEntry(
      id: 'file:${item.filename}',
      name: item.title ?? item.decodedName,
      isDir: false,
      isVideo: true,
      raw: {
        'filename': item.filename,
        'episode': item.episode,
        // resolvePlay._subtitlesOf 读 raw['subtitles'] 为 List<Map>。
        'subtitles': item.subtitles.map((s) => s.toJson()).toList(),
      },
    );

/// 跳转直链播放页（移动/桌面共用 `/source-player`）。
void playSourceItem(
    BuildContext context, ServerConfig server, PlayItemModel item) {
  context.push(
    '/source-player',
    extra: SourcePlayArgs(server: server, entry: sourceEntryFor(item)),
  );
}

/// 字幕组/版本标注。
String versionLabel(PlayItemModel item) {
  final parts = <String>[];
  final sub = _subgroupOf(item.decodedName);
  if (sub != null) parts.add(sub);
  if (item.extName != null && item.extName!.isNotEmpty) {
    parts.add(item.extName!.toUpperCase());
  }
  if (item.formatSize != null) parts.add(item.formatSize!);
  return parts.isEmpty ? item.decodedName : parts.join(' · ');
}

String? _subgroupOf(String name) {
  // 取文件名里第一个 [..]/【..】 块作字幕组。
  final m = RegExp(r'[\[【]([^\]】]+)[\]】]').firstMatch(name);
  return m?.group(1);
}

/// 弹出版本选择（同一集多个文件）。选中即播放。
Future<void> showVersionPicker(
  BuildContext context,
  ServerConfig server,
  List<PlayItemModel> versions,
) async {
  if (versions.length == 1) {
    playSourceItem(context, server, versions.first);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text('选择版本',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          for (final v in versions)
            ListTile(
              leading: const Icon(Icons.movie_outlined),
              title: Text(versionLabel(v),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(v.decodedName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(context);
                playSourceItem(context, server, v);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
