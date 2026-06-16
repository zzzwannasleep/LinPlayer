part of 'settings_screen.dart';

/// 字幕翻译设置页（移动端）。
class TranslationSettingsScreen extends ConsumerWidget {
  const TranslationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ref.watch(translationEngineKindProvider);
    final target = ref.watch(translationTargetLangProvider);
    final layout = ref.watch(bilingualLayoutProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('字幕翻译')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          const _SectionHeader('翻译引擎'),
          ListTile(
            title: const Text('引擎模式'),
            subtitle: Text(kind.label),
            trailing: DropdownButton<TranslationEngineKind>(
              value: kind,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(translationEngineKindProvider.notifier).state = v;
                }
              },
              items: [
                for (final e in TranslationEngineKind.values)
                  DropdownMenuItem(value: e, child: Text(e.label)),
              ],
            ),
          ),
          const Divider(height: 1),
          _EngineConfigForm(kind: kind),
          const _SectionHeader('翻译输出'),
          ListTile(
            title: const Text('目标语言'),
            trailing: DropdownButton<String>(
              value: target == 'cht' ? 'cht' : 'zh',
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(translationTargetLangProvider.notifier).state = v;
                }
              },
              items: const [
                DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                DropdownMenuItem(value: 'cht', child: Text('繁体中文')),
              ],
            ),
          ),
          ListTile(
            title: const Text('双语排版'),
            subtitle: Text(_layoutLabel(layout)),
            trailing: DropdownButton<BilingualLayout>(
              value: layout,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(bilingualLayoutProvider.notifier).state = v;
                }
              },
              items: const [
                DropdownMenuItem(
                    value: BilingualLayout.translatedOnly, child: Text('仅译文')),
                DropdownMenuItem(
                    value: BilingualLayout.translatedFirst,
                    child: Text('译文+原文')),
                DropdownMenuItem(
                    value: BilingualLayout.originalFirst,
                    child: Text('原文+译文')),
              ],
            ),
          ),
          if (isDesktopPlatform) ...[
            const _SectionHeader('Whisper 本地转写（PC 专属）'),
            const _WhisperSection(),
          ],
        ],
      ),
    );
  }

  static String _layoutLabel(BilingualLayout l) => switch (l) {
        BilingualLayout.translatedOnly => '只显示中文译文',
        BilingualLayout.translatedFirst => '中文在上，原文在下',
        BilingualLayout.originalFirst => '原文在上，中文在下',
      };
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// 按引擎类型渲染对应配置表单。
class _EngineConfigForm extends ConsumerWidget {
  const _EngineConfigForm({required this.kind});
  final TranslationEngineKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (kind) {
      case TranslationEngineKind.openai:
        return _AiForm(
          provider: openAiConfigProvider,
          hintBase: 'https://api.openai.com/v1',
          hintModel: 'gpt-4o-mini',
        );
      case TranslationEngineKind.anthropic:
        return _AiForm(
          provider: anthropicConfigProvider,
          hintBase: 'https://api.anthropic.com/v1',
          hintModel: 'claude-haiku-4-5-20251001',
        );
      case TranslationEngineKind.baiduGeneral:
        return _BaiduForm(
          provider: baiduGeneralConfigProvider,
          endpointHint: BaiduEngineConfig.generalEndpoint,
          isLlm: false,
        );
      case TranslationEngineKind.baiduLlm:
        return _BaiduForm(
          provider: baiduLlmConfigProvider,
          endpointHint: BaiduEngineConfig.llmEndpoint,
          isLlm: true,
        );
      case TranslationEngineKind.tencent:
        return const _TencentForm();
    }
  }
}

class _AiForm extends ConsumerStatefulWidget {
  const _AiForm({
    required this.provider,
    required this.hintBase,
    required this.hintModel,
  });
  final StateNotifierProvider<PreferenceNotifier<AiEngineConfig>, AiEngineConfig>
      provider;
  final String hintBase;
  final String hintModel;

