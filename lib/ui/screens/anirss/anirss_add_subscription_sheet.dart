import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/bgm_info.dart';
import '../../widgets/common/media_widgets.dart';

/// 弹出「搜索并添加订阅」面板（BGM 搜索 → 生成订阅 → addAni）。
Future<void> showAniRssAddSubscriptionSheet(
    BuildContext context, WidgetRef ref) {
  final api = ref.read(aniRssApiProvider);
  if (api == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _AddSubscriptionSheet(api: api, parentRef: ref),
  );
}

class _AddSubscriptionSheet extends StatefulWidget {
  final AniRssApi api;
  final WidgetRef parentRef;
  const _AddSubscriptionSheet({required this.api, required this.parentRef});

  @override
  State<_AddSubscriptionSheet> createState() => _AddSubscriptionSheetState();
}

class _AddSubscriptionSheetState extends State<_AddSubscriptionSheet> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _addingId;
  List<BgmInfoModel> _results = const [];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.searchBgm(q);
      setState(() => _results = r);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(BgmInfoModel bgm) async {
    setState(() => _addingId = bgm.id);
    try {
      final ani = await widget.api.getAniBySubjectId(bgm.id);
      await widget.api.addAni(ani);
      widget.parentRef.invalidate(aniListProvider);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已添加订阅「${bgm.displayName}」')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _addingId = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('添加失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('搜索并添加订阅',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    hintText: '输入番剧名（BGM 搜索）',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _search,
                child: const Text('搜索'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: _buildResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!));
    if (_results.isEmpty) {
      return const Center(child: Text('输入关键词后点搜索', style: TextStyle(color: Colors.grey)));
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final bgm = _results[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(
            width: 44,
            height: 60,
            child: MediaImage(
              imageUrl: bgm.image,
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          title: Text(bgm.displayName,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (bgm.date != null) bgm.date!.split('T').first,
              if (bgm.eps != null) '${bgm.eps} 集',
              if (bgm.score != null && bgm.score! > 0) '★ ${bgm.score!.toStringAsFixed(1)}',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _addingId == bgm.id
              ? const SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : FilledButton.tonal(
                  onPressed: _addingId != null ? null : () => _add(bgm),
                  child: const Text('添加'),
                ),
        );
      },
    );
  }
}
