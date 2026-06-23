import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_registry.dart';
import '../../../core/theme/app_motion.dart';

/// 桌面端「源类型选择器」：添加服务器第一步。可搜索的网格卡片。
class DesktopSourcePickerScreen extends StatefulWidget {
  const DesktopSourcePickerScreen({super.key});

  @override
  State<DesktopSourcePickerScreen> createState() =>
      _DesktopSourcePickerScreenState();
}

class _DesktopSourcePickerScreenState extends State<DesktopSourcePickerScreen> {
  String _query = '';

  void _select(SourceKind kind) {
    if (kind == SourceKind.emby) {
      context.push('/add-emby');
    } else {
      context.push('/add-source/${kind.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = kSourceTypes.where((t) => t.matches(_query)).toList();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '选择要添加的服务',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  decoration: InputDecoration(
                    hintText: '搜索源类型（Emby、OpenList…）',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: types.isEmpty
                      ? const Center(child: Text('没有匹配的源类型'))
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 360,
                            childAspectRatio: 3.4,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                          itemCount: types.length,
                          itemBuilder: (context, index) {
                            final t = types[index];
                            return _DesktopTypeCard(
                              descriptor: t,
                              onTap: () => _select(t.kind),
                            )
                                .animate()
                                .fadeIn(
                                  delay: (index * 50).ms,
                                  duration: AppMotion.medium,
                                )
                                .slideY(begin: 0.1, end: 0);
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopTypeCard extends StatefulWidget {
  final SourceTypeDescriptor descriptor;
  final VoidCallback onTap;

  const _DesktopTypeCard({required this.descriptor, required this.onTap});

  @override
  State<_DesktopTypeCard> createState() => _DesktopTypeCardState();
}

class _DesktopTypeCardState extends State<_DesktopTypeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = widget.descriptor;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _hover
                ? theme.colorScheme.surfaceContainerHighest
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hover
                  ? d.accent.withValues(alpha: 0.5)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: d.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(d.icon, color: d.accent, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(d.name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(
                      d.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.textTheme.bodySmall?.color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
