import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_logger.dart';

/// Windows「原地覆盖更新」器。
///
/// 思路：运行中的 `LinPlayer.exe` 无法替换自身，所以把活儿交给一个**脱离进程**的
/// PowerShell 脚本——它等当前进程退出后，把下载好的发布包解压覆盖到安装目录，
/// 再重新拉起程序。
///
/// **不动用户数据**：用户数据（SharedPreferences / 应用支持目录 / 缓存）都在
/// `%APPDATA%` / `getApplicationSupportDirectory()` 等系统目录，与安装目录分离；
/// 本更新只覆盖安装目录内的程序文件，不触碰任何用户数据。
class WindowsSelfUpdater {
  WindowsSelfUpdater._();

  static final _logger = AppLogger();
  static const _tag = 'WinSelfUpdate';

  /// 用下载好的发布 zip（[zipPath]）原地覆盖更新并在更新后重启程序。
  ///
  /// 成功返回 true（随后调用方应尽快退出程序，让脚本接管覆盖）；失败返回 false。
  static Future<bool> applyAndRelaunch(String zipPath) async {
    if (!Platform.isWindows) return false;
    try {
      final exePath = Platform.resolvedExecutable;
      final installDir = p.dirname(exePath);
      final myPid = pid;

      final tmp = await getTemporaryDirectory();
      final staging =
          p.join(tmp.path, 'linplayer_update_${DateTime.now().millisecondsSinceEpoch}');
      final scriptPath = p.join(tmp.path, 'linplayer_update.ps1');
      final logPath = p.join(tmp.path, 'linplayer_update.log');

      final script = _buildScript(
        pid: myPid,
        zipPath: zipPath,
        staging: staging,
        installDir: installDir,
        exePath: exePath,
        logPath: logPath,
      );
      await File(scriptPath).writeAsString(script);

      // 脱离父进程运行：父进程（本程序）退出后脚本继续执行覆盖。
      await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          scriptPath,
        ],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      _logger.i(_tag, '已启动覆盖更新脚本，准备退出程序交接：$scriptPath');
      return true;
    } catch (e, st) {
      _logger.eWithStack(_tag, '启动覆盖更新脚本失败', e, st);
      return false;
    }
  }

  /// PowerShell 单引号字符串转义：把内部单引号翻倍。
  static String _ps(String raw) => raw.replaceAll("'", "''");

  static String _buildScript({
    required int pid,
    required String zipPath,
    required String staging,
    required String installDir,
    required String exePath,
    required String logPath,
  }) {
    // 全部值用 PowerShell 单引号字面量包裹，避免路径中空格/特殊字符被解释。
    return '''
\$ErrorActionPreference = 'Stop'
\$log = '${_ps(logPath)}'
function Log(\$m) { try { Add-Content -LiteralPath \$log -Value ("[" + (Get-Date -Format o) + "] " + \$m) } catch {} }

\$pid_       = $pid
\$zip        = '${_ps(zipPath)}'
\$staging    = '${_ps(staging)}'
\$installDir = '${_ps(installDir)}'
\$exe        = '${_ps(exePath)}'

Log "更新开始 pid=\$pid_ zip=\$zip install=\$installDir"

# 1) 等当前程序退出（最多 60s），释放对 exe/dll 的文件锁。
try {
  \$proc = Get-Process -Id \$pid_ -ErrorAction SilentlyContinue
  if (\$proc) { Wait-Process -Id \$pid_ -Timeout 60 -ErrorAction SilentlyContinue }
} catch { Log "等待退出异常(忽略): \$_" }
Start-Sleep -Milliseconds 800

# 2) 解压发布包到暂存目录。
try {
  if (Test-Path -LiteralPath \$staging) { Remove-Item -LiteralPath \$staging -Recurse -Force }
  New-Item -ItemType Directory -Force -Path \$staging | Out-Null
  Expand-Archive -LiteralPath \$zip -DestinationPath \$staging -Force
  Log "解压完成 -> \$staging"
} catch {
  Log "解压失败: \$_"
  # 解压失败：直接拉起旧程序，避免把用户卡在没程序可用的状态。
  Start-Process -FilePath \$exe -WorkingDirectory \$installDir
  exit 1
}

# 有些打包会多嵌一层目录；若暂存目录下只有单个文件夹且无 exe，则下钻一层。
\$src = \$staging
\$exeName = Split-Path \$exe -Leaf
if (-not (Test-Path -LiteralPath (Join-Path \$src \$exeName))) {
  \$sub = Get-ChildItem -LiteralPath \$src -Directory
  if (\$sub.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path \$sub[0].FullName \$exeName))) {
    \$src = \$sub[0].FullName
    Log "下钻一层取真实根: \$src"
  }
}

# 3) 覆盖安装目录（只动程序文件；用户数据在 %APPDATA% 等处，不受影响）。
\$ok = \$true
try {
  Copy-Item -Path (Join-Path \$src '*') -Destination \$installDir -Recurse -Force
  Log "覆盖完成"
} catch {
  \$ok = \$false
  Log "覆盖失败: \$_"
}

# 4) 重新拉起程序。
try {
  Start-Process -FilePath \$exe -WorkingDirectory \$installDir
  Log "已重启程序"
} catch { Log "重启失败: \$_" }

# 5) 清理暂存（zip 与脚本本身留给系统临时目录自然回收，避免自删竞态）。
try { if (Test-Path -LiteralPath \$staging) { Remove-Item -LiteralPath \$staging -Recurse -Force } } catch {}
try { if (Test-Path -LiteralPath \$zip) { Remove-Item -LiteralPath \$zip -Force } } catch {}

Log "更新结束 ok=\$ok"
''';
  }
}
