import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_registry.dart';
import '../../../core/theme/app_motion.dart';

/// 添加服务器第一步：可搜索的「源类型选择器」（移动端）。
///
/// 选 Emby → 进入现有 Emby 添加流程；选网盘类 → 进入该源登录页。
/// 列表由 [kSourceTypes] 驱动，后续接入新源会自动出现。
class SourcePickerScreen extends StatefulWidget {
  const SourcePickerScreen({super.key});

  @override
  State<SourcePickerScreen> createState() => _SourcePickerScreenState();
}

class _SourcePickerScreenState extends State<SourcePickerScreen> {
  String _query = '';

  void _select(SourceKind kind) {
    if (kind == SourceKind.emby) {
      context.push('/add/emby');
    } else {
      context.push('/add/source/${kind.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = kSourceTypes.where((t) => t.matches(_query)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('选择要添加的服务')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索源类型（Emby、OpenList…）',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: types.isEmpty
                ? const Center(child: Text('没有匹配的源类型'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: types.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final t = types[index];
                      return _SourceTypeCard(
                        descriptor: t,
                        onTap: () => _select(t.kind),
                      )
                          .animate()
                          .fadeIn(
                            delay: (index * 40).ms,
                            duration: AppMotion.medium,
                          )
                          .slideY(begin: 0.08, end: 0, curve: AppMotion.standard);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SourceTypeCard extends StatelessWidget {
  final SourceTypeDescriptor descriptor;
  final VoidCallback onTap;

  const _SourceTypeCard({required this.descriptor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: descriptor.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(descriptor.icon, color: descriptor.accent, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      descriptor.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      descriptor.subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
