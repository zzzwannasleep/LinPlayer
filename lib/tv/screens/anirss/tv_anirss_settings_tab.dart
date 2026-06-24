import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/anirss/anirss_config_spec.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/anirss_token.dart';
import '../../../core/sources/anirss/models/ani_config.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_toast.dart';

/// Ani-rss 设置 Tab（TV）：服务器管理 + 关于 + 服务端 Config 镜像。
/// Config 表单由 kAniRssConfigSpec 驱动：bool → 焦点开关行；string/int → 焦点行打开文本输入对话框。
class TvAniRssSettingsTab extends ConsumerStatefulWidget {
  final ServerConfig server;
  const TvAniRssSettingsTab({super.key, required this.server});

  @override
  ConsumerState<TvAniRssSettingsTab> createState() =>
      _TvAniRssSettingsTabState();
}

class _TvAniRssSettingsTabState extends ConsumerState<TvAniRssSettingsTab> {
  bool _seeded = false;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final asyncConfig = ref.watch(aniConfigProvider);
    final draft = ref.watch(configDraftProvider);

    // 配置加载完成后播种草稿一次。
    ref.listen(aniConfigProvider, (_, next) {
      next.whenData((cfg) {
        if (!_seeded) {
          _seeded = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(configDraftProvider.notifier).seed(cfg.raw);
          });
        }
      });
    });

    return ListView(
      children: [
        _buildSectionTitle(m, '服务器'),
        _ServerManagementCard(server: widget.server),
        SizedBox(height: m.spacingLg),
        _buildSectionTitle(m, '关于'),
        _buildAbout(m),
        SizedBox(height: m.spacingLg),
        _buildSectionTitle(m, 'Ani-rss 服务端设置'),
        asyncConfig.when(
          loading: () => Padding(
            padding: EdgeInsets.all(m.spacingLg),
            child: const Center(
                child:
                    CircularProgressIndicator(color: TvDesignTokens.brand)),
          ),
          error: (e, _) => Padding(
            padding: EdgeInsets.all(m.spacingMd),
            child: Text('读取配置失败：$e',
                style: TextStyle(
                    fontSize: m.fontSizeSm, color: TvDesignTokens.error)),
          ),
          data: (_) => _buildConfigForm(m, draft),
        ),
        SizedBox(height: m.spacingXxl),
      ],
    );
  }

  Widget _buildSectionTitle(TvMetrics m, String text) => Padding(
        padding: EdgeInsets.fromLTRB(
            m.spacingXs, m.spacingMd, m.spacingXs, m.spacingSm),
        child: Text(text,
            style: TextStyle(
                fontSize: m.fontSizeLg,
                color: TvDesignTokens.textPrimary,
                fontWeight: FontWeight.bold)),
      );

  Widget _buildAbout(TvMetrics m) {
    final asyncAbout = ref.watch(aniAboutProvider);
    return asyncAbout.when(
      loading: () => _infoRow(m, Icons.info_outline, '关于', '加载中…'),
      error: (_, __) => _infoRow(m, Icons.info_outline, '关于', '版本信息不可用'),
      data: (about) => _infoRow(
        m,
        Icons.info_outline,
        'Ani-rss ${about.version ?? ''}',
        about.update ? '有新版本：${about.latest ?? ''}' : '已是最新版本',
      ),
    );
  }

  Widget _infoRow(TvMetrics m, IconData icon, String title, String subtitle) {
    return Container(
      margin: EdgeInsets.only(bottom: m.spacingSm),
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingLg, vertical: m.spacingMd),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        children: [
          Icon(icon, color: TvDesignTokens.textSecondary, size: m.s(28)),
          SizedBox(width: m.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: TvDesignTokens.textPrimary)),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: m.fontSizeXs,
                        color: TvDesignTokens.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigForm(TvMetrics m, Map<String, dynamic> draft) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in kAniRssConfigSpec) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
                m.spacingXs, m.spacingMd, m.spacingXs, m.spacingSm),
            child: Text(section.title,
                style: TextStyle(
                    fontSize: m.fontSizeMd,
                    color: TvDesignTokens.brand,
                    fontWeight: FontWeight.w600)),
          ),
          for (final field in section.fields)
            _buildField(m, field, draft),
        ],
        SizedBox(height: m.spacingLg),
        TvFocusable(
          padding: EdgeInsets.all(m.s(4)),
          onSelect: _saving ? null : _save,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: m.spacingLg, vertical: m.spacingMd),
            decoration: BoxDecoration(
              color: TvDesignTokens.brand,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_saving ? Icons.hourglass_top : Icons.save,
                    color: Colors.white, size: m.s(26)),
                SizedBox(width: m.spacingXs),
                Text(_saving ? '保存中…' : '保存设置',
                    style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: Colors.white,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildField(
      TvMetrics m, CfgField field, Map<String, dynamic> draft) {
    final value = draft[field.key];
    if (field.type == CfgType.bool_) {
      final on = value == true;
      return Padding(
        padding: EdgeInsets.only(bottom: m.spacingSm),
        child: TvFocusable(
          padding: EdgeInsets.all(m.s(4)),
          onSelect: () =>
              ref.read(configDraftProvider.notifier).set(field.key, !on),
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: m.spacingLg, vertical: m.spacingMd),
            decoration: BoxDecoration(
              color: TvDesignTokens.surface,
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
            child: Row(
              children: [
                Expanded(child: _fieldLabel(m, field)),
                _toggle(m, on),
              ],
            ),
          ),
        ),
      );
    }
    // string / int / enum / password → 文本输入对话框。
    final display = field.type == CfgType.password
        ? ((value?.toString().isNotEmpty ?? false) ? '••••••' : '未设置')
        : (value?.toString().isNotEmpty == true ? value.toString() : '未设置');
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: TvFocusable(
        padding: EdgeInsets.all(m.s(4)),
        onSelect: () => _editField(field, value),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: m.spacingLg, vertical: m.spacingMd),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: Row(
            children: [
              Expanded(child: _fieldLabel(m, field)),
              SizedBox(width: m.spacingMd),
              Flexible(
                child: Text(display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: m.fontSizeSm,
                        color: TvDesignTokens.textSecondary)),
              ),
              SizedBox(width: m.spacingSm),
              Icon(Icons.chevron_right,
                  color: TvDesignTokens.textSecondary, size: m.s(24)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(TvMetrics m, CfgField field) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(field.label,
            style: TextStyle(
                fontSize: m.fontSizeMd, color: TvDesignTokens.textPrimary)),
        if (field.help != null)
          Text(field.help!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: m.fontSizeXs,
                  color: TvDesignTokens.textSecondary)),
      ],
    );
  }

  Widget _toggle(TvMetrics m, bool on) {
    return Container(
      width: m.s(56),
      height: m.s(30),
      padding: EdgeInsets.all(m.s(3)),
      decoration: BoxDecoration(
        color: on ? TvDesignTokens.brand : TvDesignTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Align(
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: m.s(24),
          height: m.s(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Future<void> _editField(CfgField field, dynamic current) async {
    final isNumber = field.type == CfgType.int_;
    final result = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: field.label,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      pageBuilder: (ctx, _, __) => _TextInputDialog(
        title: field.label,
        help: field.help,
        options: field.options,
        initial: current?.toString() ?? '',
        isNumber: isNumber,
        obscure: field.type == CfgType.password,
      ),
    );
    if (result == null) return;
    dynamic toStore = result;
    if (isNumber) {
      toStore = int.tryParse(result.trim()) ?? current;
    }
    ref.read(configDraftProvider.notifier).set(field.key, toStore);
  }

  Future<void> _save() async {
    final api = ref.read(aniRssApiProvider);
    if (api == null) return;
    setState(() => _saving = true);
    try {
      final draft = ref.read(configDraftProvider);
      await api.setConfig(ConfigModel(Map<String, dynamic>.from(draft)));
      ref.invalidate(aniConfigProvider);
      _seeded = false;
      if (mounted) TvToast.show(context, '设置已保存');
    } catch (e) {
      if (mounted) TvToast.show(context, '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// 服务器管理卡：切换线路 / 重新登录 / 移除。
class _ServerManagementCard extends ConsumerWidget {
  final ServerConfig server;
  const _ServerManagementCard({required this.server});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    return Column(
      children: [
        _infoTile(m, Icons.dns_rounded, server.name, server.activeLineUrl),
        if (server.lines.length > 1)
          _actionTile(
            context,
            m,
            Icons.alt_route_rounded,
            '切换线路',
            server.lines[server.activeLineIndex
                    .clamp(0, server.lines.length - 1)]
                .name,
            () => _switchLine(context, ref),
          ),
        _actionTile(context, m, Icons.login_rounded, '重新登录', '凭据失效时刷新令牌',
            () => _reLogin(context, ref)),
        _actionTile(context, m, Icons.delete_outline, '移除此服务器', '仅从本应用移除',
            () => _remove(context, ref),
            danger: true),
      ],
    );
  }

  Widget _infoTile(
      TvMetrics m, IconData icon, String title, String subtitle) {
    return Container(
      margin: EdgeInsets.only(bottom: m.spacingSm),
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingLg, vertical: m.spacingMd),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        children: [
          Icon(icon, color: TvDesignTokens.brand, size: m.s(28)),
          SizedBox(width: m.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: TvDesignTokens.textPrimary)),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: m.fontSizeXs,
                        color: TvDesignTokens.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile(BuildContext context, TvMetrics m, IconData icon,
      String title, String subtitle, VoidCallback onTap,
      {bool danger = false}) {
    final c = danger ? TvDesignTokens.error : TvDesignTokens.textPrimary;
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingSm),
      child: TvFocusable(
        padding: EdgeInsets.all(m.s(4)),
        onSelect: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: m.spacingLg, vertical: m.spacingMd),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: Row(
            children: [
              Icon(icon,
                  color: danger
                      ? TvDesignTokens.error
                      : TvDesignTokens.textSecondary,
                  size: m.s(28)),
              SizedBox(width: m.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: TextStyle(fontSize: m.fontSizeMd, color: c)),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: m.fontSizeXs,
                            color: TvDesignTokens.textSecondary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: TvDesignTokens.textSecondary, size: m.s(24)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _switchLine(BuildContext context, WidgetRef ref) async {
    final m = context.tv;
    final idx = await showGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '切换线路',
      barrierColor: Colors.black.withValues(alpha: 0.7),
      pageBuilder: (ctx, _, __) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: m.s(640),
            constraints: BoxConstraints(maxHeight: m.s(600)),
            padding: EdgeInsets.all(m.spacingXl),
            decoration: BoxDecoration(
              color: TvDesignTokens.surface,
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('切换线路',
                    style: TextStyle(
                        fontSize: m.fontSizeLg,
                        color: TvDesignTokens.textPrimary,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: m.spacingMd),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: server.lines.length,
                    itemBuilder: (context, i) {
                      final selected = i == server.activeLineIndex;
                      return Padding(
                        padding: EdgeInsets.only(bottom: m.spacingSm),
                        child: TvFocusable(
                          autofocus: selected,
                          padding: EdgeInsets.all(m.s(4)),
                          onSelect: () => Navigator.of(ctx).pop(i),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: m.spacingLg,
                                vertical: m.spacingMd),
                            decoration: BoxDecoration(
                              color: TvDesignTokens.surfaceElevated,
                              borderRadius:
                                  BorderRadius.circular(m.posterRadius),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                    selected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    color: selected
                                        ? TvDesignTokens.brand
                                        : TvDesignTokens.textSecondary,
                                    size: m.s(24)),
                                SizedBox(width: m.spacingMd),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(server.lines[i].name,
                                          style: TextStyle(
                                              fontSize: m.fontSizeMd,
                                              color: TvDesignTokens
                                                  .textPrimary)),
                                      Text(server.lines[i].url,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: m.fontSizeXs,
                                              color: TvDesignTokens
                                                  .textSecondary)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (idx == null) return;
    ref.read(serverListProvider.notifier).setActiveLine(server.id, idx);
    AniRssAuth.instance.clearToken(server.id);
    final updated = ref
        .read(serverListProvider)
        .firstWhere((s) => s.id == server.id, orElse: () => server);
    ref.read(currentServerProvider.notifier).state = updated;
    _invalidateAll(ref);
    if (context.mounted) TvToast.show(context, '已切换线路');
  }

  Future<void> _reLogin(BuildContext context, WidgetRef ref) async {
    final u = server.username ?? '';
    final p = server.password ?? '';
    if (u.isEmpty || p.isEmpty) {
      TvToast.show(context, '未保存账密，无法自动重登');
      return;
    }
    try {
      final token = await AniRssAuth.login(server.activeLineUrl, u, p);
      AniRssAuth.instance.cacheToken(server.id, token);
      final updated = server.copyWith(authToken: token);
      ref.read(serverListProvider.notifier).updateServer(updated);
      ref.read(currentServerProvider.notifier).state = updated;
      _invalidateAll(ref);
      if (context.mounted) TvToast.show(context, '已重新登录');
    } catch (e) {
      if (context.mounted) TvToast.show(context, '重新登录失败：$e');
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final m = context.tv;
    final ok = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '移除服务器',
      barrierColor: Colors.black.withValues(alpha: 0.7),
      pageBuilder: (ctx, _, __) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: m.s(560),
            padding: EdgeInsets.all(m.spacingXl),
            decoration: BoxDecoration(
              color: TvDesignTokens.surface,
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('移除「${server.name}」？',
                    style: TextStyle(
                        fontSize: m.fontSizeLg,
                        color: TvDesignTokens.textPrimary,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: m.spacingSm),
                Text('仅从本应用移除该服务器，不影响 Ani-rss 服务端。',
                    style: TextStyle(
                        fontSize: m.fontSizeSm,
                        color: TvDesignTokens.textSecondary)),
                SizedBox(height: m.spacingLg),
                Row(
                  children: [
                    Expanded(
                      child: TvFocusable(
                        autofocus: true,
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => Navigator.of(ctx).pop(false),
                        child: _dlgBtn(m, '取消', filled: false),
                      ),
                    ),
                    SizedBox(width: m.spacingMd),
                    Expanded(
                      child: TvFocusable(
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => Navigator.of(ctx).pop(true),
                        child: _dlgBtn(m, '移除', danger: true),
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
    if (ok != true) return;
    AniRssAuth.instance.clearToken(server.id);
    ref.read(serverListProvider.notifier).removeServer(server.id);
    if (context.mounted) context.go('/tv/home');
  }

  Widget _dlgBtn(TvMetrics m, String label,
      {bool filled = true, bool danger = false}) {
    final Color bg = danger
        ? TvDesignTokens.error
        : (filled ? TvDesignTokens.brand : TvDesignTokens.surfaceElevated);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingLg, vertical: m.spacingMd),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: m.fontSizeMd,
              color: Colors.white,
              fontWeight: FontWeight.w600)),
    );
  }

  void _invalidateAll(WidgetRef ref) {
    ref.invalidate(aniListProvider);
    ref.invalidate(aniConfigProvider);
    ref.invalidate(aniAboutProvider);
  }
}

/// TV 文本输入对话框：系统软键盘 / 遥控器 D-pad 输入。枚举字段提供候选行。
class _TextInputDialog extends StatefulWidget {
  final String title;
  final String? help;
  final List<String>? options;
  final String initial;
  final bool isNumber;
  final bool obscure;
  const _TextInputDialog({
    required this.title,
    required this.initial,
    this.help,
    this.options,
    this.isNumber = false,
    this.obscure = false,
  });

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final options = widget.options;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: m.s(720),
          constraints: BoxConstraints(maxHeight: m.s(620)),
          padding: EdgeInsets.all(m.spacingXl),
          decoration: BoxDecoration(
            color: TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.title,
                  style: TextStyle(
                      fontSize: m.fontSizeLg,
                      color: TvDesignTokens.textPrimary,
                      fontWeight: FontWeight.bold)),
              if (widget.help != null) ...[
                SizedBox(height: m.spacingXs),
                Text(widget.help!,
                    style: TextStyle(
                        fontSize: m.fontSizeXs,
                        color: TvDesignTokens.textSecondary)),
              ],
              SizedBox(height: m.spacingMd),
              if (options != null && options.isNotEmpty)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final opt in options)
                        Padding(
                          padding: EdgeInsets.only(bottom: m.spacingSm),
                          child: TvFocusable(
                            autofocus: opt == widget.initial,
                            padding: EdgeInsets.all(m.s(4)),
                            onSelect: () => Navigator.of(context).pop(opt),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                  horizontal: m.spacingLg,
                                  vertical: m.spacingMd),
                              decoration: BoxDecoration(
                                color: TvDesignTokens.surfaceElevated,
                                borderRadius:
                                    BorderRadius.circular(m.posterRadius),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                      opt == widget.initial
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked,
                                      color: opt == widget.initial
                                          ? TvDesignTokens.brand
                                          : TvDesignTokens.textSecondary,
                                      size: m.s(24)),
                                  SizedBox(width: m.spacingMd),
                                  Text(opt,
                                      style: TextStyle(
                                          fontSize: m.fontSizeMd,
                                          color:
                                              TvDesignTokens.textPrimary)),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              else ...[
                Container(
                  padding: EdgeInsets.symmetric(horizontal: m.spacingMd),
                  decoration: BoxDecoration(
                    color: TvDesignTokens.surfaceElevated,
                    borderRadius: BorderRadius.circular(m.posterRadius),
                  ),
                  child: TextField(
                    controller: _ctrl,
                    autofocus: true,
                    obscureText: widget.obscure,
                    keyboardType: widget.isNumber
                        ? TextInputType.number
                        : TextInputType.text,
                    style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: TvDesignTokens.textPrimary),
                    onSubmitted: (v) => Navigator.of(context).pop(v),
                    decoration: const InputDecoration(border: InputBorder.none),
                  ),
                ),
                SizedBox(height: m.spacingLg),
                Row(
                  children: [
                    Expanded(
                      child: TvFocusable(
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => Navigator.of(context).pop(),
                        child: _btn(m, '取消', filled: false),
                      ),
                    ),
                    SizedBox(width: m.spacingMd),
                    Expanded(
                      child: TvFocusable(
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () =>
                            Navigator.of(context).pop(_ctrl.text),
                        child: _btn(m, '确定', filled: true),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(TvMetrics m, String label, {required bool filled}) {
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: m.spacingLg, vertical: m.spacingMd),
      decoration: BoxDecoration(
        color: filled ? TvDesignTokens.brand : TvDesignTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: m.fontSizeMd,
              color: Colors.white,
              fontWeight: FontWeight.w600)),
    );
  }
}
