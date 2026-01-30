import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'emby_api.dart';

typedef DownloadProgressCallback = void Function(
    int receivedBytes, int totalBytes);

enum AppUpdatePlatform {
  windows,
  android,
  macos,
  ios,
  linux,
  other,
}

class AppVersionFull implements Comparable<AppVersionFull> {
  AppVersionFull._(this.parts, this.build, this.raw);

  final List<int> parts;
  final int build;
  final String raw;

  String get version => parts.join('.');
  String get versionFull => '$version+$build';

  static AppVersionFull? tryParse(String raw) {
    final trimmed = raw.trim();
    final match =
        RegExp(r'^v?([0-9]+(?:\.[0-9]+)*)(?:\+([0-9]+))?$').firstMatch(trimmed);
    if (match == null) return null;

    final parts =
        match.group(1)!.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final build = int.tryParse(match.group(2) ?? '') ?? 0;
    return AppVersionFull._(parts, build, trimmed);
  }

  @override
  int compareTo(AppVersionFull other) {
    final maxLen =
        parts.length > other.parts.length ? parts.length : other.parts.length;
    for (var i = 0; i < maxLen; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      final cmp = a.compareTo(b);
      if (cmp != 0) return cmp;
    }
    return build.compareTo(other.build);
  }
}

class GitHubReleaseAsset {
  const GitHubReleaseAsset({
    required this.name,
    required this.browserDownloadUrl,
    required this.size,
    required this.contentType,
  });

  final String name;
  final String browserDownloadUrl;
  final int size;
  final String contentType;

  factory GitHubReleaseAsset.fromJson(Map<String, dynamic> json) {
    return GitHubReleaseAsset(
      name: json['name'] as String? ?? '',
      browserDownloadUrl: json['browser_download_url'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      contentType: json['content_type'] as String? ?? '',
    );
  }
}

class GitHubReleaseInfo {
  const GitHubReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.publishedAt,
    required this.assets,
    required this.versionFull,
  });

  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final DateTime publishedAt;
  final List<GitHubReleaseAsset> assets;
  final String? versionFull;
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.currentVersionFull,
    required this.currentParsed,
    required this.latestVersionFull,
    required this.latestParsed,
    required this.release,
  });

  final String currentVersionFull;
  final AppVersionFull? currentParsed;

  final String? latestVersionFull;
  final AppVersionFull? latestParsed;

  final GitHubReleaseInfo release;

  bool get hasUpdate {
    final current = currentParsed;
    final latest = latestParsed;
    if (current == null || latest == null) return false;
    return latest.compareTo(current) > 0;
  }
}

