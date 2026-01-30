import '../../../services/emby_api.dart';
import '../../../state/media_server_type.dart';

Map<String, String> buildEmbyHeaders({
  required MediaServerType serverType,
  required String deviceId,
  required String? userId,
  required String token,
}) {
  return {
    'X-Emby-Token': token,
    ...EmbyApi.buildAuthorizationHeaders(
      serverType: serverType,
      deviceId: deviceId,
      userId: userId,
    ),
  };
}
