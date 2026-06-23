import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';

import '../providers/server_providers.dart';
import 'media_source_backend.dart';
import 'quark_tv.dart';
import 'source_credentials.dart';

enum QuarkQrState { loading, waiting, success, error, expired }

/// 夸克扫码（设备码）登录状态机：取二维码 → 轮询用户扫码确认 → 换 token →
/// 保存 refresh_token/device_id 并产出 [ServerConfig]。UI [addListener] 后渲染。
class QuarkQrLogin extends ChangeNotifier {
  static const _uuid = Uuid();
  static const _pollInterval = Duration(seconds: 2);
  static const _timeout = Duration(minutes: 3);

  final QuarkTvClient _tv = QuarkTvClient();
  final String name;

  QuarkQrLogin({this.name = ''});

  QuarkQrState state = QuarkQrState.loading;
  String? qrData;
  String? errorMessage;
  ServerConfig? server;

  String _deviceId = '';
  String _queryToken = '';
  bool _disposed = false;

  void _set(QuarkQrState s) {
    if (_disposed) return;
    state = s;
    notifyListeners();
  }

  /// 开始扫码流程（可重试调用）。
  Future<void> start() async {
    _set(QuarkQrState.loading);
    errorMessage = null;
    _deviceId = md5
        .convert(utf8.encode(DateTime.now().microsecondsSinceEpoch.toString()))
        .toString();
    try {
      final r = await _tv.getLoginCode(_deviceId);
      if (_disposed) return;
      if (r.qrData.isEmpty) {
        throw SourceException('未获取到二维码');
      }
      qrData = r.qrData;
      _queryToken = r.queryToken;
      _set(QuarkQrState.waiting);
      unawaited(_poll());
    } on SourceException catch (e) {
      errorMessage = e.message;
      _set(QuarkQrState.error);
    } catch (e) {
      errorMessage = '获取二维码失败: $e';
      _set(QuarkQrState.error);
    }
  }

  Future<void> _poll() async {
    final deadline = DateTime.now().add(_timeout);
    while (!_disposed &&
        state == QuarkQrState.waiting &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollInterval);
      if (_disposed || state != QuarkQrState.waiting) return;
      try {
        final code = await _tv.getCode(_deviceId, _queryToken);
        if (code.isNotEmpty) {
          await _finish(code);
          return;
        }
      } catch (_) {
        // 用户尚未扫码确认：接口报错属正常，继续轮询。
      }
    }
    if (!_disposed && state == QuarkQrState.waiting) {
      _set(QuarkQrState.expired);
    }
  }

  Future<void> _finish(String code) async {
    try {
      final tok = await _tv.exchangeToken(_deviceId, code, isRefresh: false);
      if (_disposed) return;
      final id = _uuid.v4();
      await SourceCredentialStore.instance.write(id, {
        'refresh_token': tok.refreshToken,
        'device_id': _deviceId,
      });
      server = ServerConfig(
        id: id,
        name: name.trim().isEmpty ? '夸克网盘' : name.trim(),
        baseUrl: QuarkTvClient.api,
        sourceKind: SourceKind.quark,
      );
      _set(QuarkQrState.success);
    } on SourceException catch (e) {
      errorMessage = e.message;
      _set(QuarkQrState.error);
    } catch (e) {
      errorMessage = '登录失败: $e';
      _set(QuarkQrState.error);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
