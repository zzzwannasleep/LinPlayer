import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/quark_qr_login.dart';

/// 夸克扫码登录视图（三端共用）。自管 [QuarkQrLogin] 状态机，成功时回调
/// [onSuccess] 把构造好的 [ServerConfig] 交给上层落库 + 跳转。
class QuarkQrLoginView extends StatefulWidget {
  /// 取当前备注名（扫码成功时用）。
  final ValueGetter<String> currentName;
  final ValueChanged<ServerConfig> onSuccess;

  const QuarkQrLoginView({
    super.key,
    required this.currentName,
    required this.onSuccess,
  });

  @override
  State<QuarkQrLoginView> createState() => _QuarkQrLoginViewState();
}

class _QuarkQrLoginViewState extends State<QuarkQrLoginView> {
  QuarkQrLogin? _login;
  bool _delivered = false;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  void _restart() {
    _login?.removeListener(_onChanged);
    _login?.dispose();
    final login = QuarkQrLogin(name: widget.currentName());
    login.addListener(_onChanged);
    _login = login;
    login.start();
  }

  void _onChanged() {
    if (!mounted) return;
    final login = _login;
    if (login != null &&
        login.state == QuarkQrState.success &&
        login.server != null &&
        !_delivered) {
      _delivered = true;
      final server = login.server!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSuccess(server);
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _login?.removeListener(_onChanged);
    _login?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final login = _login;
    if (login == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 220,
          height: 220,
          child: Center(child: _buildQrArea(login)),
        ),
        const SizedBox(height: 16),
        Text(
          _statusText(login.state),
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
        ),
        if (login.state == QuarkQrState.error && login.errorMessage != null) ...[
          const SizedBox(height: 6),
          Text(login.errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        if (login.state == QuarkQrState.expired ||
            login.state == QuarkQrState.error) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {
              _delivered = false;
              _restart();
            },
            child: const Text('重新获取二维码'),
          ),
        ],
      ],
    );
  }

  Widget _buildQrArea(QuarkQrLogin login) {
    switch (login.state) {
      case QuarkQrState.waiting:
        return Container(
          padding: const EdgeInsets.all(8),
          color: Colors.white,
          child: QrImageView(
            data: login.qrData ?? '',
            version: QrVersions.auto,
            size: 200,
            backgroundColor: Colors.white,
          ),
        );
      case QuarkQrState.success:
        return const Icon(Icons.check_circle, color: Colors.green, size: 64);
      case QuarkQrState.expired:
        return const Icon(Icons.timer_off, color: Colors.grey, size: 64);
      case QuarkQrState.error:
        return const Icon(Icons.error_outline, color: Colors.grey, size: 64);
      case QuarkQrState.loading:
        return const CircularProgressIndicator();
    }
  }

  String _statusText(QuarkQrState state) {
    switch (state) {
      case QuarkQrState.loading:
        return '正在获取二维码…';
      case QuarkQrState.waiting:
        return '请用手机夸克 App 扫码并确认登录';
      case QuarkQrState.success:
        return '登录成功，正在进入…';
      case QuarkQrState.expired:
        return '二维码已过期';
      case QuarkQrState.error:
        return '登录失败';
    }
  }
}
