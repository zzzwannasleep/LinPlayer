import 'package:lin_player_server_api/network/lin_http_client.dart';
import 'package:lin_player_server_api/services/emby_api.dart';

class ServerApiBootstrap {
  const ServerApiBootstrap._();

  static void configure({
    required String userAgentProduct,
    required String appVersion,
    required String defaultClientName,
    bool allowBadCertificates = true,
  }) {
    LinHttpClientFactory.configure(
      LinHttpClientFactory.config.copyWith(
        allowBadCertificates: allowBadCertificates,
      ),
    );
    EmbyApi.setUserAgentProduct(userAgentProduct);
    EmbyApi.setDefaultClientName(defaultClientName);
    EmbyApi.setAppVersion(appVersion);
  }
}
