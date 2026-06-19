/// 播放错误文案处理。
///
/// 底层播放/网络错误串里常带有完整播放地址（含 `api_key` 等敏感参数）或晦涩的
/// 英文堆栈，既不能直接展示给用户（会泄露播放地址），也看不懂。这里把常见错误
/// 归类成**安全、友好的中文文案**，并统一附带「导出日志反馈」引导。
///
/// 原则：永不回显原始错误串——所有分支（含兜底）都返回固定文案。
library;

/// Telegram 反馈频道地址。
const String kFeedbackChannelUrl = 'https://t.me/MikudesuChannels';

/// 出错时统一的反馈引导文案（不含链接本身，链接单独展示以便复制）。
const String kPlaybackErrorFeedbackHint =
    '若反复出现，请前往「设置 → 关于 → 导出日志」，并将日志发送到下方 Telegram 频道，'
    '交由频道主排查修复。';

/// 将任意播放/初始化错误转换为可安全展示的中文文案。
///
/// [rawError] 可以是异常对象或字符串；函数只读取其文本特征做归类，绝不回显原文，
/// 因此即便原始串里含播放地址也不会泄露。
String friendlyPlaybackError(Object? rawError) {
  final r = (rawError?.toString() ?? '').toLowerCase();
  if (r.isEmpty) {
    return '播放遇到问题，无法继续播放。';
  }

  // 网络连接类：超时 / 断网 / DNS / 连接被拒。
  if (r.contains('timeout') ||
      r.contains('timed out') ||
      r.contains('socketexception') ||
      r.contains('connection error') ||
      r.contains('connection refused') ||
      r.contains('connection closed') ||
      r.contains('connection reset') ||
      r.contains('failed host lookup') ||
      r.contains('network is unreachable') ||
      r.contains('no address associated')) {
    return '无法连接到服务器，请检查网络连接或服务器状态后重试。';
  }

  // 鉴权类：登录过期 / 无权限。
  if (r.contains(' 401') ||
      r.contains('401 ') ||
      r.contains(' 403') ||
      r.contains('403 ') ||
      r.contains('unauthorized') ||
      r.contains('forbidden')) {
    return '登录状态已失效或无访问权限，请重新登录服务器后重试。';
  }

  // 资源不存在。
  if (r.contains(' 404') || r.contains('404 ') || r.contains('not found')) {
    return '该视频资源不存在或已被移除。';
  }

  // 区间请求被拒（416）：通常是源不支持范围请求或链接已失效。
  if (r.contains('416') || r.contains('range not satisfiable')) {
    return '当前视频源暂时无法播放（服务器拒绝了播放请求），请稍后重试或更换播放源。';
  }

  // 服务器侧错误。
  if (r.contains(' 500') ||
      r.contains('500 ') ||
      r.contains(' 502') ||
      r.contains(' 503') ||
      r.contains(' 504') ||
      r.contains('internal server error') ||
      r.contains('bad gateway') ||
      r.contains('service unavailable')) {
    return '服务器繁忙或内部错误，请稍后重试。';
  }

  // 打不开 / 解析失败 / 格式不支持。
  if (r.contains('failed to open') ||
      r.contains('failed to recognize') ||
      r.contains('unrecognized') ||
      r.contains('demux') ||
      r.contains('no such file') ||
      r.contains('unsupported') ||
      r.contains('invalid data')) {
    return '无法打开该视频流，可能是源格式不受支持或链接已失效。';
  }

  // 兜底：不回显原文。
  return '播放遇到问题，无法继续播放。';
}
