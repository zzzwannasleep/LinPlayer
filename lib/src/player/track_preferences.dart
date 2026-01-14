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
  if (pref.isEmpty || pref == 'default') return null;
  for (final a in tracks.audio) {
    if (matchesPreferredLanguage(preference: pref, language: a.language, title: a.title)) {
      return a;
    }
  }
  return null;
}

SubtitleTrack? pickPreferredSubtitleTrack(Tracks tracks, String preference) {
  final pref = _norm(preference);
  if (pref.isEmpty || pref == 'default' || isSubtitleOffPreference(pref)) return null;
  for (final s in tracks.subtitle) {
    if (matchesPreferredLanguage(preference: pref, language: s.language, title: s.title)) {
      return s;
    }
  }
  return null;
}

