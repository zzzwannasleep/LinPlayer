import 'dart:io';

Future<bool> launchExternalMpv({
  String? executablePath,
  required String source,
  Map<String, String>? httpHeaders,
}) async {
  final specified = executablePath?.trim();
  final mpv = (specified != null && specified.isNotEmpty) ? specified : 'mpv';

  final args = <String>[
    '--vo=gpu-next',
    '--hwdec=no',
    '--target-colorspace-hint=yes',
  ];

  if (httpHeaders != null && httpHeaders.isNotEmpty) {
    final headerFields = httpHeaders.entries
        .map((e) => '${e.key.trim()}: ${e.value}')
        .where((s) => s.trim() != ':')
        .join(',');
    if (headerFields.trim().isNotEmpty) {
      args.add('--http-header-fields=$headerFields');
    }
  }

  args.add(source);

  Future<bool> tryStart(String executable) async {
    try {
      await Process.start(
        executable,
        args,
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  if (await tryStart(mpv)) return true;
  // Common Windows name when not in PATH.
  if (mpv != 'mpv.exe' && await tryStart('mpv.exe')) return true;
  // Try alongside the running executable (useful for bundled distributions).
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final adjacent = '$exeDir${Platform.pathSeparator}mpv.exe';
  if (mpv != adjacent && await tryStart(adjacent)) return true;
  return false;
}
