import 'package:flutter/foundation.dart';

@immutable
class EmosSession {
  const EmosSession({
    required this.token,
    required this.userId,
    required this.username,
    this.avatarUrl,
  });

  final String token;
  final String userId;
  final String username;
  final String? avatarUrl;
}

