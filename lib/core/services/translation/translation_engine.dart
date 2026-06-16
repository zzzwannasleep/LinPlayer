/// 翻译引擎抽象层。
///
/// 三种接入模式统一到 [TranslationEngine] 接口之下：
/// - AI 接口（OpenAI / Anthropic 格式）：整批 JSON 翻译。
/// - API 接口（百度通用 / 百度大模型 / 腾讯）：文本翻译接口。
/// - Whisper 转写出的文本同样经此接口译成中文（PC 端流式）。
library;

/// 引擎种类。
enum TranslationEngineKind {
  openai,
  anthropic,
  baiduGeneral,
  baiduLlm,
  tencent;

  String get storageKey => name;

  String get label => switch (this) {
        TranslationEngineKind.openai => 'AI · OpenAI 格式',
        TranslationEngineKind.anthropic => 'AI · Anthropic 格式',
        TranslationEngineKind.baiduGeneral => '百度通用翻译',
        TranslationEngineKind.baiduLlm => '百度大模型翻译',
        TranslationEngineKind.tencent => '腾讯机器翻译',
      };

  bool get isAi =>
      this == TranslationEngineKind.openai ||
      this == TranslationEngineKind.anthropic;

  static TranslationEngineKind fromKey(String? key) =>
      TranslationEngineKind.values.firstWhere(
        (e) => e.storageKey == key,
        orElse: () => TranslationEngineKind.openai,
      );
}

/// 翻译失败异常（携带引擎与可读原因）。
class TranslationException implements Exception {
  TranslationException(this.engine, this.message, {this.cause});
  final String engine;
  final String message;
  final Object? cause;
  @override
  String toString() => '[$engine] $message${cause != null ? ' ($cause)' : ''}';
}

/// 翻译引擎接口。实现需保证返回列表与输入等长、顺序一致。
abstract class TranslationEngine {
  String get id;

  /// 单批可处理的最大条数（服务层据此分块）。
  int get maxBatchSize;

  /// 单批文本字符数上限（服务层据此分块，0 表示不限制）。
  int get maxBatchChars;

  /// 并发批次上限（API 限流敏感的引擎应取 1）。
  int get maxConcurrency;

  /// 翻译一批文本。[sourceLang]/[targetLang] 为 ISO 风格代码（auto/zh/ja/en…）。
  /// 返回与 [texts] 等长的译文列表。
  Future<List<String>> translate(
    List<String> texts, {
    required String sourceLang,
    required String targetLang,
  });
}

// ============ 配置模型 ============

/// AI 引擎配置（OpenAI / Anthropic 通用）。
class AiEngineConfig {
  const AiEngineConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured => apiKey.isNotEmpty && baseUrl.isNotEmpty;

  AiEngineConfig copyWith({String? baseUrl, String? apiKey, String? model}) =>
      AiEngineConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() =>
      {'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};

  factory AiEngineConfig.fromJson(Map<String, dynamic> j) => AiEngineConfig(
        baseUrl: (j['baseUrl'] ?? '') as String,
        apiKey: (j['apiKey'] ?? '') as String,
        model: (j['model'] ?? '') as String,
      );

  static const openaiDefault = AiEngineConfig(
    baseUrl: 'https://api.openai.com/v1',
    model: 'gpt-4o-mini',
  );
  static const anthropicDefault = AiEngineConfig(
    baseUrl: 'https://api.anthropic.com/v1',
    model: 'claude-haiku-4-5-20251001',
  );
}

/// 百度翻译配置（通用 / 大模型共用，endpoint 可改）。
class BaiduEngineConfig {
  const BaiduEngineConfig({
    this.endpoint = '',
    this.appId = '',
    this.secretKey = '',
    this.apiKey = '',
  });

  final String endpoint;
  final String appId;
  final String secretKey;

  /// 大模型接口的 Bearer API Key（通用接口不用）。
  final String apiKey;

  bool get isConfigured =>
      appId.isNotEmpty && (secretKey.isNotEmpty || apiKey.isNotEmpty);

  BaiduEngineConfig copyWith({
    String? endpoint,
    String? appId,
    String? secretKey,
    String? apiKey,
  }) =>
      BaiduEngineConfig(
        endpoint: endpoint ?? this.endpoint,
        appId: appId ?? this.appId,
        secretKey: secretKey ?? this.secretKey,
        apiKey: apiKey ?? this.apiKey,
      );

  Map<String, dynamic> toJson() => {
        'endpoint': endpoint,
        'appId': appId,
        'secretKey': secretKey,
        'apiKey': apiKey,
      };

  factory BaiduEngineConfig.fromJson(Map<String, dynamic> j) =>
      BaiduEngineConfig(
        endpoint: (j['endpoint'] ?? '') as String,
        appId: (j['appId'] ?? '') as String,
        secretKey: (j['secretKey'] ?? '') as String,
        apiKey: (j['apiKey'] ?? '') as String,
      );

