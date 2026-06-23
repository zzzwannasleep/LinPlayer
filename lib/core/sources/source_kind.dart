/// 源类型。
///
/// [emby] 是现有 Emby/Jellyfin 后端的标记（向后兼容：旧数据缺字段时默认它）。
/// 其余为新接入的「文件浏览 → 取流播放」型源：网盘 / 聚合 / 追番。
///
/// 单独成文件，避免 [ServerConfig]（server_providers.dart）与
/// media_source_backend.dart 之间的循环 import。
enum SourceKind { emby, openlist, quark, anirss }

SourceKind sourceKindFromName(String? name) {
  switch (name) {
    case 'openlist':
      return SourceKind.openlist;
    case 'quark':
      return SourceKind.quark;
    case 'anirss':
      return SourceKind.anirss;
    case 'emby':
    default:
      return SourceKind.emby;
  }
}

/// 该源是否为「文件浏览型」（非 Emby）。决定选中服务器后落到浏览页还是原首页。
bool isFileBrowseSource(SourceKind kind) => kind != SourceKind.emby;
