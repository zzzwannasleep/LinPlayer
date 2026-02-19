import 'package:flutter/material.dart';
import 'package:lin_player_player/lin_player_player.dart';

import 'list_picker_dialog.dart';

Future<DandanplaySearchCandidate?> showDanmakuManualSearchDialog({
  required BuildContext context,
  required List<String> apiUrls,
  String appId = '',
  String appSecret = '',
  required String initialKeyword,
  int? initialEpisodeHint,
}) async {
  final keywordController = TextEditingController(text: initialKeyword.trim());
  final episodeController = TextEditingController(
    text: (initialEpisodeHint != null && initialEpisodeHint > 0)
        ? initialEpisodeHint.toString()
        : '',
  );

  var searching = false;
  var searched = false;
  var autoSearchScheduled = false;
  var apiSourceIndex = -1; // -1 = all
  String? errorText;
  var candidates = const <DandanplaySearchCandidate>[];

  String formatApiUrl(String input) {
    final raw = input.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return raw;
    final path = uri.path.isEmpty || uri.path == '/' ? '' : uri.path;
    return '${uri.host}$path';
  }

  Future<void> doSearch(
    StateSetter setDialogState,
    BuildContext dialogContext,
  ) async {
    final keyword = keywordController.text.trim();
    if (keyword.isEmpty) {
      setDialogState(() {
        searched = true;
        candidates = const [];
        errorText = '请输入番剧名称';
      });
      return;
    }

    final rawEpisode = episodeController.text.trim();
    final episodeHint = rawEpisode.isEmpty ? null : int.tryParse(rawEpisode);

    setDialogState(() {
      searching = true;
      searched = true;
      errorText = null;
    });

    try {
      final effectiveApiUrls = apiSourceIndex < 0 ||
              apiSourceIndex >= apiUrls.length
          ? apiUrls
          : [apiUrls[apiSourceIndex]];
      final results = await searchOnlineDanmakuCandidates(
        apiUrls: effectiveApiUrls,
        keyword: keyword,
        episodeHint:
            (episodeHint != null && episodeHint > 0) ? episodeHint : null,
        appId: appId,
        appSecret: appSecret,
      );

      if (!dialogContext.mounted) return;
      if (results.length == 1) {
        Navigator.of(dialogContext).pop(results.first);
        return;
      }

      setDialogState(() {
        searching = false;
        candidates = results;
        errorText = results.isEmpty ? '未找到结果，可修改名称后重试' : null;
      });
    } catch (e) {
      if (!dialogContext.mounted) return;
      setDialogState(() {
        searching = false;
        candidates = const [];
        errorText = '搜索失败：$e';
      });
    }
  }

  final picked = await showDialog<DandanplaySearchCandidate>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          if (!autoSearchScheduled && initialKeyword.trim().isNotEmpty) {
            autoSearchScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (dialogContext.mounted) {
                doSearch(setDialogState, dialogContext);
              }
            });
          }

          return AlertDialog(
            title: const Text('手动匹配弹幕'),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: keywordController,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      labelText: '番剧名称',
                      hintText: '例如：葬送的芙莉莲',
                    ),
                    onSubmitted: (_) => doSearch(setDialogState, dialogContext),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: episodeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '集数（可选）',
                      hintText: '不填则按番剧名称搜索全部剧集',
                    ),
                    onSubmitted: (_) => doSearch(setDialogState, dialogContext),
                  ),
                  if (apiUrls.length > 1) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '弹幕源：${apiSourceIndex < 0 ? '全部' : formatApiUrl(apiUrls[apiSourceIndex])}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final options = <String>[
                              '全部在线源',
                              ...apiUrls.map(formatApiUrl),
                            ];
                            final picked = await showListPickerDialog(
                              context: dialogContext,
                              title: '选择在线弹幕源',
                              items: options,
                              initialIndex:
                                  apiSourceIndex < 0 ? 0 : apiSourceIndex + 1,
                              height: 260,
                            );
                            if (!dialogContext.mounted || picked == null) {
                              return;
                            }
                            final next = picked == 0 ? -1 : picked - 1;
                            if (next == apiSourceIndex) return;
                            setDialogState(() => apiSourceIndex = next);
                            if (!searching &&
                                searched &&
                                keywordController.text.trim().isNotEmpty) {
                              await doSearch(setDialogState, dialogContext);
                            }
                          },
                          icon: const Icon(Icons.layers_outlined),
                          label: const Text('选择源'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          searching
                              ? '搜索中...'
                              : searched
                                  ? '结果：${candidates.length} 项'
                                  : '请输入名称后搜索',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: searching
                            ? null
                            : () => doSearch(setDialogState, dialogContext),
                        icon: const Icon(Icons.search),
                        label: const Text('搜索'),
                      ),
                    ],
                  ),
                  if (searching) const LinearProgressIndicator(),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        errorText!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 280,
                    child: candidates.isEmpty
                        ? const Center(child: Text('无可选条目'))
                        : ListView.separated(
                            itemCount: candidates.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final c = candidates[index];
                              final title =
                                  '${c.animeTitle.isEmpty ? 'Unknown' : c.animeTitle} ${c.episodeTitle}'
                                      .trim();
                              final subtitle = c.episodeNumber == null
                                  ? '${c.sourceHost} · episodeId=${c.episodeId}'
                                  : '${c.sourceHost} · 第${c.episodeNumber}集 · episodeId=${c.episodeId}';
                              return ListTile(
                                dense: true,
                                title: Text(
                                  title.isEmpty
                                      ? 'episodeId=${c.episodeId}'
                                      : title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => Navigator.of(dialogContext).pop(c),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
            ],
          );
        },
      );
    },
  );

  keywordController.dispose();
  episodeController.dispose();
  return picked;
}
