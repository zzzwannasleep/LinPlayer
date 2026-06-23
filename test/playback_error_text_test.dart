import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linplayer_mobile/core/utils/playback_error_text.dart';

void main() {
  group('friendlyPlaybackError', () {
    const networkMsg =
        '无法连接到服务器（连接被中断），请检查网络后重试；若仍不行，请更换线路/播放源或开启代理。';

    test('TLS 握手被中断归入网络连接类（回归用例：曾掉到兜底）', () {
      // 日志真实串：HandshakeException: Connection terminated during handshake
      expect(
        friendlyPlaybackError(
            'HandshakeException: Connection terminated during handshake'),
        networkMsg,
      );
      // 真正的 HandshakeException 对象也应命中（toString 含 handshake）。
      expect(
        friendlyPlaybackError(
            const HandshakeException('Connection terminated during handshake')),
        networkMsg,
      );
    });

    test('既有网络分支不回归', () {
      expect(friendlyPlaybackError('Connection reset by peer'), networkMsg);
      expect(friendlyPlaybackError('SocketException: Failed host lookup'),
          networkMsg);
      expect(friendlyPlaybackError('Connection timed out'), networkMsg);
    });

    test('鉴权 / 资源 / 服务端分支不被网络分支抢走', () {
      expect(
        friendlyPlaybackError('HTTP request failed, statusCode: 403'),
        '登录状态已失效或无访问权限，请重新登录服务器后重试。',
      );
      expect(
        friendlyPlaybackError('statusCode: 404 not found'),
        '该视频资源不存在或已被移除。',
      );
      expect(
        friendlyPlaybackError('502 bad gateway'),
        '服务器繁忙或内部错误，请稍后重试。',
      );
    });

    test('空 / 未知错误走兜底，且绝不回显原文', () {
      expect(friendlyPlaybackError(null), '播放遇到问题，无法继续播放。');
      expect(friendlyPlaybackError(''), '播放遇到问题，无法继续播放。');
      final secret = friendlyPlaybackError(
          'https://emby.example.com/Videos/1/stream?api_key=SECRET');
      expect(secret.contains('SECRET'), isFalse);
      expect(secret.contains('api_key'), isFalse);
    });
  });
}
