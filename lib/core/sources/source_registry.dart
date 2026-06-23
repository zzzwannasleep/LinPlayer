import 'package:flutter/material.dart';

import 'anirss_backend.dart';
import 'media_source_backend.dart';
import 'openlist_backend.dart';
import 'quark_backend.dart';

/// 一种源支持的登录方式。
enum SourceLoginMethod { password, qrcode, cookie }

/// 源类型在「添加服务器」选择器里的展示描述。新增源时在 [kSourceTypes] 追加一项，
/// 选择器（带搜索）与登录页路由都由它驱动。
class SourceTypeDescriptor {
  final SourceKind kind;
  final String name;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final List<SourceLoginMethod> loginMethods;

  /// 搜索关键词（中英/拼音别名），供选择器搜索框过滤。
  final List<String> keywords;

  const SourceTypeDescriptor({
    required this.kind,
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.loginMethods,
    this.keywords = const [],
  });

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (name.toLowerCase().contains(q)) return true;
    if (subtitle.toLowerCase().contains(q)) return true;
    return keywords.any((k) => k.toLowerCase().contains(q));
  }
}

/// 已支持的源类型表。选择器从此渲染；后续接入新源只需在此追加 + 实现 backend/登录页。
const List<SourceTypeDescriptor> kSourceTypes = [
  SourceTypeDescriptor(
    kind: SourceKind.emby,
    name: 'Emby / Jellyfin',
    subtitle: '媒体服务器，账号密码登录',
    icon: Icons.dns_rounded,
    accent: Color(0xFF52B54B),
    loginMethods: [SourceLoginMethod.password],
    keywords: ['emby', 'jellyfin', 'media server', '媒体服务器'],
  ),
  SourceTypeDescriptor(
    kind: SourceKind.openlist,
    name: 'OpenList',
    subtitle: '文件列表网关（AList 后继），账密登录在线播放',
    icon: Icons.folder_shared_rounded,
    accent: Color(0xFF2F6FED),
    loginMethods: [SourceLoginMethod.password],
    keywords: ['openlist', 'alist', 'oplist', '列表', '网盘聚合'],
  ),
  SourceTypeDescriptor(
    kind: SourceKind.quark,
    name: '夸克网盘',
    subtitle: '扫码或粘贴 Cookie 登录，在线播放网盘视频',
    icon: Icons.cloud_rounded,
    accent: Color(0xFF3A6CF6),
    loginMethods: [SourceLoginMethod.qrcode, SourceLoginMethod.cookie],
    keywords: ['quark', '夸克', 'kuake', '网盘', 'pan'],
  ),
  SourceTypeDescriptor(
    kind: SourceKind.anirss,
    name: 'Ani-rss',
    subtitle: '自动追番，账密登录浏览并在线播放剧集',
    icon: Icons.rss_feed_rounded,
    accent: Color(0xFFE9543B),
    loginMethods: [SourceLoginMethod.password],
    keywords: ['anirss', 'ani-rss', '追番', '番剧', 'rss'],
  ),
];

SourceTypeDescriptor? sourceTypeOf(SourceKind kind) {
  for (final d in kSourceTypes) {
    if (d.kind == kind) return d;
  }
  return null;
}

/// 按源类型取后端实例（有状态：内含 token 缓存，故按 kind 复用单例）。
final Map<SourceKind, MediaSourceBackend> _backends = {};

MediaSourceBackend mediaSourceBackendFor(SourceKind kind) {
  return _backends.putIfAbsent(kind, () {
    switch (kind) {
      case SourceKind.openlist:
        return OpenListBackend();
      case SourceKind.anirss:
        return AniRssBackend();
      case SourceKind.quark:
        return QuarkBackend();
      case SourceKind.emby:
        throw UnimplementedError('源 $kind 尚未接入文件浏览后端');
    }
  });
}
