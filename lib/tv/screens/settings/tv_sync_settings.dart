import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/playback_providers.dart';
import '../../../core/providers/sync_providers.dart';
import '../../../core/providers/watch_history_providers.dart';
import '../../../core/services/sync/sync_models.dart';
import '../../../core/services/watch_history/watch_history_writeback_service.dart';
import '../../../core/services/sync/trakt_sync_service.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_panel.dart';
import '../../widgets/tv_toast.dart';

/// TV 端「同步服务」设置内容（右侧面板）。
class TvSyncSettings extends ConsumerWidget {
  const TvSyncSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = context.tv;
    final state = ref.watch(syncControllerProvider);
    final crossServerResume = ref.watch(crossServerResumeProvider);
    final writebackEnabled = ref.watch(crossServerWritebackEnabledProvider);
    final writebackRange = ref.watch(crossServerWritebackRangeProvider);
    final writebackProgress = ref.watch(crossServerWritebackProgressProvider);
    return ListView(
      padding: EdgeInsets.all(m.spacingXl),
      children: [
        Text(
          '同步记录',
          style: TextStyle(
            fontSize: m.fontSizeXxl,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: m.spacingLg),
        _toggle(
          context,
          m,
          title: '跨服务器续播',
          subtitle: '换服务器观看同一内容时自动续播到最新进度',
          value: crossServerResume,
          onToggle: () => ref
              .read(crossServerResumeProvider.notifier)
              .state = !crossServerResume,
        ),
        _toggle(
          context,
          m,
          title: '看完后回传到其它服务器',
          subtitle: '把已看完 / 进度同步到其它服务器(会写入其它服)',
          value: writebackEnabled,
          onToggle: () => ref
              .read(crossServerWritebackEnabledProvider.notifier)
              .state = !writebackEnabled,
        ),
        if (writebackEnabled) ...[
          _action(
            context,
            m,
            title: '回传目标',
            value: crossServerWritebackRangeLabel(writebackRange),
            onSelect: () => _pickWritebackRange(context, ref),
          ),
          _toggle(
            context,
            m,
            title: '同步播放进度',
            subtitle: '不仅回传「已看完」,也回传当前播放进度',
            value: writebackProgress,
            onToggle: () => ref
                .read(crossServerWritebackProgressProvider.notifier)
                .state = !writebackProgress,
          ),
        ],
        SizedBox(height: m.spacingXl),
        Text(
          '同步服务',
          style: TextStyle(
            fontSize: m.fontSizeXxl,
            color: TvDesignTokens.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: m.spacingLg),
        _item(
          context,
          ref,
          m,
          service: SyncService.trakt,
          account: state.trakt,
          hint: '电影与剧集追踪（trakt.tv）',
        ),
        _item(
          context,
          ref,
          m,
          service: SyncService.bangumi,
          account: state.bangumi,
          hint: '动画/番剧追踪（bgm.tv）',
        ),
      ],
    );
  }

  Widget _item(
    BuildContext context,
    WidgetRef ref,
    TvMetrics m, {
    required SyncService service,
    required SyncAccount? account,
    required String hint,
  }) {
    final connected = account != null;
    final subtitle = connected
        ? '已连接${account.username != null ? '：${account.username}' : ''}'
        : hint;
    return TvFocusable(
      onSelect: () {
        if (connected) {
          _confirmDisconnect(context, ref, service);
        } else {
          _connect(context, ref, service);
        }
      },
      child: Container(
        padding: EdgeInsets.all(m.spacingLg),
        margin: EdgeInsets.only(bottom: m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    service.displayName,
                    style: TextStyle(
                      fontSize: m.fontSizeMd,
                      color: TvDesignTokens.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: TvDesignTokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              connected ? '断开' : '连接',
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.brand,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggle(
    BuildContext context,
    TvMetrics m, {
    required String title,
    required String subtitle,
    required bool value,
    required VoidCallback onToggle,
  }) {
    return TvFocusable(
      onSelect: onToggle,
      child: Container(
        padding: EdgeInsets.all(m.spacingLg),
        margin: EdgeInsets.only(bottom: m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: m.fontSizeMd,
                      color: TvDesignTokens.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: TvDesignTokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              value ? '开' : '关',
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: value
                    ? TvDesignTokens.brand
                    : TvDesignTokens.textSecondary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    TvMetrics m, {
    required String title,
    required String value,
    required VoidCallback onSelect,
  }) {
    return TvFocusable(
      onSelect: onSelect,
      child: Container(
        padding: EdgeInsets.all(m.spacingLg),
        margin: EdgeInsets.only(bottom: m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.surface,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: m.fontSizeMd,
                  color: TvDesignTokens.textPrimary,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.brand,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pickWritebackRange(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => TvPanel(
        title: '回传目标',
        onClose: () => Navigator.pop(ctx),
        children: [
          for (final range in CrossServerWritebackRange.values)
            TvPanelOption(
              title: crossServerWritebackRangeLabel(range),
              onTap: () {
                ref.read(crossServerWritebackRangeProvider.notifier).state =
                    range;
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _confirmDisconnect(
      BuildContext context, WidgetRef ref, SyncService service) {
    showDialog(
      context: context,
      builder: (ctx) => TvPanel(
        title: '断开 ${service.displayName}',
        onClose: () => Navigator.pop(ctx),
        children: [
          Padding(
            padding: EdgeInsets.symmetric(vertical: ctx.tv.spacingMd),
            child: const Text('确定要断开连接吗？已保存的登录令牌会被清除。',
                style: TextStyle(color: TvDesignTokens.textSecondary)),
          ),
          TvPanelOption(
            title: '确认断开',
            onTap: () async {
              await ref
                  .read(syncControllerProvider.notifier)
                  .disconnect(service);
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
          TvPanelOption(title: '取消', onTap: () => Navigator.pop(ctx)),
        ],
      ),
    );
  }

  void _connect(BuildContext context, WidgetRef ref, SyncService service) {
    showDialog(
      context: context,
      builder: (ctx) => service == SyncService.trakt
          ? const _TvTraktDialog()
          : const _TvBangumiDialog(),
    );
  }
}

class _TvTraktDialog extends ConsumerStatefulWidget {
  const _TvTraktDialog();
  @override
  ConsumerState<_TvTraktDialog> createState() => _TvTraktDialogState();
}

class _TvTraktDialogState extends ConsumerState<_TvTraktDialog> {
  TraktDeviceCode? _code;
  String? _error;
  Timer? _timer;
  int _remaining = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final code = await ref
          .read(syncControllerProvider.notifier)
          .startTraktDeviceAuth();
      if (!mounted) return;
      setState(() {
        _code = code;
        _remaining = code.expiresIn;
      });
      var interval = code.interval;
      var tick = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) return;
        setState(() => _remaining = (_remaining - 1).clamp(0, code.expiresIn));
        if (_remaining <= 0) {
          timer.cancel();
          setState(() => _error = '授权码已过期，请重试');
          return;
        }
        if (++tick < interval) return;
        tick = 0;
        final result = await ref
            .read(syncControllerProvider.notifier)
            .pollTrakt(code.deviceCode);
        if (!mounted) return;
        if (result.state == TraktPollState.authorized) {
          timer.cancel();
          Navigator.of(context).pop();
          TvToast.show(context, 'Trakt 已连接');
        } else if (result.state == TraktPollState.slowDown) {
          interval += 1;
        } else if (result.state == TraktPollState.expired) {
          timer.cancel();
          setState(() => _error = '授权码已过期，请重试');
        } else if (result.state == TraktPollState.denied) {
          timer.cancel();
          setState(() => _error = '授权被拒绝');
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '获取授权码失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final code = _code;
    return TvPanel(
      title: '连接 Trakt',
      onClose: () => Navigator.pop(context),
      children: [
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent))
        else if (code == null)
          const Text('正在获取授权码…',
              style: TextStyle(color: TvDesignTokens.textSecondary))
        else ...[
          const Text('在手机或电脑浏览器打开下面网址，输入验证码完成授权：',
              style: TextStyle(color: TvDesignTokens.textSecondary)),
          SizedBox(height: m.spacingLg),
          _TvInfoBox(label: '网址', value: code.verificationUrl),
          SizedBox(height: m.spacingMd),
          _TvInfoBox(label: '验证码', value: code.userCode, big: true),
          SizedBox(height: m.spacingLg),
          Text('等待授权…（${_remaining}s）',
              style: const TextStyle(color: TvDesignTokens.textSecondary)),
        ],
      ],
    );
  }
}

class _TvBangumiDialog extends ConsumerStatefulWidget {
  const _TvBangumiDialog();
  @override
  ConsumerState<_TvBangumiDialog> createState() => _TvBangumiDialogState();
}

class _TvBangumiDialogState extends ConsumerState<_TvBangumiDialog> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请先输入授权码');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(syncControllerProvider.notifier)
          .connectBangumiWithCode(code);
      if (mounted) {
        Navigator.of(context).pop();
        TvToast.show(context, 'Bangumi 已连接');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '连接失败：$e';
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final url = ref.read(syncControllerProvider.notifier).buildBangumiAuthorizeUrl();
    return TvPanel(
      title: '连接 Bangumi',
      onClose: () => Navigator.pop(context),
      children: [
        const Text('在手机或电脑浏览器打开下面网址授权，授权后页面会显示授权码：',
            style: TextStyle(color: TvDesignTokens.textSecondary)),
        SizedBox(height: m.spacingMd),
        _TvInfoBox(label: '授权网址', value: url),
        SizedBox(height: m.spacingLg),
        const Text('输入授权码：',
            style: TextStyle(color: TvDesignTokens.textSecondary)),
        SizedBox(height: m.spacingSm),
        TextField(
          controller: _controller,
          style: const TextStyle(color: TvDesignTokens.textPrimary),
          decoration: const InputDecoration(
            hintText: '授权码 (code)',
            filled: true,
            fillColor: TvDesignTokens.background,
            border: OutlineInputBorder(),
          ),
        ),
        SizedBox(height: m.spacingLg),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          SizedBox(height: m.spacingMd),
        ],
        TvPanelOption(
          title: _submitting ? '连接中…' : '完成连接',
          onTap: _submitting ? null : _submit,
        ),
      ],
    );
  }
}

/// TV 端只读信息框（可聚焦后按确认键复制）。
class _TvInfoBox extends StatelessWidget {
  final String label;
  final String value;
  final bool big;

  const _TvInfoBox({required this.label, required this.value, this.big = false});

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return TvFocusable(
      onSelect: () {
        Clipboard.setData(ClipboardData(text: value));
        TvToast.show(context, '已复制$label');
      },
      child: Container(
        padding: EdgeInsets.all(m.spacingMd),
        decoration: BoxDecoration(
          color: TvDesignTokens.background,
          borderRadius: BorderRadius.circular(m.posterRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textSecondary)),
            SizedBox(height: m.s(4)),
            Text(
              value,
              style: TextStyle(
                fontSize: big ? m.fontSizeXxl : m.fontSizeMd,
                color: TvDesignTokens.textPrimary,
                fontWeight: big ? FontWeight.bold : FontWeight.normal,
                letterSpacing: big ? 3 : 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
