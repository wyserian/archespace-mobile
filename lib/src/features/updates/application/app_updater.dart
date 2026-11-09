import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:archespace_mobile/src/shared/config/build_info.dart';

/// A newer GitHub release: the APK that fits this phone and its checksum file.
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.apkName,
    required this.apkUrl,
    required this.shaUrl,
    required this.size,
  });

  /// Without the leading "v".
  final String version;
  final String apkName;
  final Uri apkUrl;
  final Uri shaUrl;

  /// In bytes, as GitHub reports it.
  final int size;
}

/// An update failure with a message to show as is.
class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
}

/// The download was cancelled.
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// Whether version [a] is newer than [b] (x.y.z, an optional leading "v").
bool isNewerVersion(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp('^v'), '')
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d > 0;
  }
  return false;
}

/// The update in GitHub's latest-release [json], or null when it isn't newer
/// than [current] or lacks an APK with its .sha256. Takes the smaller arm64
/// APK on an [arm64] phone (when the release has one), else the universal.
UpdateRelease? newerRelease(
  Map<String, dynamic> json, {
  required String current,
  required bool arm64,
}) {
  final tag = json['tag_name'] as String? ?? '';
  if (!isNewerVersion(tag, current)) return null;
  final assets = {
    for (final a in (json['assets'] as List? ?? const []))
      (a as Map<String, dynamic>)['name'] as String: a,
  };
  final apks = assets.keys.where((n) => n.endsWith('.apk'));
  final apk =
      (arm64
          ? apks.where((n) => n.endsWith('-arm64.apk')).firstOrNull
          : null) ??
      apks.where((n) => !n.endsWith('-arm64.apk')).firstOrNull;
  final sha = apk == null ? null : assets['$apk.sha256'];
  if (apk == null || sha == null) return null;
  return UpdateRelease(
    version: tag.replaceFirst(RegExp('^v'), ''),
    apkName: apk,
    apkUrl: Uri.parse(assets[apk]!['browser_download_url'] as String),
    shaUrl: Uri.parse(sha['browser_download_url'] as String),
    size: (assets[apk]!['size'] as num?)?.toInt() ?? 0,
  );
}

/// In-app updates from the repo's GitHub releases (Android only: iOS apps
/// come from the App Store). Finds a newer release, downloads the APK, checks
/// it against the release's SHA-256, and hands it to Android's installer,
/// which also checks it's signed with the same key as the installed app.
class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static const MethodChannel _channel = MethodChannel('archespace/updates');
  static const String _autoKey = 'update_auto_check';
  static const String _lastCheckKey = 'update_last_check';

  /// Release builds on Android: a dev build has no real version to compare.
  static bool get supported => Platform.isAndroid && BuildInfo.isStamped;

  /// Whether to check once a day on its own (Settings > About).
  final ValueNotifier<bool> autoCheck = ValueNotifier<bool>(true);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    autoCheck.value = prefs.getBool(_autoKey) ?? true;
  }

  Future<void> setAutoCheck(bool on) async {
    autoCheck.value = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoKey, on);
  }

  /// The newest release when it's newer than this build, else null. Throws
  /// when GitHub can't be reached.
  Future<UpdateRelease?> check() async {
    final abi = await _channel.invokeMethod<String>('abi');
    final api = BuildInfo.repoUrl.replaceFirst(
      'https://github.com/',
      'https://api.github.com/repos/',
    );
    final body = await _get(Uri.parse('$api/releases/latest'));
    return newerRelease(
      jsonDecode(body) as Map<String, dynamic>,
      current: BuildInfo.appVersion,
      arm64: abi == 'arm64-v8a',
    );
  }

  /// [check], at most once a day and only while [autoCheck] is on; quiet
  /// (null) on any failure.
  Future<UpdateRelease?> dailyCheck() async {
    if (!supported || !autoCheck.value) return null;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt(_lastCheckKey) ?? 0;
    if (now - last < Duration.millisecondsPerDay) return null;
    await prefs.setInt(_lastCheckKey, now);
    try {
      return await check();
    } catch (_) {
      return null;
    }
  }

  /// Downloads [release]'s APK into the cache (replacing any earlier one) and
  /// returns it once it matches the release's SHA-256. [onProgress] gets
  /// 0..1; [isCancelled] stops it with [UpdateCancelled].
  Future<File> download(
    UpdateRelease release, {
    required ValueChanged<double> onProgress,
    required bool Function() isCancelled,
  }) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    // "<hex>  <file name>", as sha256sum writes it.
    final expected = (await _get(
      release.shaUrl,
    )).trim().split(RegExp(r'\s+')).first.toLowerCase();

    final file = File('${dir.path}/${release.apkName}');
    final hashSink = Sha256().newHashSink();
    final client = HttpClient()..userAgent = 'ArcheSpace-mobile';
    try {
      final response = await (await client.getUrl(release.apkUrl)).close();
      if (response.statusCode != HttpStatus.ok) {
        throw const UpdateException("Couldn't download the update.");
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : release.size;
      final out = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          if (isCancelled()) throw const UpdateCancelled();
          out.add(chunk);
          hashSink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress(received / total);
        }
      } finally {
        await out.close();
      }
    } finally {
      client.close(force: true);
    }

    hashSink.close();
    final hex = (await hashSink.hash()).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (hex != expected) {
      await file.delete();
      throw const UpdateException(
        "The download didn't match the release's checksum, so it wasn't "
        'installed. Try again.',
      );
    }
    return file;
  }

  /// Whether Android lets this app install APKs ("Install unknown apps").
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  /// Opens this app's "Install unknown apps" page in Android's settings.
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  /// Opens Android's installer on [apk]; the user confirms there.
  Future<void> install(File apk) =>
      _channel.invokeMethod<void>('install', {'path': apk.path});

  static Future<String> _get(Uri url) async {
    final client = HttpClient()
      ..userAgent = 'ArcheSpace-mobile'
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(url);
      if (url.host == 'api.github.com') {
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub answered ${response.statusCode}', uri: url);
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }
}
