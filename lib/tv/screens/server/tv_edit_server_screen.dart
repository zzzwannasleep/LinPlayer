import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_toast.dart';

/// TV / Pad 服务器编辑页
///
/// 对齐 PC 端编辑能力：可改名称、备注（信息），更换图标，
/// 以及管理线路（增/删/改/设为当前）。从服务器卡片长按或编辑按钮进入。
class TvEditServerScreen extends ConsumerStatefulWidget {
  final String? serverId;

  const TvEditServerScreen({super.key, this.serverId});

  @override
  ConsumerState<TvEditServerScreen> createState() => _TvEditServerScreenState();
}

class _TvEditServerScreenState extends ConsumerState<TvEditServerScreen> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _remarkCtrl = TextEditingController();
  final TextEditingController _iconCtrl = TextEditingController();

  List<ServerLine> _lines = [];
  int _activeLineIndex = 0;
  bool _loaded = false;

  ServerConfig? _findServer() {
    final servers = ref.read(serverListProvider);
    for (final s in servers) {
      if (s.id == widget.serverId) return s;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final server = _findServer();
    if (server != null) {
      _nameCtrl.text = server.name;
      _remarkCtrl.text = server.remark ?? '';
      _iconCtrl.text = server.iconUrl ?? '';
      _lines = List<ServerLine>.from(server.lines);
      _activeLineIndex = server.activeLineIndex;
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _remarkCtrl.dispose();
    _iconCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final server = _findServer();
    if (server == null) return;
    final name = _nameCtrl.text.trim();
    final updated = server.copyWith(
      name: name.isEmpty ? server.name : name,
      remark: _remarkCtrl.text.trim(),
      iconUrl: _iconCtrl.text.trim(),
      lines: _lines,
      activeLineIndex: _lines.isEmpty
          ? 0
          : _activeLineIndex.clamp(0, _lines.length - 1),
    );
    ref.read(serverListProvider.notifier).updateServer(updated);
    // 若编辑的是当前服务器，同步刷新当前引用，使线路切换立即生效。
    if (ref.read(currentServerProvider)?.id == updated.id) {
      ref.read(currentServerProvider.notifier).state = updated;
    }
    TvToast.show(context, '已保存');
    context.pop();
  }

  String _newLineId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> _editLine({ServerLine? existing, int? index}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final remarkCtrl = TextEditingController(text: existing?.remark ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final m = dialogContext.tv;
        return TvPanel(
          title: existing == null ? '新增线路' : '编辑线路',
          onClose: () => Navigator.pop(dialogContext, false),
          children: [
            _dialogField(m, '线路名称', nameCtrl),
            SizedBox(height: m.spacingMd),
            _dialogField(m, '线路地址 (http://…)', urlCtrl,
                keyboardType: TextInputType.url),
            SizedBox(height: m.spacingMd),
            _dialogField(m, '备注（可选）', remarkCtrl),
            SizedBox(height: m.spacingLg),
            Row(
              children: [
                Expanded(
                  child: TvFocusable(
                    onSelect: () => Navigator.pop(dialogContext, false),
                    child: _pillButton('取消', TvDesignTokens.surface,
                        TvDesignTokens.textPrimary, m),
                  ),
                ),
                SizedBox(width: m.spacingMd),
                Expanded(
                  child: TvFocusable(
                    autofocus: true,
                    onSelect: () => Navigator.pop(dialogContext, true),
                    child: _pillButton(
                        '确定', TvDesignTokens.brand, Colors.white, m),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );

    if (result == true && mounted) {
      final url = urlCtrl.text.trim();
      if (url.isEmpty) {
        TvToast.show(context, '线路地址不能为空');
      } else {
        final line = ServerLine(
          id: existing?.id ?? _newLineId(),
          name: nameCtrl.text.trim().isEmpty
              ? '线路 ${_lines.length + 1}'
              : nameCtrl.text.trim(),
          url: url,
          remark: remarkCtrl.text.trim().isEmpty ? null : remarkCtrl.text.trim(),
        );
        setState(() {
          if (existing != null && index != null) {
            _lines[index] = line;
          } else {
            _lines = [..._lines, line];
          }
        });
      }
    }
    nameCtrl.dispose();
    urlCtrl.dispose();
    remarkCtrl.dispose();
  }

  void _deleteLine(int index) {
    setState(() {
      _lines = [..._lines]..removeAt(index);
      if (_activeLineIndex >= _lines.length) {
        _activeLineIndex = _lines.isEmpty ? 0 : _lines.length - 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    if (!_loaded) {
      return Scaffold(
        backgroundColor: TvDesignTokens.background,
        body: Center(
          child: Text('服务器不存在',
              style: TextStyle(
                  color: TvDesignTokens.textSecondary,
                  fontSize: m.fontSizeMd)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.s(900)),
            child: ListView(
              padding: EdgeInsets.all(m.spacingXl),
              children: [
                Row(
                  children: [
                    TvFocusable(
                      padding: EdgeInsets.all(m.spacingXs),
                      onSelect: () => context.pop(),
                      child: Icon(Icons.arrow_back,
                          color: TvDesignTokens.textPrimary, size: m.s(32)),
                    ),
                    SizedBox(width: m.spacingMd),
                    Text(
                      '编辑服务器',
                      style: TextStyle(
                        fontSize: m.fontSizeXxl,
                        color: TvDesignTokens.textPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: m.spacingXl),
                _sectionTitle('基本信息', m),
                SizedBox(height: m.spacingMd),
                _field(m, '服务器名称', _nameCtrl),
                SizedBox(height: m.spacingMd),
                _field(m, '备注信息', _remarkCtrl),
                SizedBox(height: m.spacingMd),
                _buildIconField(m),
                SizedBox(height: m.spacingXl),
                _buildLinesSection(m),
                SizedBox(height: m.spacingXl),
                Row(
                  children: [
                    Expanded(
                      child: TvFocusable(
                        onSelect: () => context.pop(),
                        child: _pillButton('取消', TvDesignTokens.surface,
                            TvDesignTokens.textPrimary, m),
                      ),
                    ),
                    SizedBox(width: m.spacingMd),
                    Expanded(
                      child: TvFocusable(
                        onSelect: _save,
                        child: _pillButton(
                            '保存', TvDesignTokens.brand, Colors.white, m),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIconField(TvMetrics m) {
    final url = _iconCtrl.text.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: m.s(64),
          height: m.s(64),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          clipBehavior: Clip.antiAlias,
          child: url.isEmpty
              ? Icon(Icons.storage,
                  color: TvDesignTokens.textSecondary, size: m.s(32))
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(Icons.broken_image,
                      color: TvDesignTokens.textDisabled, size: m.s(28)),
                ),
        ),
        SizedBox(width: m.spacingMd),
        Expanded(
          child: _field(m, '图标地址 (URL)', _iconCtrl,
              onChanged: (_) => setState(() {})),
        ),
      ],
    );
  }

  Widget _buildLinesSection(TvMetrics m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle('线路管理', m),
            const Spacer(),
            TvFocusable(
              padding: EdgeInsets.all(m.spacingXs),
              onSelect: () => _editLine(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add,
                      color: TvDesignTokens.brand, size: m.s(24)),
                  SizedBox(width: m.spacingXs),
                  Text('新增线路',
                      style: TextStyle(
                          fontSize: m.fontSizeSm,
                          color: TvDesignTokens.brand)),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: m.spacingMd),
        if (_lines.isEmpty)
          Text('暂无线路（将使用服务器默认地址）',
              style: TextStyle(
                  fontSize: m.fontSizeSm,
                  color: TvDesignTokens.textDisabled))
        else
          for (final entry in _lines.asMap().entries)
            _buildLineRow(m, entry.key, entry.value),
      ],
    );
  }

  Widget _buildLineRow(TvMetrics m, int index, ServerLine line) {
    final active = index == _activeLineIndex;
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: Container(
        padding: EdgeInsets.all(m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
          border: active
              ? Border.all(color: TvDesignTokens.brand, width: m.s(2))
              : null,
        ),
        child: Row(
          children: [
            TvFocusable(
              padding: EdgeInsets.all(m.spacingXs),
              onSelect: () => setState(() => _activeLineIndex = index),
              child: Icon(
                active ? Icons.radio_button_checked : Icons.radio_button_off,
                color: active
                    ? TvDesignTokens.brand
                    : TvDesignTokens.textSecondary,
                size: m.s(28),
              ),
            ),
            SizedBox(width: m.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: m.fontSizeMd,
                          color: TvDesignTokens.textPrimary,
                          fontWeight: FontWeight.w500)),
                  SizedBox(height: m.spacingXs),
                  Text(line.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: m.fontSizeXs,
                          color: TvDesignTokens.textSecondary)),
                ],
              ),
            ),
            TvFocusable(
              padding: EdgeInsets.all(m.spacingXs),
              onSelect: () => _editLine(existing: line, index: index),
              child: Icon(Icons.edit_outlined,
                  color: TvDesignTokens.textSecondary, size: m.s(24)),
            ),
            SizedBox(width: m.spacingXs),
            TvFocusable(
              padding: EdgeInsets.all(m.spacingXs),
              onSelect: () => _deleteLine(index),
              child: Icon(Icons.delete_outline,
                  color: TvDesignTokens.error, size: m.s(24)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, TvMetrics m) => Text(
        text,
        style: TextStyle(
          fontSize: m.fontSizeLg,
          color: TvDesignTokens.textPrimary,
          fontWeight: FontWeight.bold,
        ),
      );

  Widget _field(TvMetrics m, String label, TextEditingController ctrl,
      {TextInputType? keyboardType, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      onChanged: onChanged,
      style: TextStyle(
        fontSize: m.fontSizeMd,
        color: TvDesignTokens.textPrimary,
      ),
      cursorColor: TvDesignTokens.brand,
      decoration: InputDecoration(labelText: label),
    );
  }

  Widget _dialogField(TvMetrics m, String label, TextEditingController ctrl,
      {TextInputType? keyboardType}) {
    return _field(m, label, ctrl, keyboardType: keyboardType);
  }

  Widget _pillButton(String text, Color bg, Color fg, TvMetrics m) {
    return Container(
      padding: EdgeInsets.all(m.spacingMd),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Center(
        child: Text(text,
            style: TextStyle(
                fontSize: m.fontSizeMd,
                color: fg,
                fontWeight: FontWeight.bold)),
      ),
    );
  }
}
