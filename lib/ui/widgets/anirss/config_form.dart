import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/anirss/anirss_config_spec.dart';
import '../../../core/sources/anirss/anirss_providers.dart';

/// 由 [kAniRssConfigSpec] 驱动的配置表单（Material，移动/桌面共用）。
/// 读写 [configDraftProvider]；未 spec 的字段由「高级(原始)」区只读展示，
/// 保存时随原始 Map 一并回传，永不丢字段。
class AniRssConfigForm extends ConsumerWidget {
  const AniRssConfigForm({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(configDraftProvider);
    final notifier = ref.read(configDraftProvider.notifier);
    final unspecced = draft.keys.where((k) => !kSpeccedConfigKeys.contains(k)).toList()
      ..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in kAniRssConfigSpec)
          _Section(
            title: section.title,
            children: [
              for (final f in section.fields)
                _FieldRow(field: f, value: draft[f.key], notifier: notifier),
            ],
          ),
        if (unspecced.isNotEmpty)
          _AdvancedRawSection(keys: unspecced, draft: draft),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  )),
              const SizedBox(height: 4),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  final CfgField field;
  final dynamic value;
  final ConfigDraftNotifier notifier;
  const _FieldRow(
      {required this.field, required this.value, required this.notifier});

  @override
  Widget build(BuildContext context) {
    switch (field.type) {
      case CfgType.bool_:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(field.label),
          subtitle: field.help != null ? Text(field.help!) : null,
          value: value == true,
          onChanged: (v) => notifier.set(field.key, v),
        );
      case CfgType.enumStr:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: field.label,
              helperText: field.help,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: (field.options ?? const []).contains(value?.toString())
                    ? value.toString()
                    : null,
                items: [
                  for (final o in field.options ?? const [])
                    DropdownMenuItem(value: o, child: Text(o)),
                ],
                onChanged: (v) => notifier.set(field.key, v),
              ),
            ),
          ),
        );
      case CfgType.int_:
        return _TextRow(
          field: field,
          initial: value?.toString() ?? '',
          keyboardType: TextInputType.number,
          onChanged: (s) =>
              notifier.set(field.key, s.isEmpty ? null : int.tryParse(s) ?? value),
        );
      case CfgType.password:
        return _TextRow(
          field: field,
          initial: value?.toString() ?? '',
          obscure: true,
          onChanged: (s) => notifier.set(field.key, s),
        );
      case CfgType.stringList:
        return _TextRow(
          field: field,
          initial: (value is List ? value.join(', ') : (value?.toString() ?? '')),
          onChanged: (s) => notifier.set(
              field.key,
              s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList()),
        );
      case CfgType.string_:
        return _TextRow(
          field: field,
          initial: value?.toString() ?? '',
          onChanged: (s) => notifier.set(field.key, s),
        );
    }
  }
}

class _TextRow extends StatefulWidget {
  final CfgField field;
  final String initial;
  final bool obscure;
  final TextInputType? keyboardType;
  final ValueChanged<String> onChanged;
  const _TextRow({
    required this.field,
    required this.initial,
    required this.onChanged,
    this.obscure = false,
    this.keyboardType,
  });

  @override
  State<_TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<_TextRow> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: _ctrl,
        obscureText: widget.obscure,
        keyboardType: widget.keyboardType,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          labelText: widget.field.label,
          helperText: widget.field.help,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _AdvancedRawSection extends StatelessWidget {
  final List<String> keys;
  final Map<String, dynamic> draft;
  const _AdvancedRawSection({required this.keys, required this.draft});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        title: Text('高级（原始，${keys.length} 项）'),
        subtitle: const Text('未在上方表单中的字段，保存时原样保留'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final k in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(k, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                  Expanded(
                    flex: 5,
                    child: Text('${draft[k]}',
                        style: const TextStyle(fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
