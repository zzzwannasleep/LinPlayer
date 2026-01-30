import '../app_config/app_config.dart';
import '../app_config/app_product.dart';
import '../state/media_server_type.dart';
import 'emos/emos_adapter.dart';
import 'lin/lin_emby_adapter.dart';
import 'server_adapter.dart';
import 'uhd/uhd_adapter.dart';

class ServerAdapterFactory {
  static MediaServerAdapter forLogin({
    required MediaServerType serverType,
    required String deviceId,
  }) {
    switch (AppConfig.current.product) {
      case AppProduct.lin:
        return LinEmbyAdapter(serverType: serverType, deviceId: deviceId);
      case AppProduct.emos:
        return EmosServerAdapter(serverType: serverType, deviceId: deviceId);
      case AppProduct.uhd:
        return UhdServerAdapter(serverType: serverType, deviceId: deviceId);
    }
  }
}

