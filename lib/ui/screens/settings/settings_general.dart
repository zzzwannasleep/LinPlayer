part of 'settings_screen.dart';

class GeneralSettingsScreen extends ConsumerStatefulWidget {
  const GeneralSettingsScreen({super.key});

  @override
  ConsumerState<GeneralSettingsScreen> createState() =>
      _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends ConsumerState<GeneralSettingsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      _loadCacheSettings();
      ref.read(cacheSizeProvider);
    });
  }

  Future<void> _loadCacheSettings() async {
    final expiryDays = await CacheService.getImageCacheExpiryDays();
    final maxSizeMB = await CacheService.getVideoCacheMaxSizeMB();
    if (mounted) {
      ref.read(imageCacheExpiryDaysProvider.notifier).state = expiryDays;
      ref.read(videoCacheMaxSizeMBProvider.notifier).state = maxSizeMB;
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final startupPage = ref.watch(startupPageProvider);
    final hideDailyRecommendations =
        ref.watch(hideDailyRecommendationsProvider);
    final imageExpiryDays = ref.watch(imageCacheExpiryDaysProvider);
    final videoMaxSizeMB = ref.watch(videoCacheMaxSizeMBProvider);
    final cacheSizeAsync = ref.watch(cacheSizeProvider);
    final displayLocale = locale ?? Localizations.localeOf(context);

    return Scaffold(
      appBar: AppBar(title: const Text('通用设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          ListTile(
            title: const Text('外观'),
            subtitle: Text(localizedThemeModeLabel(themeMode,
                displayLocale: displayLocale)),
            onTap: () => _showThemeSelector(context),
          ),
          ListTile(
            title: const Text('语言'),
            subtitle: Text(
                localizedLocaleLabel(locale, displayLocale: displayLocale)),
            onTap: () => _showLanguageSelector(context),
          ),
          ListTile(
            title: const Text('启动页'),
            subtitle: Text(
                startupPageLabel(startupPage, displayLocale: displayLocale)),
            onTap: () => _showStartupPageSelector(context),
          ),
          Builder(builder: (context) {
            final fontPath = ref.watch(customAppFontPathProvider);
            return ListTile(
              title: const Text('应用字体'),
              subtitle: Text(
                fontPath.isEmpty
                    ? '默认字体 · 点击导入字体文件 (ttf/otf)'
                    : '${p.basename(fontPath)} · 切换字体后重启生效',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: fontPath.isEmpty
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      tooltip: '恢复默认',
                      icon: const Icon(Icons.clear),
                      onPressed: () async {
                        await FontService.clearAppFont();
                        ref.read(customAppFontPathProvider.notifier).state = '';
                      },
                    ),
              onTap: () => _importCustomFont(context, ref, isApp: true),
            );
          }),
          SwitchListTile(
            title: const Text('隐藏每日推荐'),
            subtitle: const Text('开启后只隐藏每日推荐，继续观看仍会保留'),
            value: hideDailyRecommendations,
            onChanged: (value) => ref
                .read(hideDailyRecommendationsProvider.notifier)
                .state = value,
          ),
          SwitchListTile(
            title: const Text('使用视频背景'),
            subtitle: const Text('开启后在详情页使用预告片视频作为背景（如可用），关闭则使用封面图'),
            value: ref.watch(useVideoBackgroundProvider),
            onChanged: (value) => ref
                .read(useVideoBackgroundProvider.notifier)
                .state = value,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '缓存管理',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          ListTile(
            title: const Text('图片缓存'),
            subtitle: cacheSizeAsync.when(
              data: (info) => Text(
                  '已用 ${info.imageFormatted} / 上限 6 GB，$imageExpiryDays 天后过期'),
              loading: () => const Text('计算中...'),
              error: (_, __) => const Text('获取失败'),
            ),
            trailing: TextButton(
              onPressed: () => _clearImageCache(context),
              child: const Text('清除'),
            ),
          ),
          ListTile(
            title: const Text('图片缓存过期天数'),
            subtitle: Text('$imageExpiryDays 天（超 6GB 时自动清理最旧）'),
            onTap: () => _showImageCacheExpirySelector(context),
          ),
          ListTile(
            title: const Text('视频播放缓存'),
            subtitle: cacheSizeAsync.when(
              data: (info) => Text(
                '已用 ${info.videoFormatted}，上限 ${CacheService.formatSizeMB(videoMaxSizeMB)}（缓存到磁盘，不占内存）',
              ),
              loading: () => const Text('计算中...'),
              error: (_, __) => const Text('获取失败'),
            ),
            trailing: TextButton(
              onPressed: () => _clearVideoCache(context),
              child: const Text('清除'),
            ),
          ),
          ListTile(
            title: const Text('视频播放缓存上限'),
            subtitle: Text(
                '${CacheService.formatSizeMB(videoMaxSizeMB)}（300MB – 8GB，越大越流畅但占磁盘越多）'),
            onTap: () => _showVideoCacheMaxSizeSelector(context),
          ),
          ListTile(
            title: const Text('总缓存'),
            subtitle: cacheSizeAsync.when(
              data: (info) => Text(info.totalFormatted),
              loading: () => const Text('计算中...'),
              error: (_, __) => const Text('获取失败'),
            ),
            trailing: TextButton(
              onPressed: () => _clearAllCache(context),
              child: const Text('全部清除'),
            ),
          ),
          const Divider(),
          ListTile(
            title: const Text('聚合搜索优先级'),
            subtitle: const Text('服务器名称优先'),
            onTap: () => _showSearchPrioritySelector(context),
          ),
        ],
      ),
    );
  }

  Future<void> _clearImageCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除图片缓存'),
        content: const Text('确定清除所有图片磁盘缓存？下次加载需重新下载。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清除')),
        ],
      ),
    );
    if (confirmed == true) {
      await CacheService.clearAllImageCache();
      if (!mounted) return;
      ref.invalidate(cacheSizeProvider);
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('图片缓存已清除')),
      );
    }
  }

  Future<void> _clearVideoCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除视频播放缓存'),
        content: const Text('确定清除视频播放的磁盘缓存？只影响临时播放缓冲，不影响已下载的影片。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清除')),
        ],
      ),
    );
    if (confirmed == true) {
      await CacheService.clearVideoCache();
      if (!mounted) return;
      ref.invalidate(cacheSizeProvider);
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('视频缓存已清除')),
      );
    }
  }

  Future<void> _clearAllCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部缓存'),
        content: const Text('确定清除所有图片和视频缓存？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('全部清除')),
        ],
      ),
    );
    if (confirmed == true) {
      await CacheService.clearAllCache();
      if (!mounted) return;
      ref.invalidate(cacheSizeProvider);
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('所有缓存已清除')),
      );
    }
  }

  void _showImageCacheExpirySelector(BuildContext context) {
    final days = [7, 14, 30, 60, 90];
    final current = ref.read(imageCacheExpiryDaysProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('图片缓存过期天数'),
        content: RadioGroup<int>(
          groupValue: current,
          onChanged: (value) async {
            if (value != null) {
              ref.read(imageCacheExpiryDaysProvider.notifier).state = value;
              await CacheService.setImageCacheExpiryDays(value);
            }
            if (ctx.mounted) {
              Navigator.pop(ctx);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: days
                .map((d) => RadioListTile<int>(
                      title: Text('$d 天'),
                      value: d,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showVideoCacheMaxSizeSelector(BuildContext context) {
    const minMB = CacheService.videoCacheMinMB; // 300
    const maxMB = CacheService.videoCacheMaxMB; // 8192
    var value = ref
        .read(videoCacheMaxSizeMBProvider)
        .clamp(minMB, maxMB)
        .toDouble();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('视频播放缓存上限'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                CacheService.formatSizeMB(value.round()),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Slider(
                min: minMB.toDouble(),
                max: maxMB.toDouble(),
                // 约 100MB 一档
                divisions: ((maxMB - minMB) / 100).round(),
                value: value,
                label: CacheService.formatSizeMB(value.round()),
                onChanged: (v) => setLocal(() => value = v),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '缓存写入磁盘（不占内存）。越大缓冲越多、拖动/弱网更稳，但占用磁盘越多。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final mb = value.round();
                ref.read(videoCacheMaxSizeMBProvider.notifier).state = mb;
                await CacheService.setVideoCacheMaxSizeMB(mb);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _showLanguageSelector(BuildContext context) {
    final current = ref.read(localeProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('语言'),
        content: RadioGroup<String>(
          groupValue: current?.toLanguageTag().replaceAll('-', '_') ?? 'system',
          onChanged: (value) {
            if (value == null) {
              Navigator.pop(context);
              return;
            }
            ref.read(localeProvider.notifier).state = switch (value) {
              'zh_CN' => const Locale('zh', 'CN'),
              'en' => const Locale('en'),
              _ => null,
            };
            Navigator.pop(context);
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text('跟随系统'),
                value: 'system',
              ),
              RadioListTile<String>(
                title: Text('简体中文'),
                value: 'zh_CN',
              ),
              RadioListTile<String>(
                title: Text('English'),
                value: 'en',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showStartupPageSelector(BuildContext context) {
    final current = ref.read(startupPageProvider);
    final displayLocale =
        ref.read(localeProvider) ?? Localizations.localeOf(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动页'),
        content: RadioGroup<StartupPageOption>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(startupPageProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<StartupPageOption>(
                title: Text(startupPageLabel(StartupPageOption.home,
                    displayLocale: displayLocale)),
                value: StartupPageOption.home,
              ),
              RadioListTile<StartupPageOption>(
                title: Text(startupPageLabel(StartupPageOption.servers,
                    displayLocale: displayLocale)),
                value: StartupPageOption.servers,
              ),
              RadioListTile<StartupPageOption>(
                title: Text(startupPageLabel(StartupPageOption.resume,
                    displayLocale: displayLocale)),
                value: StartupPageOption.resume,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSearchPrioritySelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('聚合搜索优先级'),
        content: RadioGroup<String>(
          groupValue: 'name',
          onChanged: (_) => Navigator.pop(context),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text('服务器名称优先'),
                value: 'name',
              ),
              RadioListTile<String>(
                title: Text('响应速度优先'),
                value: 'speed',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showThemeSelector(BuildContext context) {
    final current = ref.read(themeModeProvider);
    final displayLocale =
        ref.read(localeProvider) ?? Localizations.localeOf(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('外观'),
        content: RadioGroup<ThemeModeOption>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(themeModeProvider.notifier).state = value;
            }
            Navigator.pop(context);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: ThemeModeOption.values
                .map((mode) => RadioListTile<ThemeModeOption>(
                      title: Text(localizedThemeModeLabel(mode,
                          displayLocale: displayLocale)),
                      value: mode,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }
}

/// 播放器设置页