class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.owner = 'zzzwannasleep',
    this.repo = 'LinPlayer',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String owner;
  final String repo;

  Uri get _latestTagReleaseUri => Uri.parse(
      'https://api.github.com/repos/$owner/$repo/releases/tags/latest');

  Uri get _latestReleaseUri =>
      Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

  static AppUpdatePlatform get currentPlatform {
    if (Platform.isWindows) return AppUpdatePlatform.windows;
    if (Platform.isAndroid) return AppUpdatePlatform.android;
    if (Platform.isMacOS) return AppUpdatePlatform.macos;
    if (Platform.isIOS) return AppUpdatePlatform.ios;
    if (Platform.isLinux) return AppUpdatePlatform.linux;
    return AppUpdatePlatform.other;
  }

  static String? extractVersionFull({
    required String releaseName,
    required String releaseBody,
  }) {
    final bodyMatch = RegExp(
      r'^-\s*Version:\s*([0-9]+(?:\.[0-9]+)*\+[0-9]+)\s*$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(releaseBody);
    final fromBody = bodyMatch?.group(1)?.trim();
    if (fromBody != null && fromBody.isNotEmpty) return fromBody;

    final nameMatch =
        RegExp(r'\(([0-9]+(?:\.[0-9]+)*\+[0-9]+)\)').firstMatch(releaseName);
    return nameMatch?.group(1)?.trim();
  }

  Future<GitHubReleaseInfo> fetchLatestRelease({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      'User-Agent': EmbyApi.userAgent,
    };

    Future<http.Response> get(Uri uri) =>
        _client.get(uri, headers: headers).timeout(timeout);

    http.Response resp = await get(_latestTagReleaseUri);
    if (resp.statusCode == 404) {
      resp = await get(_latestReleaseUri);
    }
    if (resp.statusCode != 200) {
      throw Exception(
        'GitHub API failed: HTTP ${resp.statusCode} ${resp.reasonPhrase ?? ''}',
      );
    }

    final json = jsonDecode(resp.body);
    if (json is! Map) {
      throw Exception('Invalid GitHub API response.');
    }
    final map = json.cast<String, dynamic>();

    final assetsRaw = (map['assets'] as List?) ?? const [];
    final assets = assetsRaw
        .whereType<Map>()
        .map((e) => GitHubReleaseAsset.fromJson(e.cast<String, dynamic>()))
        .where(
            (a) => a.name.trim().isNotEmpty && a.browserDownloadUrl.isNotEmpty)
        .toList();

    final releaseName = map['name'] as String? ?? '';
    final body = map['body'] as String? ?? '';
    final versionFull = extractVersionFull(
      releaseName: releaseName,
      releaseBody: body,
    );

    return GitHubReleaseInfo(
      tagName: map['tag_name'] as String? ?? '',
      name: releaseName,
      body: body,
      htmlUrl: map['html_url'] as String? ?? '',
      publishedAt: DateTime.tryParse(map['published_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      assets: assets,
      versionFull: versionFull,
    );
  }

  static String packageVersionFull(PackageInfo info) {
    final v = info.version.trim();
    final b = info.buildNumber.trim();
    if (v.isEmpty) return '';
    if (b.isEmpty) return v;
    return '$v+$b';
  }

  Future<AppUpdateCheckResult> checkForUpdate({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final pkg = await PackageInfo.fromPlatform();
    final currentVersionFull = packageVersionFull(pkg);
    final currentParsed = AppVersionFull.tryParse(currentVersionFull);

    final release = await fetchLatestRelease(timeout: timeout);
    final latestVersionFull = release.versionFull;
    final latestParsed = latestVersionFull == null
        ? null
        : AppVersionFull.tryParse(latestVersionFull);

    return AppUpdateCheckResult(
      currentVersionFull: currentVersionFull,
      currentParsed: currentParsed,
      latestVersionFull: latestVersionFull,
      latestParsed: latestParsed,
      release: release,
    );
  }

  static List<GitHubReleaseAsset> candidateAssetsForPlatform({
    required AppUpdatePlatform platform,
    required List<GitHubReleaseAsset> assets,
  }) {
    String lower(String s) => s.toLowerCase();

    switch (platform) {
      case AppUpdatePlatform.windows:
        final exe =
            assets.where((a) => lower(a.name).endsWith('.exe')).toList();
        exe.sort(
            (a, b) => _windowsAssetScore(b).compareTo(_windowsAssetScore(a)));
        return exe;

      case AppUpdatePlatform.android:
        final apk =
            assets.where((a) => lower(a.name).endsWith('.apk')).toList();
        apk.sort(
            (a, b) => _androidAssetScore(b).compareTo(_androidAssetScore(a)));
        return apk;

      case AppUpdatePlatform.macos:
        final dmg =
            assets.where((a) => lower(a.name).endsWith('.dmg')).toList();
        dmg.sort((a, b) => _macAssetScore(b).compareTo(_macAssetScore(a)));
        return dmg;

      case AppUpdatePlatform.ios:
        final ipa =
            assets.where((a) => lower(a.name).endsWith('.ipa')).toList();
        return ipa;

      case AppUpdatePlatform.linux:
        final linux = assets
            .where(
              (a) =>
                  lower(a.name).endsWith('.appimage') ||
                  lower(a.name).endsWith('.deb') ||
                  lower(a.name).endsWith('.rpm') ||
                  lower(a.name).endsWith('.tar.gz'),
            )
            .toList();
        linux
            .sort((a, b) => _linuxAssetScore(b).compareTo(_linuxAssetScore(a)));
        return linux;

      case AppUpdatePlatform.other:
        return const [];
    }
  }

  static int _windowsAssetScore(GitHubReleaseAsset a) {
    final name = a.name.toLowerCase();
    var score = 0;
    if (name.contains('linplayer')) score += 10;
    if (name.contains('windows')) score += 10;
    if (name.contains('setup')) score += 20;
    if (name.contains('x64') || name.contains('x86_64')) score += 5;
    return score;
  }

  static int _androidAssetScore(GitHubReleaseAsset a) {
    final name = a.name.toLowerCase();
    var score = 0;
    if (name.contains('linplayer')) score += 10;
    if (name.contains('android')) score += 10;
    if (name == 'linplayer-android.apk') score += 20;
    if (name.contains('universal')) score += 15;
    if (name.contains('arm64') || name.contains('aarch64')) score += 8;
    if (name.contains('armeabi') || name.contains('armv7')) score += 5;
    return score;
  }

  static int _macAssetScore(GitHubReleaseAsset a) {
    final name = a.name.toLowerCase();
    var score = 0;
    if (name.contains('linplayer')) score += 10;
    if (name.contains('macos') || name.contains('mac')) score += 10;
    if (name.contains('arm64')) score += 3;
    return score;
  }

  static int _linuxAssetScore(GitHubReleaseAsset a) {
    final name = a.name.toLowerCase();
    var score = 0;
    if (name.contains('linplayer')) score += 10;
    if (name.contains('linux')) score += 10;
    if (name.contains('x86_64') ||
        name.contains('amd64') ||
        name.contains('x64')) {
      score += 5;
    }
    if (name.endsWith('.appimage')) score += 20;
    if (name.endsWith('.deb')) score += 15;
    if (name.endsWith('.rpm')) score += 15;
    if (name.endsWith('.tar.gz')) score += 5;
    return score;
  }

  Future<File> downloadAssetToTemp(
    GitHubReleaseAsset asset, {
    DownloadProgressCallback? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final request = http.Request('GET', Uri.parse(asset.browserDownloadUrl));
    request.headers['User-Agent'] = EmbyApi.userAgent;
    final streamed = await _client.send(request).timeout(timeout);
    if (streamed.statusCode != 200) {
      throw Exception('Download failed: HTTP ${streamed.statusCode}');
    }

    final total = streamed.contentLength ?? -1;
    final safeName = asset.name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
    final filename = '${DateTime.now().millisecondsSinceEpoch}-$safeName';
    final filePath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}$filename';
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }

    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in streamed.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    return file;
  }

  Future<void> startWindowsInstaller(
    File installer, {
    List<String> arguments = const [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART'
    ],
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows installer is only supported on Windows.');
    }

    try {
      await Process.start(
        installer.path,
        arguments,
        mode: ProcessStartMode.detached,
      );
      return;
    } on ProcessException catch (e) {
      final code = e.errorCode;
      if (code == 740 || code == 5) {
        await _startWindowsInstallerElevated(installer.path, arguments);
        return;
      }
      rethrow;
    }
  }

  Future<void> _startWindowsInstallerElevated(
    String installerPath,
    List<String> arguments,
  ) async {
    final psFilePath = _psQuote(installerPath);
    final psArgs = arguments.map(_psQuote).map((a) => "'$a'").join(',');
    final ps =
        "Start-Process -FilePath '$psFilePath' -ArgumentList @($psArgs) -Verb RunAs";
    await Process.start(
      'powershell',
      ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps],
      runInShell: true,
      mode: ProcessStartMode.detached,
    );
  }

  static String _psQuote(String input) => input.replaceAll("'", "''");
}
