import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_registry.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';

/// TV 端「源类型选择器」：添加服务器第一步。焦点可选的纵向卡片列表。
///
/// TV 文本输入不便，源类型数量也有限，初版不放搜索框（移动/桌面有搜索）。
class TvSourcePickerScreen extends StatelessWidget {
  const TvSourcePickerScreen({super.key});

  void _select(BuildContext context, SourceKind kind) {
    if (kind == SourceKind.emby) {
      context.go('/tv/add-emby');
    } else {
      context.push('/tv/add-source/${kind.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: m.s(820)),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(m.spacingXxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择要添加的服务',
                  style: TextStyle(
                    fontSize: m.fontSizeXxl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: m.spacingXl),
                ...List.generate(kSourceTypes.length, (i) {
                  final t = kSourceTypes[i];
                  return Padding(
                    padding: EdgeInsets.only(bottom: m.spacingMd),
                    child: TvFocusable(
                      autofocus: i == 0,
                      padding: EdgeInsets.all(m.s(4)),
                      onSelect: () => _select(context, t.kind),
                      child: _card(m, t),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(TvMetrics m, SourceTypeDescriptor t) {
    return Container(
      padding: EdgeInsets.all(m.spacingLg),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        children: [
          Container(
            width: m.s(56),
            height: m.s(56),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
            child: Icon(t.icon, color: t.accent, size: m.s(30)),
          ),
          SizedBox(width: m.spacingLg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.name,
                  style: TextStyle(
                    fontSize: m.fontSizeLg,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: m.spacingXs),
                Text(
                  t.subtitle,
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right,
              color: TvDesignTokens.textSecondary, size: m.s(28)),
        ],
      ),
    );
  }
}
