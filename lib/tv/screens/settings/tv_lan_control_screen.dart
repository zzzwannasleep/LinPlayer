import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/lan_remote.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';

/// 局域网扫码遥控页：启动内置 HTTP 服务，展示二维码与访问地址。
/// 手机连同一 Wi-Fi 扫码即可在浏览器里编辑设置 / 服务器并遥控播放。
class TvLanControlScreen extends ConsumerStatefulWidget {
  const TvLanControlScreen({super.key});

  @override
  ConsumerState<TvLanControlScreen> createState() => _TvLanControlScreenState();
}

class _TvLanControlScreenState extends ConsumerState<TvLanControlScreen> {
  String? _url;
  String? _error;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      final url = await ref.read(lanRemoteServerProvider).start();
      if (!mounted) return;
      setState(() {
        _starting = false;
        if (url == null) {
          _error = '无法获取局域网地址，请确认已连接 Wi-Fi';
        } else {
          _url = url;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(m.spacingXl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TvFocusable(
                    autofocus: true,
                    padding: EdgeInsets.all(m.spacingXs),
                    onSelect: () =>
                        context.canPop() ? context.pop() : context.go('/tv/home'),
                    child: Icon(Icons.arrow_back,
                        color: TvDesignTokens.textPrimary, size: m.s(32)),
                  ),
                  SizedBox(width: m.spacingMd),
                  Text(
                    '手机扫码遥控',
                    style: TextStyle(
                      fontSize: m.fontSizeXxl,
                      color: TvDesignTokens.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              SizedBox(height: m.spacingXl),
              Expanded(child: _buildBody(m)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(TvMetrics m) {
    if (_starting) {
      return const Center(
        child: CircularProgressIndicator(color: TvDesignTokens.brand),
      );
    }
    if (_error != null || _url == null) {
      return Center(
        child: Text(
          _error ?? '启动失败',
          style: TextStyle(
              fontSize: m.fontSizeMd, color: TvDesignTokens.textSecondary),
        ),
      );
    }
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(m.spacingLg),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(m.posterRadius),
          ),
          child: QrImageView(
            data: _url!,
            size: m.s(280),
            backgroundColor: Colors.white,
          ),
        ),
        SizedBox(width: m.spacingXxl),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '用手机扫描左侧二维码',
                style: TextStyle(
                  fontSize: m.fontSizeXl,
                  color: TvDesignTokens.textPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: m.spacingMd),
              _step(m, '1', '确保手机与本设备连接同一 Wi-Fi / 局域网'),
              _step(m, '2', '扫码后在浏览器打开，即可编辑设置、服务器并遥控播放'),
              _step(m, '3', '播放页支持：暂停 / 快进退 / 上下集 / 选集 / 音轨 / 字幕'),
              SizedBox(height: m.spacingLg),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: m.spacingLg, vertical: m.spacingMd),
                decoration: BoxDecoration(
                  color: TvDesignTokens.surface,
                  borderRadius: BorderRadius.circular(m.posterRadius),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link,
                        color: TvDesignTokens.brand, size: m.s(24)),
                    SizedBox(width: m.spacingSm),
                    SelectableText(
                      _url!,
                      style: TextStyle(
                        fontSize: m.fontSizeLg,
                        color: TvDesignTokens.brand,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _step(TvMetrics m, String n, String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: m.spacingMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: m.s(28),
            height: m.s(28),
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: TvDesignTokens.brand,
              shape: BoxShape.circle,
            ),
            child: Text(n,
                style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
          SizedBox(width: m.spacingMd),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: m.fontSizeMd,
                color: TvDesignTokens.textSecondary,
                height: TvDesignTokens.lineHeightNormal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
