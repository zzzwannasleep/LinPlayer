enum DesktopUiLanguage {
  zhCn,
  enUs,
}

extension DesktopUiLanguageX on DesktopUiLanguage {
  bool get isChinese => this == DesktopUiLanguage.zhCn;

  String pick({
    required String zh,
    required String en,
  }) {
    return isChinese ? zh : en;
  }
}
