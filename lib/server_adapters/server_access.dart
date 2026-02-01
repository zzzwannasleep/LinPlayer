import 'package:lin_player_state/lin_player_state.dart';

import 'package:lin_player_core/state/media_server_type.dart';
import 'package:lin_player_server_adapters/lin_player_server_adapters.dart';

class ServerAccess {
  const ServerAccess({required this.adapter, required this.auth});

  final MediaServerAdapter adapter;
  final ServerAuthSession auth;
}

ServerAccess? resolveServerAccess({
  required AppState appState,
  ServerProfile? server,
}) {
  final baseUrl = server?.baseUrl ?? appState.baseUrl;
  final token = server?.token ?? appState.token;
  final userId = server?.userId ?? appState.userId;
  final apiPrefix = server?.apiPrefix ?? appState.apiPrefix;
  final serverType = server?.serverType ?? appState.serverType;

  if (baseUrl == null || token == null || userId == null) return null;
  if (!serverType.isEmbyLike) return null;

  final scheme = Uri.tryParse(baseUrl)?.scheme.trim().toLowerCase();
  final preferredScheme =
      (scheme == 'http' || scheme == 'https') ? scheme! : 'https';

  final auth = ServerAuthSession(
    token: token,
    baseUrl: baseUrl,
    userId: userId,
    apiPrefix: apiPrefix,
    preferredScheme: preferredScheme,
  );
  final adapter = ServerAdapterFactory.forLogin(
    serverType: serverType,
    deviceId: appState.deviceId,
  );
  return ServerAccess(adapter: adapter, auth: auth);
}