  @override
  ConsumerState<_AiForm> createState() => _AiFormState();
}

class _AiFormState extends ConsumerState<_AiForm> {
  late TextEditingController _base;
  late TextEditingController _key;
  late TextEditingController _model;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(widget.provider);
    _base = TextEditingController(text: cfg.baseUrl);
    _key = TextEditingController(text: cfg.apiKey);
    _model = TextEditingController(text: cfg.model);
  }

  @override
  void didUpdateWidget(covariant _AiForm old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      final cfg = ref.read(widget.provider);
      _base.text = cfg.baseUrl;
      _key.text = cfg.apiKey;
      _model.text = cfg.model;
    }
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  void _save() {
    ref.read(widget.provider.notifier).state = AiEngineConfig(
      baseUrl: _base.text.trim(),
      apiKey: _key.text.trim(),
      model: _model.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _field(_base, 'API 地址 (Base URL)', widget.hintBase, onChanged: (_) => _save()),
          const SizedBox(height: 12),
          _field(_key, 'API Key', 'sk-...', obscure: true, onChanged: (_) => _save()),
          const SizedBox(height: 12),
          _field(_model, '模型', widget.hintModel, onChanged: (_) => _save()),
        ],
      ),
    );
  }
}

class _BaiduForm extends ConsumerStatefulWidget {
  const _BaiduForm({
    required this.provider,
    required this.endpointHint,
    required this.isLlm,
  });
  final StateNotifierProvider<PreferenceNotifier<BaiduEngineConfig>,
      BaiduEngineConfig> provider;
  final String endpointHint;
  final bool isLlm;

  @override
  ConsumerState<_BaiduForm> createState() => _BaiduFormState();
}

class _BaiduFormState extends ConsumerState<_BaiduForm> {
  late TextEditingController _appId;
  late TextEditingController _secret; // 通用=密钥 / 大模型=API Key
  late TextEditingController _endpoint;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(widget.provider);
    _appId = TextEditingController(text: cfg.appId);
    _secret =
        TextEditingController(text: widget.isLlm ? cfg.apiKey : cfg.secretKey);
    _endpoint = TextEditingController(text: cfg.endpoint);
  }

  @override
  void didUpdateWidget(covariant _BaiduForm old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      final cfg = ref.read(widget.provider);
      _appId.text = cfg.appId;
      _secret.text = widget.isLlm ? cfg.apiKey : cfg.secretKey;
      _endpoint.text = cfg.endpoint;
    }
  }

  @override
  void dispose() {
    _appId.dispose();
    _secret.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  void _save() {
    final base = ref.read(widget.provider).copyWith(
          appId: _appId.text.trim(),
          endpoint: _endpoint.text.trim(),
        );
    ref.read(widget.provider.notifier).state = widget.isLlm
        ? base.copyWith(apiKey: _secret.text.trim())
        : base.copyWith(secretKey: _secret.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _field(_appId, 'APP ID', '百度翻译开放平台 APPID', onChanged: (_) => _save()),
          const SizedBox(height: 12),
          if (widget.isLlm)
            _field(_secret, 'API Key', '大模型翻译 API Key（Bearer）',
                obscure: true, onChanged: (_) => _save())
          else
            _field(_secret, '密钥', '开发者密钥', obscure: true, onChanged: (_) => _save()),
          const SizedBox(height: 12),
          _field(_endpoint, '接口地址（可留空用默认）', widget.endpointHint,
              onChanged: (_) => _save()),
        ],
      ),
    );
  }
}

class _TencentForm extends ConsumerStatefulWidget {
  const _TencentForm();
  @override
  ConsumerState<_TencentForm> createState() => _TencentFormState();
}

