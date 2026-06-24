/// 设置页字段类型。
enum CfgType { bool_, int_, string_, enumStr, stringList, password }

/// 一个配置字段（key 对应 ani-rss Config 的字段名）。
class CfgField {
  final String key;
  final String label;
  final CfgType type;
  final String? help;

  /// enumStr 的可选值。
  final List<String>? options;

  const CfgField(
    this.key,
    this.label,
    this.type, {
    this.help,
    this.options,
  });
}

/// 一个配置分区。
class CfgSection {
  final String title;
  final List<CfgField> fields;
  const CfgSection(this.title, this.fields);
}

/// 高价值字段表（驱动设置表单）。未列出的 key 由「高级(原始)」区兜底，
/// 保存时随原始 Map 一并回传，永不丢字段。后续可增量补充。
const List<CfgSection> kAniRssConfigSpec = [
  CfgSection('RSS / 下载', [
    CfgField('rss', 'RSS 开关', CfgType.bool_, help: '关闭后不自动抓取新剧集'),
    CfgField('rssSleepMinutes', 'RSS 间隔（分钟）', CfgType.int_),
    CfgField('rssTimeout', 'RSS 超时（秒）', CfgType.int_),
    CfgField('downloadNew', '只下载最新集', CfgType.bool_),
    CfgField('downloadCount', '同时下载数量限制', CfgType.int_),
    CfgField('downloadRetry', '下载重试次数', CfgType.int_),
    CfgField('delete', '自动删除已完成任务', CfgType.bool_),
    CfgField('fileExist', '已下载自动跳过', CfgType.bool_),
  ]),
  CfgSection('下载工具', [
    CfgField('downloadToolType', '下载工具类型', CfgType.string_,
        help: 'qBittorrent / Transmission / Aria2 等'),
    CfgField('downloadToolHost', '下载工具地址', CfgType.string_),
    CfgField('downloadToolUsername', '用户名', CfgType.string_),
    CfgField('downloadToolPassword', '密码', CfgType.password),
    CfgField('qbUseDownloadPath', '使用 qB 自身保存路径', CfgType.bool_),
    CfgField('downloadPathTemplate', '下载路径模版', CfgType.string_),
    CfgField('ovaDownloadPathTemplate', '剧场版路径模版', CfgType.string_),
  ]),
  CfgSection('重命名', [
    CfgField('rename', '自动重命名', CfgType.bool_),
    CfgField('renameTemplate', '重命名模版', CfgType.string_),
    CfgField('renameDelYear', '剔除年份', CfgType.bool_),
    CfgField('renameDelTmdbId', '剔除 TMDB ID', CfgType.bool_),
    CfgField('maxFileNameLength', '最大文件名长度', CfgType.int_),
    CfgField('titleYear', '标题带年份', CfgType.bool_),
  ]),
  CfgSection('刮削 / TMDB', [
    CfgField('scrape', '刮削开关', CfgType.bool_),
    CfgField('tmdb', '启用 TMDB', CfgType.bool_),
    CfgField('tmdbApi', 'TMDB API', CfgType.string_),
    CfgField('tmdbApiKey', 'TMDB API Key', CfgType.password),
    CfgField('tmdbImage', 'TMDB 图片地址', CfgType.string_),
    CfgField('tmdbLanguage', 'TMDB 语言', CfgType.string_, help: '如 zh-CN'),
    CfgField('tmdbAnime', '仅获取动漫', CfgType.bool_),
    CfgField('tmdbId', '标题带 TMDB ID', CfgType.bool_),
  ]),
  CfgSection('Bangumi', [
    CfgField('bgmTokenType', 'BGM Token 类型', CfgType.enumStr,
        options: ['INPUT', 'AUTO']),
    CfgField('bgmToken', 'BGM Token', CfgType.password),
    CfgField('bgmJpName', 'BGM 日语标题', CfgType.bool_),
    CfgField('bgmImage', 'BGM 封面质量', CfgType.string_),
  ]),
  CfgSection('代理', [
    CfgField('proxy', '启用代理', CfgType.bool_),
    CfgField('proxyHost', '代理 Host', CfgType.string_),
    CfgField('proxyPort', '代理端口', CfgType.int_),
    CfgField('proxyUsername', '代理用户名', CfgType.string_),
    CfgField('proxyPassword', '代理密码', CfgType.password),
  ]),
  CfgSection('完成 / 做种', [
    CfgField('completed', '番剧完结迁移', CfgType.bool_),
    CfgField('completedPathTemplate', '完结迁移位置', CfgType.string_),
    CfgField('awaitStalledUP', '等待做种完毕', CfgType.bool_),
    CfgField('ratioLimit', '分享率', CfgType.int_),
    CfgField('seedingTimeLimit', '做种时长', CfgType.int_),
  ]),
  CfgSection('安全 / 访问', [
    CfgField('apiKey', 'API Key', CfgType.password),
    CfgField('ipWhitelist', '开启 IP 白名单', CfgType.bool_),
    CfgField('ipWhitelistStr', 'IP 白名单', CfgType.string_),
    CfgField('innerIP', '仅内网访问', CfgType.bool_),
    CfgField('multiLoginForbidden', '禁止多端登录', CfgType.bool_),
    CfgField('loginEffectiveHours', '登录有效时间（小时）', CfgType.int_),
    CfgField('allowCors', '允许跨域', CfgType.bool_),
  ]),
  CfgSection('杂项', [
    CfgField('debug', 'DEBUG 日志', CfgType.bool_),
    CfgField('logsMax', '最大日志条数', CfgType.int_),
    CfgField('autoUpdate', '自动更新', CfgType.bool_),
    CfgField('coexist', '多字幕组共存', CfgType.bool_),
    CfgField('offset', '自动推断剧集偏移', CfgType.bool_),
    CfgField('omit', '检测遗漏集数', CfgType.bool_),
  ]),
];

/// spec 中覆盖到的所有 key（「高级(原始)」区据此剔除已展示的字段）。
final Set<String> kSpeccedConfigKeys = {
  for (final s in kAniRssConfigSpec)
    for (final f in s.fields) f.key,
};
