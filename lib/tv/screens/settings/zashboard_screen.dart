import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/mihomo_service.dart';
import '../../theme/tv_design_tokens.dart';

/// 内置 zashboard 面板（指向本地 mihomo external-ui）。
///
/// 面板与 external-controller 同源（127.0.0.1:9090），secret 为空，
/// 因此无需额外填写后端地址即可选择节点、查看连接。
class ZashboardScreen extends StatefulWidget {
  const ZashboardScreen({super.key});

  @override
  State<ZashboardScreen> createState() => _ZashboardScreenState();
}

class _ZashboardScreenState extends State<ZashboardScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(TvDesignTokens.background)
      ..loadRequest(Uri.parse(MihomoPorts.dashboardUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      appBar: AppBar(
        backgroundColor: TvDesignTokens.surface,
        title: const Text('zashboard 面板'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