class _TencentFormState extends ConsumerState<_TencentForm> {
  late TextEditingController _id;
  late TextEditingController _key;
  late TextEditingController _region;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(tencentConfigProvider);
    _id = TextEditingController(text: cfg.secretId);
    _key = TextEditingController(text: cfg.secretKey);
    _region = TextEditingController(text: cfg.region);
  }

  @override
  void dispose() {
    _id.dispose();
    _key.dispose();
    _region.dispose();
    super.dispose();
  }

  void _save() {
    final cfg = ref.read(tencentConfigProvider);
    ref.read(tencentConfigProvider.notifier).state = cfg.copyWith(
      secretId: _id.text.trim(),
      secretKey: _key.text.trim(),
      region: _region.text.trim().isEmpty ? 'ap-beijing' : _region.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _field(_id, 'SecretId', '腾讯云 API 密钥 SecretId', onChanged: (_) => _save()),
          const SizedBox(height: 12),
          _field(_key, 'SecretKey', '腾讯云 API 密钥 SecretKey',
              obscure: true, onChanged: (_) => _save()),
          const SizedBox(height: 12),
          _field(_region, '地域 Region', 'ap-beijing', onChanged: (_) => _save()),
        ],
      ),
    );
  }
}

/// 通用文本输入（part 文件内共用）。
Widget _field(
  TextEditingController controller,
  String label,
  String hint, {
  bool obscure = false,
  ValueChanged<String>? onChanged,
}) {
  return TextField(
    controller: controller,
    obscureText: obscure,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
  );
}

/// Whisper 模型与依赖配置区（仅桌面）。
class _WhisperSection extends ConsumerStatefulWidget {
  const _WhisperSection();
  @override
  ConsumerState<_WhisperSection> createState() => _WhisperSectionState();
}

class _WhisperSectionState extends ConsumerState<_WhisperSection> {
  final _manager = WhisperModelManager();
  WhisperModel? _downloading;
  double _progress = 0;

  Future<void> _download(WhisperModel model) async {
    setState(() {
      _downloading = model;
      _progress = 0;
    });
    final mirror = ref.read(whisperMirrorProvider);
    try {
      await _manager.download(model, mirrorBase: mirror,
          onProgress: (received, total, p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${model.displayName} 下载完成')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  Future<void> _delete(WhisperModel model) async {
    await _manager.delete(model);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(whisperEnabledProvider);
    final selected = ref.watch(whisperModelProvider);

    return Column(
      children: [
        SwitchListTile(
          title: const Text('启用 Whisper 本地转写'),
          subtitle: const Text('为无字幕片源边播边生成字幕并翻译（仅 PC，吃 CPU/显卡）'),
          value: enabled,
          onChanged: (v) =>
              ref.read(whisperEnabledProvider.notifier).state = v,
        ),
        if (enabled) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('模型（按需下载，不预置）',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          for (final m in WhisperModel.values)
            _WhisperModelTile(
              model: m,
              manager: _manager,
              selected: selected == m,
              downloading: _downloading == m,
              progress: _downloading == m ? _progress : 0,
              onSelect: () =>
                  ref.read(whisperModelProvider.notifier).state = m,
              onDownload: () => _download(m),
              onDelete: () => _delete(m),
            ),
          const SizedBox(height: 8),
          _WhisperDependencyTile(),
          _WhisperPathFields(),
        ],
      ],
    );
  }
}

/// 依赖检测/安装：ffmpeg 自动检测，缺失可下载；whisper-cli 内置/PATH 检测。
class _WhisperDependencyTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_WhisperDependencyTile> createState() =>
      _WhisperDependencyTileState();
}

class _WhisperDependencyTileState
    extends ConsumerState<_WhisperDependencyTile> {
  final _mgr = DesktopBinaryManager();
  String? _status;
  bool _busy = false;
  double _progress = 0;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _status = '检测中…';
    });
    final ffmpeg =
        await _mgr.resolveFfmpeg(configured: ref.read(ffmpegPathProvider));
    final whisper = await _mgr.resolveWhisper(
        configured: ref.read(whisperBinaryPathProvider));
    if (ffmpeg != null) {
      ref.read(ffmpegPathProvider.notifier).state = ffmpeg;
    }
    if (whisper != null) {
      ref.read(whisperBinaryPathProvider.notifier).state = whisper;
    }
    setState(() {
      _busy = false;
      _status = 'ffmpeg: ${ffmpeg ?? '未找到'}\nwhisper-cli: ${whisper ?? '未找到（应随应用内置）'}';
    });
  }

  Future<void> _downloadFfmpeg() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _status = '下载 ffmpeg…';
    });
    try {
      final path = await _mgr.downloadFfmpeg(onProgress: (r, t, p) {
        if (mounted) setState(() => _progress = p);
      });
      ref.read(ffmpegPathProvider.notifier).state = path;
      setState(() => _status = 'ffmpeg 已安装: $path');
    } catch (e) {
      setState(() => _status = 'ffmpeg 下载失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _check,
                  icon: const Icon(Icons.search),
                  label: const Text('检测依赖'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _downloadFfmpeg,
                  icon: const Icon(Icons.download),
                  label: const Text('下载 ffmpeg'),
                ),
              ),
            ],
          ),
          if (_busy && _progress > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: _progress),
            ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_status!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
        ],
      ),
    );
  }
}

