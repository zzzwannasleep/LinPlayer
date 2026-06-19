import 'dart:convert';

import '../../app_identity.dart';

/// 追番/观看记录同步服务的统一 User-Agent。
/// 与 App 其它出口保持一致（见 [kAppUserAgent]）。
const String kSyncUserAgent = kAppUserAgent;

/// 支持的同步服务类型。
enum SyncService {
  trakt,
  bangumi;

  String get id => name;

  String get displayName {
    switch (this) {
      case SyncService.trakt:
        return 'Trakt';
      case SyncService.bangumi:
        return 'Bangumi';
    }
  }
}

/// 已连接账号的令牌与身份信息。
///
/// 持久化时整体 JSON 经过混淆（见 [SyncSecureStore]），不以明文落盘。
class SyncAccount {
  final SyncService service;
  final String accessToken;
  final String? refreshToken;

  /// 访问令牌过期时刻（绝对时间）。null 表示未知/不过期。
  final DateTime? expiresAt;

  /// 展示用用户名（可空）。
  final String? username;

  /// 服务侧用户 ID（可空）。
  final String? userId;

  const SyncAccount({
    required this.service,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.username,
    this.userId,
  });

  /// 是否已过期（带 60s 安全余量）。
  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now()
        .isAfter(exp.subtract(const Duration(seconds: 60)));
  }

  SyncAccount copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? username,
    String? userId,
  }) {
    return SyncAccount(
      service: service,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      username: username ?? this.username,
      userId: userId ?? this.userId,
    );
  }

  Map<String, dynamic> toJson() => {
        'service': service.id,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt?.millisecondsSinceEpoch,
        'username': username,
        'userId': userId,
      };

  static SyncAccount? fromJson(Map<String, dynamic> json) {
    final serviceId = json['service']?.toString();
    final access = json['accessToken']?.toString();
    if (serviceId == null || access == null || access.isEmpty) {
      return null;
    }
    final service = SyncService.values
        .where((s) => s.id == serviceId)
        .cast<SyncService?>()
        .firstWhere((s) => s != null, orElse: () => null);
    if (service == null) return null;

    final expRaw = json['expiresAt'];
    final exp = expRaw is int
        ? DateTime.fromMillisecondsSinceEpoch(expRaw)
        : (expRaw is String ? DateTime.tryParse(expRaw) : null);

    return SyncAccount(
      service: service,
      accessToken: access,
      refreshToken: json['refreshToken']?.toString(),
      expiresAt: exp,
      username: json['username']?.toString(),
      userId: json['userId']?.toString(),
    );
  }

  String encode() => jsonEncode(toJson());

  static SyncAccount? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }
}
