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
