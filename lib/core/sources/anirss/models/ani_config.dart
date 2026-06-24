/// Ani-rss 服务端设置（`/api/config` ↔ `/api/setConfig`）。
///
/// Config 有 ~123 字段且随版本增删，**内部存原始 `Map`**：UI 由 `anirss_config_spec`
/// 的字段表驱动读写，未 spec 的 key 原样保留，`setConfig` 回传原 map 永不丢字段。
class ConfigModel {
  final Map<String, dynamic> raw;
  const ConfigModel(this.raw);

  static ConfigModel fromJson(Object? json) {
    if (json is Map) return ConfigModel(json.cast<String, dynamic>());
    return const ConfigModel(<String, dynamic>{});
  }

  Map<String, dynamic> toJson() => raw;

  ConfigModel copy() => ConfigModel(Map<String, dynamic>.from(raw));

  dynamic operator [](String key) => raw[key];

  String? get version => raw['version']?.toString();
}
