/// 应用统一身份标识（版本号 + User-Agent）。
///
/// 版本号在 CI 构建时通过 `--dart-define=APP_VERSION` 注入；本地运行默认取
/// pubspec 的基础版本号。所有对外网络请求（API / 图片 / 下载 / 同步 / 播放流）
/// 都应使用 [kAppUserAgent] 作为 User-Agent，避免部分 CDN 拒绝默认（空/Dart）
/// UA 导致封面、流媒体请求失败。
library;

/// 应用当前版本号（归一化的 x.y.z，可能带 -buildN 后缀）。
const String kAppVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

/// 统一 User-Agent：`LinPlayer/<版本号>`。
const String kAppUserAgent = 'LinPlayer/$kAppVersion';

/// 预加载 User-Agent：`LinplayerPreload/<版本号>`。
///
/// 详情页（集/电影）开启「预加载」后，会用此 UA 对真实播放流发起规范的
/// Range 预取请求，提前预热服务端/CDN 缓存，与正常播放（[kAppUserAgent]）
/// 区分开，便于服务端按 UA 识别/统计预加载流量。
const String kPreloadUserAgent = 'LinplayerPreload/$kAppVersion';

/// 中立浏览器 User-Agent。
///
/// 部分第三方图标 CDN / 图床会拒绝自定义 App UA（`LinPlayer/x.x.x`），导致
/// 服务器图标等「中立」资源加载失败、显示损坏。这类请求改用通用浏览器 UA，
/// 不带任何 App 身份，最大化兼容性。
const String kDefaultBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
