import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/translation/engines/ai_translation_engine.dart';
import '../services/translation/engines/baidu_translation_engine.dart';
import '../services/translation/engines/tencent_translation_engine.dart';
import '../services/translation/subtitle_document.dart';
import '../services/translation/subtitle_translation_service.dart';
import '../services/translation/translation_engine.dart';
import '../services/translation/whisper/whisper_model.dart';
import '../services/secure_credential_store.dart';
import 'app_preferences.dart';

// ============ 引擎选择与目标语言 ============

/// 当前选用的翻译引擎。
final translationEngineKindProvider =
    StateNotifierProvider<PreferenceNotifier<TranslationEngineKind>,
        TranslationEngineKind>((ref) {
  return PreferenceNotifier<TranslationEngineKind>(
    defaultValue: TranslationEngineKind.openai,
    readValue: (prefs) =>
        TranslationEngineKind.fromKey(prefs.getString('linplayer_trans_engine')),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_trans_engine', value.storageKey);
    },
  );
});

/// 翻译目标语言（默认简体中文）。
final translationTargetLangProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: 'zh',
    readValue: (prefs) => prefs.getString('linplayer_trans_target'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_trans_target', value);
    },
  );
});

/// 双语排版方式。
final bilingualLayoutProvider =
    StateNotifierProvider<PreferenceNotifier<BilingualLayout>, BilingualLayout>(
        (ref) {
  return PreferenceNotifier<BilingualLayout>(
    defaultValue: BilingualLayout.translatedFirst,
    readValue: (prefs) {
      final v = prefs.getString('linplayer_trans_layout');
      return BilingualLayout.values
          .firstWhere((e) => e.name == v, orElse: () => BilingualLayout.translatedFirst);
    },
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_trans_layout', value.name);
    },
  );
});

// ============ 各引擎配置 ============

// 翻译引擎配置含 apiKey/secretKey，改存 OS 安全加密 KV（M5），不再明文进 prefs。
PreferenceNotifier<AiEngineConfig> _aiNotifier(String key, AiEngineConfig def) {
  return PreferenceNotifier<AiEngineConfig>(
    defaultValue: def,
    readValue: (_) {
      final s = SecureCredentialStore.instance.readKv(key);
      if (s == null) return null;
      try {
        return AiEngineConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    },
    writeValue: (_, value) async {
      await SecureCredentialStore.instance
          .writeKv(key, jsonEncode(value.toJson()));
    },
  );
}

final openAiConfigProvider =
    StateNotifierProvider<PreferenceNotifier<AiEngineConfig>, AiEngineConfig>(
        (ref) => _aiNotifier('linplayer_trans_openai', AiEngineConfig.openaiDefault));

final anthropicConfigProvider =
    StateNotifierProvider<PreferenceNotifier<AiEngineConfig>, AiEngineConfig>(
        (ref) =>
            _aiNotifier('linplayer_trans_anthropic', AiEngineConfig.anthropicDefault));

PreferenceNotifier<BaiduEngineConfig> _baiduNotifier(String key) {
  return PreferenceNotifier<BaiduEngineConfig>(
    defaultValue: const BaiduEngineConfig(),
    readValue: (_) {
      final s = SecureCredentialStore.instance.readKv(key);
      if (s == null) return null;
      try {
        return BaiduEngineConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    },
    writeValue: (_, value) async {
      await SecureCredentialStore.instance
          .writeKv(key, jsonEncode(value.toJson()));
    },
  );
}

final baiduGeneralConfigProvider = StateNotifierProvider<
    PreferenceNotifier<BaiduEngineConfig>, BaiduEngineConfig>(
  (ref) => _baiduNotifier('linplayer_trans_baidu_general'),
);

final baiduLlmConfigProvider = StateNotifierProvider<
    PreferenceNotifier<BaiduEngineConfig>, BaiduEngineConfig>(
  (ref) => _baiduNotifier('linplayer_trans_baidu_llm'),
);

final tencentConfigProvider = StateNotifierProvider<
    PreferenceNotifier<TencentEngineConfig>, TencentEngineConfig>((ref) {
  return PreferenceNotifier<TencentEngineConfig>(
    defaultValue: const TencentEngineConfig(),
    readValue: (_) {
      final s = SecureCredentialStore.instance.readKv('linplayer_trans_tencent');
      if (s == null) return null;
      try {
        return TencentEngineConfig.fromJson(
            jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    },
    writeValue: (_, value) async {
      await SecureCredentialStore.instance
          .writeKv('linplayer_trans_tencent', jsonEncode(value.toJson()));
    },
  );
});

// ============ 引擎工厂 ============

/// 按当前选择与配置构造翻译引擎；未配置返回 null。
final activeTranslationEngineProvider = Provider<TranslationEngine?>((ref) {
  final kind = ref.watch(translationEngineKindProvider);
  switch (kind) {
    case TranslationEngineKind.openai:
      final cfg = ref.watch(openAiConfigProvider);
      return cfg.isConfigured ? OpenAiTranslationEngine(cfg) : null;
    case TranslationEngineKind.anthropic:
      final cfg = ref.watch(anthropicConfigProvider);
      return cfg.isConfigured ? AnthropicTranslationEngine(cfg) : null;
    case TranslationEngineKind.baiduGeneral:
      final cfg = ref.watch(baiduGeneralConfigProvider);
      return cfg.isConfigured
          ? BaiduTranslationEngine(cfg,
              engineId: 'baidu_general',
              defaultEndpoint: BaiduEngineConfig.generalEndpoint)
          : null;
    case TranslationEngineKind.baiduLlm:
      final cfg = ref.watch(baiduLlmConfigProvider);
      return cfg.isConfigured ? BaiduLlmTranslationEngine(cfg) : null;
    case TranslationEngineKind.tencent:
      final cfg = ref.watch(tencentConfigProvider);
      return cfg.isConfigured ? TencentTranslationEngine(cfg) : null;
  }
});

final subtitleTranslationServiceProvider =
    Provider<SubtitleTranslationService>((ref) => SubtitleTranslationService());

// ============ Whisper（PC 端）设置 ============

/// 是否启用 Whisper 本地转写（默认关闭，用户手动开启后再下载模型）。
final whisperEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_whisper_enabled'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_whisper_enabled', value);
    },
  );
});

/// 选用的 Whisper 模型规格。
final whisperModelProvider =
    StateNotifierProvider<PreferenceNotifier<WhisperModel>, WhisperModel>((ref) {
  return PreferenceNotifier<WhisperModel>(
    defaultValue: WhisperModel.base,
    readValue: (prefs) =>
        WhisperModel.fromKey(prefs.getString('linplayer_whisper_model')),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_whisper_model', value.storageKey);
    },
  );
});

/// 模型下载镜像（留空用官方源）。
final whisperMirrorProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_whisper_mirror'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_whisper_mirror', value);
    },
  );
});

/// whisper-cli 可执行文件路径（用户指定或自动定位）。
final whisperBinaryPathProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_whisper_binary'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_whisper_binary', value);
    },
  );
});

/// ffmpeg 可执行文件路径（音频抽取用）。
final ffmpegPathProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '',
    readValue: (prefs) => prefs.getString('linplayer_ffmpeg_path'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_ffmpeg_path', value);
    },
  );
});
