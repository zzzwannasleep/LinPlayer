import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../core/app_identity.dart';
import '../../../ui/widgets/common/media_widgets.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';

/// 默认网络图标库（与移动端 icon_select_screen 保持一致）。
const String _defaultIconLibraryUrl =
    'https://juhe.greentea520.xyz/share/78aspf.json';

class _IconItem {
  final String name;
  final String url;
  const _IconItem({required this.name, required this.url});
}

/// 弹出 TV 风格图标选择器，返回所选图标 URL；取消则返回 null。
Future<String?> showTvIconPicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => const _TvIconPickerDialog(),
  );
}

class _TvIconPickerDialog extends StatefulWidget {
  const _TvIconPickerDialog();

  @override
  State<_TvIconPickerDialog> createState() => _TvIconPickerDialogState();
}

class _TvIconPickerDialogState extends State<_TvIconPickerDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<_IconItem> _all = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final resp = await Dio().get(
        _defaultIconLibraryUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {'User-Agent': kDefaultBrowserUserAgent},
        ),
      );
      final dynamic data = resp.data is String
          ? jsonDecode(resp.data as String)
          : resp.data;
      final items = <_IconItem>[];
      _collect(data, items);
      // 去重（按 url）。
      final seen = <String>{};
      final unique = <_IconItem>[];
      for (final it in items) {
        if (seen.add(it.url)) unique.add(it);
      }
      if (mounted) {
        setState(() {
          _all = unique;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _collect(dynamic node, List<_IconItem> out) {
    if (node is Map) {
      final url = node['url'];
      if (url is String && url.startsWith('http')) {
        final name = (node['name'] ??
                node['title'] ??
                node['label'] ??
                node['sourceName'] ??
                '')
            .toString();
        out.add(_IconItem(name: name, url: url));
      }
      for (final v in node.values) {
        _collect(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collect(v, out);
      }
    }
  }

  List<_IconItem> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all.where((it) => it.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Dialog(
      backgroundColor: TvDesignTokens.surface,
      insetPadding: EdgeInsets.all(m.spacingXxl),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Padding(
        padding: EdgeInsets.all(m.spacingXl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '选择图标',
                  style: TextStyle(
                    fontSize: m.fontSizeXl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TvFocusable(
                  padding: EdgeInsets.all(m.spacingXs),
                  onSelect: () => Navigator.pop(context),
                  child: Icon(Icons.close,
                      color: TvDesignTokens.textSecondary, size: m.s(28)),
                ),
              ],
            ),
            SizedBox(height: m.spacingMd),
            TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                  fontSize: m.fontSizeMd, color: TvDesignTokens.textPrimary),
              cursorColor: TvDesignTokens.brand,
              decoration: InputDecoration(
                hintText: '搜索图标名称…',
                prefixIcon: Icon(Icons.search,
                    color: TvDesignTokens.textSecondary, size: m.s(26)),
              ),
            ),
            SizedBox(height: m.spacingLg),
            Expanded(child: _buildBody(m)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(TvMetrics m) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: TvDesignTokens.brand),
      );
    }
    if (_error != null) {
      return Center(
        child: Text('图标库加载失败：$_error',
            style: TextStyle(
                fontSize: m.fontSizeSm, color: TvDesignTokens.textSecondary)),
      );
    }
    final items = _filtered;
    if (items.isEmpty) {
      return Center(
        child: Text('未找到图标',
            style: TextStyle(
                fontSize: m.fontSizeMd, color: TvDesignTokens.textDisabled)),
      );
    }
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: m.s(120),
        crossAxisSpacing: m.spacingMd,
        mainAxisSpacing: m.spacingMd,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final it = items[index];
        return TvFocusable(
          padding: EdgeInsets.all(m.s(4)),
          onSelect: () => Navigator.pop(context, it.url),
          child: Container(
            decoration: BoxDecoration(
              color: TvDesignTokens.surfaceElevated,
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
            clipBehavior: Clip.antiAlias,
            padding: EdgeInsets.all(m.s(10)),
            child: MediaImage(
              imageUrl: it.url,
              fit: BoxFit.contain,
              useDefaultUserAgent: true,
            ),
          ),
        );
      },
    );
  }
}
