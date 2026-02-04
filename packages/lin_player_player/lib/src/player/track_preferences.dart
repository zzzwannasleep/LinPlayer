import 'package:media_kit/media_kit.dart';

bool isSubtitleOffPreference(String pref) => pref.trim().toLowerCase() == 'off';

String _norm(String? v) => (v ?? '').trim().toLowerCase();

bool _containsAny(String haystack, Iterable<String> needles) {
  for (final n in needles) {
    if (n.isEmpty) continue;
    if (haystack.contains(n)) return true;
  }
  return false;
}

bool _matchesChineseSimplified(String hay) {
  // Prefer Simplified Chinese when the user hasn't explicitly selected subtitles.
  // Common signals: zhs/chs/zh-Hans/zh-CN, "简体"/"简中"/"Simplified".
  return _containsAny(hay, const [
    'zhs',
    'chs',
    'zh-hans',
    'hans',
    'zh-cn',
    'zh-sg',
    '简体',
    '简中',
    'simplified',
  ]);
}

bool _matchesChineseTraditional(String hay) {
  return _containsAny(hay, const [
    'zht',
    'cht',
    'zh-hant',
    'hant',
    'zh-tw',
    'zh-hk',
    '繁体',
    '繁中',
    'traditional',
  ]);
}

bool matchesPreferredLanguage({
  required String preference,
  String? language,
  String? title,
}) {
  final pref = _norm(preference);
  if (pref.isEmpty || pref == 'default') return false;

  final lang = _norm(language);
  final t = _norm(title);
  final hay = '$lang $t';

  if (_containsAny(hay, [pref])) return true;

  switch (pref) {
    case 'zhs':
    case 'chs':
    case 'zh-hans':
    case 'zh-cn':
    case 'zh-sg':
    case 'hans':
      return _matchesChineseSimplified(hay);
    case 'zht':
    case 'cht':
    case 'zh-hant':
    case 'zh-tw':
    case 'zh-hk':
    case 'hant':
      return _matchesChineseTraditional(hay);
    case 'chi':
    case 'zho':
    case 'zh':
      return _containsAny(hay, const [
        'chi',
        'zho',
        'zh',
        'zhs',
        'zht',
        'chs',
        'cht',
        'zh-hans',
        'zh-hant',
        'hans',
        'hant',
        'cmn',
        'chinese',
        '中文',
        '简体',
        '繁体',
      ]);
    case 'jpn':
    case 'ja':
      return _containsAny(hay, const [
        'jpn',
        'ja',
        'japanese',
        '日语',
        '日本語',
      ]);
    case 'eng':
    case 'en':
      return _containsAny(hay, const [
        'eng',
        'en',
        'english',
        '英语',
      ]);
    default:
      return lang == pref;
  }
}

AudioTrack? pickPreferredAudioTrack(Tracks tracks, String preference) {
  final pref = _norm(preference);
  if (pref.isEmpty || pref == 'default') {
    return null;
  }
  for (final a in tracks.audio) {
    if (matchesPreferredLanguage(
        preference: pref, language: a.language, title: a.title)) {
      return a;
    }
  }
  return null;
}

SubtitleTrack? pickPreferredSubtitleTrack(Tracks tracks, String preference) {
  final pref = _norm(preference);
  if (isSubtitleOffPreference(pref)) return null;

  // Default behavior: if user hasn't chosen subtitles, prefer Simplified Chinese.
  final isDefaultPref = pref.isEmpty || pref == 'default';
  final primaryPref = isDefaultPref ? 'zhs' : pref;
  if (primaryPref.isNotEmpty) {
    for (final s in tracks.subtitle) {
      if (matchesPreferredLanguage(
          preference: primaryPref, language: s.language, title: s.title)) {
        return s;
      }
    }
  }

  // Fallback for default: any Chinese subtitle (incl. Traditional) if available.
  if (isDefaultPref) {
    for (final s in tracks.subtitle) {
      if (matchesPreferredLanguage(
          preference: 'chi', language: s.language, title: s.title)) {
        return s;
      }
    }
  }
  return null;
}