  // 通用翻译接口地址（已核实：q/from/to/appid/salt/sign，sign=MD5(appid+q+salt+密钥)）。
  static const generalEndpoint =
      'https://fanyi-api.baidu.com/api/trans/vip/translate';
  // 大模型文本翻译接口（已核实：POST JSON + Bearer API Key，model_type=llm）。
  static const llmEndpoint =
      'https://fanyi-api.baidu.com/ait/api/aiTextTranslate';
}

/// 腾讯机器翻译配置。
class TencentEngineConfig {
  const TencentEngineConfig({
    this.secretId = '',
    this.secretKey = '',
    this.region = 'ap-beijing',
    this.projectId = 0,
  });

  final String secretId;
  final String secretKey;
  final String region;
  final int projectId;

  bool get isConfigured => secretId.isNotEmpty && secretKey.isNotEmpty;

  TencentEngineConfig copyWith({
    String? secretId,
    String? secretKey,
    String? region,
    int? projectId,
  }) =>
      TencentEngineConfig(
        secretId: secretId ?? this.secretId,
        secretKey: secretKey ?? this.secretKey,
        region: region ?? this.region,
        projectId: projectId ?? this.projectId,
      );

  Map<String, dynamic> toJson() => {
        'secretId': secretId,
        'secretKey': secretKey,
        'region': region,
        'projectId': projectId,
      };

  factory TencentEngineConfig.fromJson(Map<String, dynamic> j) =>
      TencentEngineConfig(
        secretId: (j['secretId'] ?? '') as String,
        secretKey: (j['secretKey'] ?? '') as String,
        region: (j['region'] ?? 'ap-beijing') as String,
        projectId: (j['projectId'] ?? 0) as int,
      );

  static const endpoint = 'tmt.tencentcloudapi.com';
}

/// 语言代码归一：把 Emby/ISO 三字母码映射到各引擎可识别的代码。
class TranslationLang {
  /// 通用目标默认中文。
  static const targetChineseGeneric = 'zh';

  /// 自动检测源语言。
  static const autoSource = 'auto';

  /// ISO/Emby 码 → 百度码（日语为 jp，中文 zh，自动 auto）。
  static String toBaidu(String code) {
    switch (code.toLowerCase()) {
      case 'auto':
        return 'auto';
      case 'zh':
      case 'chi':
      case 'zho':
      case 'chs':
        return 'zh';
      case 'cht':
        return 'cht';
      case 'en':
      case 'eng':
        return 'en';
      case 'ja':
      case 'jpn':
        return 'jp';
      case 'ko':
      case 'kor':
        return 'kor';
      case 'fr':
      case 'fre':
      case 'fra':
        return 'fra';
      case 'de':
      case 'ger':
      case 'deu':
        return 'de';
      case 'ru':
      case 'rus':
        return 'ru';
      case 'es':
      case 'spa':
        return 'spa';
      default:
        return 'auto';
    }
  }

  /// ISO/Emby 码 → 腾讯码（日语 ja，中文 zh，自动 auto）。
  static String toTencent(String code) {
    switch (code.toLowerCase()) {
      case 'auto':
        return 'auto';
      case 'zh':
      case 'chi':
      case 'zho':
      case 'chs':
        return 'zh';
      case 'cht':
        return 'zh-TW';
      case 'en':
      case 'eng':
        return 'en';
      case 'ja':
      case 'jpn':
        return 'ja';
      case 'ko':
      case 'kor':
        return 'ko';
      case 'fr':
      case 'fre':
      case 'fra':
        return 'fr';
      case 'de':
      case 'ger':
      case 'deu':
        return 'de';
      case 'ru':
      case 'rus':
        return 'ru';
      case 'es':
      case 'spa':
        return 'es';
      default:
        return 'auto';
    }
  }

  /// ISO/Emby 码 → 人类可读语言名（喂给 AI 提示词）。
  static String humanName(String code) {
    switch (code.toLowerCase()) {
      case 'auto':
        return 'the source language';
      case 'zh':
      case 'chi':
      case 'zho':
      case 'chs':
        return 'Simplified Chinese';
      case 'cht':
        return 'Traditional Chinese';
      case 'en':
      case 'eng':
        return 'English';
      case 'ja':
      case 'jpn':
        return 'Japanese';
      case 'ko':
      case 'kor':
        return 'Korean';
      case 'fr':
      case 'fre':
      case 'fra':
        return 'French';
      case 'de':
      case 'ger':
      case 'deu':
        return 'German';
      case 'ru':
      case 'rus':
        return 'Russian';
      case 'es':
      case 'spa':
        return 'Spanish';
      default:
        return code;
    }
  }
}
