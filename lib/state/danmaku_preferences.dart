enum DanmakuLoadMode {
  local,
  online,
}

DanmakuLoadMode danmakuLoadModeFromId(String? id) {
  switch (id) {
    case 'online':
      return DanmakuLoadMode.online;
    case 'local':
    default:
      return DanmakuLoadMode.local;
  }
}

extension DanmakuLoadModeX on DanmakuLoadMode {
  String get id {
    switch (this) {
      case DanmakuLoadMode.local:
        return 'local';
      case DanmakuLoadMode.online:
        return 'online';
    }
  }

  String get label {
    switch (this) {
      case DanmakuLoadMode.local:
        return '本地';
      case DanmakuLoadMode.online:
        return '在线';
    }
  }
}

enum DanmakuMatchMode {
  auto,
  fileNameOnly,
  hashAndFileName,
}

DanmakuMatchMode danmakuMatchModeFromId(String? id) {
  switch (id) {
    case 'fileNameOnly':
      return DanmakuMatchMode.fileNameOnly;
    case 'hashAndFileName':
      return DanmakuMatchMode.hashAndFileName;
    case 'auto':
    default:
      return DanmakuMatchMode.auto;
  }
}

extension DanmakuMatchModeX on DanmakuMatchMode {
  String get id {
    switch (this) {
      case DanmakuMatchMode.auto:
        return 'auto';
      case DanmakuMatchMode.fileNameOnly:
        return 'fileNameOnly';
      case DanmakuMatchMode.hashAndFileName:
        return 'hashAndFileName';
    }
  }

  String get label {
    switch (this) {
      case DanmakuMatchMode.auto:
        return '自动';
      case DanmakuMatchMode.fileNameOnly:
        return '仅文件名';
      case DanmakuMatchMode.hashAndFileName:
        return '哈希值 + 文件名';
    }
  }
}

enum DanmakuChConvert {
  off,
  toSimplified,
  toTraditional,
}

DanmakuChConvert danmakuChConvertFromId(String? id) {
  switch (id) {
    case 'toSimplified':
      return DanmakuChConvert.toSimplified;
    case 'toTraditional':
      return DanmakuChConvert.toTraditional;
    case 'off':
    default:
      return DanmakuChConvert.off;
  }
}

extension DanmakuChConvertX on DanmakuChConvert {
  String get id {
    switch (this) {
      case DanmakuChConvert.off:
        return 'off';
      case DanmakuChConvert.toSimplified:
        return 'toSimplified';
      case DanmakuChConvert.toTraditional:
        return 'toTraditional';
    }
  }

  String get label {
    switch (this) {
      case DanmakuChConvert.off:
        return '关闭';
      case DanmakuChConvert.toSimplified:
        return '简体';
      case DanmakuChConvert.toTraditional:
        return '繁体';
    }
  }

  int get apiValue {
    switch (this) {
      case DanmakuChConvert.off:
        return 0;
      case DanmakuChConvert.toSimplified:
        return 1;
      case DanmakuChConvert.toTraditional:
        return 2;
    }
  }
}
