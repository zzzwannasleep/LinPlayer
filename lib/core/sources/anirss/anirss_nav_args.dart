import '../../providers/server_providers.dart';
import 'models/ani.dart';

/// 详情页导航参数（经 go_router 的 `extra` 传，Ani 对象大不走 path）。
class AniRssDetailArgs {
  final ServerConfig server;
  final AniModel ani;
  const AniRssDetailArgs({required this.server, required this.ani});
}