class _WhisperModelTile extends StatelessWidget {
  const _WhisperModelTile({
    required this.model,
    required this.manager,
    required this.selected,
    required this.downloading,
    required this.progress,
    required this.onSelect,
    required this.onDownload,
    required this.onDelete,
  });

  final WhisperModel model;
  final WhisperModelManager manager;
  final bool selected;
  final bool downloading;
  final double progress;
  final VoidCallback onSelect;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: manager.isDownloaded(model),
      builder: (context, snap) {
        final has = snap.data ?? false;
        return ListTile(
          leading: Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(model.displayName),
          subtitle: downloading
              ? LinearProgressIndicator(value: progress > 0 ? progress : null)
              : Text('${model.sizeLabel}${has ? ' · 已下载' : ''}'),
          onTap: has ? onSelect : null,
          trailing: downloading
              ? Text('${(progress * 100).toStringAsFixed(0)}%')
              : has
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: onDelete,
                    )
                  : IconButton(
                      icon: const Icon(Icons.download),
                      onPressed: onDownload,
                    ),
        );
      },
    );
  }
}

class _WhisperPathFields extends ConsumerStatefulWidget {
  @override
  ConsumerState<_WhisperPathFields> createState() => _WhisperPathFieldsState();
}

class _WhisperPathFieldsState extends ConsumerState<_WhisperPathFields> {
  late TextEditingController _binary;
  late TextEditingController _ffmpeg;
  late TextEditingController _mirror;

  @override
  void initState() {
    super.initState();
    _binary = TextEditingController(text: ref.read(whisperBinaryPathProvider));
    _ffmpeg = TextEditingController(text: ref.read(ffmpegPathProvider));
    _mirror = TextEditingController(text: ref.read(whisperMirrorProvider));
  }

  @override
  void dispose() {
    _binary.dispose();
    _ffmpeg.dispose();
    _mirror.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _field(_binary, 'whisper-cli 路径（留空用 PATH）',
              'D:\\whisper\\whisper-cli.exe',
              onChanged: (v) =>
                  ref.read(whisperBinaryPathProvider.notifier).state = v.trim()),
          const SizedBox(height: 12),
          _field(_ffmpeg, 'ffmpeg 路径（留空用 PATH）', 'D:\\ffmpeg\\bin\\ffmpeg.exe',
              onChanged: (v) =>
                  ref.read(ffmpegPathProvider.notifier).state = v.trim()),
          const SizedBox(height: 12),
          _field(_mirror, '模型下载镜像（留空用官方源）',
              'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main',
              onChanged: (v) =>
                  ref.read(whisperMirrorProvider.notifier).state = v.trim()),
        ],
      ),
    );
  }
}
