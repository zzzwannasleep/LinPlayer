part of 'settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      // 底部预留浮动 TabBar 的高度（MainShell 已把它注入 MediaQuery.padding.bottom）。
      // ListView 显式设置 padding 会忽略 MediaQuery 内边距，故需手动叠加，
      // 否则最后一张卡片会被底部 Tab 挡住。
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _SettingsCard(
            icon: Icons.palette,
            title: '通用设置',
            subtitle: '外观、语言、启动页等',
            onTap: () => _showGeneralSettings(context),
          ),
          _SettingsCard(
            icon: Icons.play_circle,
            title: '播放器设置',
            subtitle: '内核、手势、播放行为等',
            onTap: () => _showPlayerSettings(context),
          ),
          _SettingsCard(
            icon: Icons.chat_bubble,
            title: '弹幕设置',
            subtitle: '外观、屏蔽词、延迟等',
            onTap: () => _showDanmakuSettings(context),
          ),
          _SettingsCard(
            icon: Icons.translate,
            title: '字幕翻译',
            subtitle: 'AI / 百度 / 腾讯翻译，Whisper 本地转写',
            onTap: () => _showTranslationSettings(context),
          ),
          _SettingsCard(
            icon: Icons.vpn_key,
            title: '代理设置',
            subtitle: 'HTTP(S) / SOCKS 自定义代理',
            onTap: () => _showNetworkSettings(context),
          ),
          _SettingsCard(
            icon: Icons.sync,
            title: '同步服务',
            subtitle: 'Trakt、Bangumi 观看记录同步',
            onTap: () => _showSyncSettings(context),
          ),
          _SettingsCard(
            icon: Icons.extension,
            title: '插件',
            subtitle: '安装、启用/禁用第三方插件',
            onTap: () => _showPlugins(context),
          ),
          _SettingsCard(
            icon: Icons.system_update,
            title: '检查更新',
            subtitle: '当前 $kCurrentAppVersion · 每 24 小时自动检查',
            onTap: () => _checkUpdate(context, ref),
          ),
          _SettingsCard(
            icon: Icons.info,
            title: '关于',
            subtitle: '版本、开源许可、致谢',
            onTap: () => _showAbout(context),
          ),
          _SettingsCard(
            icon: Icons.backup,
            title: '备份与恢复',
            subtitle: '导出/导入服务器配置、WebDAV同步',
            onTap: () => _showBackupRestore(context),
          ),
          // 线路同步已移至各服务器的线路管理页面
        ],
      ),
    );
  }

  void _showGeneralSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const GeneralSettingsScreen()),
    );
  }

  void _showPlayerSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PlayerSettingsScreen()),
    );
  }

  void _showDanmakuSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const DanmakuSettingsScreen()),
    );
  }

  void _showNetworkSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const NetworkSettingsScreen()),
    );
  }

  void _showSyncSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SyncSettingsScreen()),
    );
  }

  void _showTranslationSettings(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const TranslationSettingsScreen()),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关于'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('LinPlayer v$kCurrentAppVersion'),
            SizedBox(height: 8),
            Text('GitHub: https://github.com/your-repo'),
            SizedBox(height: 8),
            Text('mpv version: 0.37.0'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _exportLogs(context);
            },
            child: const Text('导出日志'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs(BuildContext context) async {
    try {
      final path = await AppLogger().exportToFile();
      final livePath = AppLogger().logFilePath;
      await Clipboard.setData(ClipboardData(text: path));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text(
              '日志已导出（路径已复制）:\n$path'
              '${livePath != null ? '\n实时日志文件: $livePath' : ''}',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出日志失败: $e')),
        );
      }
    }
  }

  void _showBackupRestore(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const BackupRestoreScreen()),
    );
  }

  void _showPlugins(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const PluginManagementScreen()),
    );
  }

  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在检查更新…')));
    final includePre = ref.read(updateIncludePrereleaseProvider);
    final info = await ref
        .read(appUpdateServiceProvider)
        .checkForUpdate(includePrerelease: includePre);
    if (!context.mounted) return;
    if (info == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('已是最新版本（$kCurrentAppVersion）')),
      );
    } else {
      ref.read(availableUpdateProvider.notifier).state = info;
      await showUpdateDialog(context, info);
    }
  }
}

/// 设置卡片
class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF5B8DEF).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFF5B8DEF)),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// 通用设置页
