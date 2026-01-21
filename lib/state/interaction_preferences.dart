enum DoubleTapAction {
  none,
  playPause,
  seekBackward,
  seekForward,
}

DoubleTapAction doubleTapActionFromId(String? id) {
  switch ((id ?? '').trim()) {
    case 'playPause':
      return DoubleTapAction.playPause;
    case 'seekBackward':
      return DoubleTapAction.seekBackward;
    case 'seekForward':
      return DoubleTapAction.seekForward;
    case 'none':
    default:
      return DoubleTapAction.none;
  }
}

extension DoubleTapActionX on DoubleTapAction {
  String get id {
    switch (this) {
      case DoubleTapAction.none:
        return 'none';
      case DoubleTapAction.playPause:
        return 'playPause';
      case DoubleTapAction.seekBackward:
        return 'seekBackward';
      case DoubleTapAction.seekForward:
        return 'seekForward';
    }
  }

  String get label {
    switch (this) {
      case DoubleTapAction.none:
        return '无';
      case DoubleTapAction.playPause:
        return '播放/暂停';
      case DoubleTapAction.seekBackward:
        return '快退';
      case DoubleTapAction.seekForward:
        return '快进';
    }
  }
}

enum ReturnHomeBehavior {
  pause,
  keepPlaying,
}

ReturnHomeBehavior returnHomeBehaviorFromId(String? id) {
  switch ((id ?? '').trim()) {
    case 'keepPlaying':
      return ReturnHomeBehavior.keepPlaying;
    case 'pause':
    default:
      return ReturnHomeBehavior.pause;
  }
}

extension ReturnHomeBehaviorX on ReturnHomeBehavior {
  String get id {
    switch (this) {
      case ReturnHomeBehavior.pause:
        return 'pause';
      case ReturnHomeBehavior.keepPlaying:
        return 'keepPlaying';
    }
  }

  String get label {
    switch (this) {
      case ReturnHomeBehavior.pause:
        return '暂停视频';
      case ReturnHomeBehavior.keepPlaying:
        return '继续播放';
    }
  }
}
