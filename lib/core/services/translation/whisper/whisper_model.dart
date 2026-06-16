/// Whisper 本地模型规格（PC 端专属）。
///
/// 不预置任何模型，用户在设置里开启功能后按需下载。模型为 whisper.cpp 的
/// GGML 量化权重，下载源默认 Hugging Face 官方仓库。
enum WhisperModel {
  tiny,
  base,
  medium,
  large;

  String get displayName => switch (this) {
        WhisperModel.tiny => 'Tiny（最快，精度最低）',
        WhisperModel.base => 'Base（快速，日常够用）',
        WhisperModel.medium => 'Medium（较慢，精度好）',
        WhisperModel.large => 'Large（最慢，精度最高）',
      };

  /// 权重文件名（whisper.cpp GGML 格式）。
  String get fileName => switch (this) {
        WhisperModel.tiny => 'ggml-tiny.bin',
        WhisperModel.base => 'ggml-base.bin',
        WhisperModel.medium => 'ggml-medium.bin',
        WhisperModel.large => 'ggml-large-v3.bin',
      };

  /// 大致体积（用于 UI 提示）。
  String get sizeLabel => switch (this) {
        WhisperModel.tiny => '约 75 MB',
        WhisperModel.base => '约 142 MB',
        WhisperModel.medium => '约 1.5 GB',
        WhisperModel.large => '约 2.9 GB',
      };

  /// 默认下载地址（Hugging Face 官方仓库；设置里可改镜像）。
  String downloadUrl(String mirrorBase) {
    final base = mirrorBase.isNotEmpty
        ? mirrorBase.replaceAll(RegExp(r'/+$'), '')
        : 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';
    return '$base/$fileName';
  }

  String get storageKey => name;

  static WhisperModel fromKey(String? key) => WhisperModel.values.firstWhere(
        (m) => m.storageKey == key,
        orElse: () => WhisperModel.base,
      );
}
