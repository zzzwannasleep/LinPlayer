import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/intro_skip_service.dart';

/// introdb 查询服务（单例，内置内存缓存）。
final introSkipServiceProvider = Provider<IntroSkipService>((ref) {
  return IntroSkipService();
});
