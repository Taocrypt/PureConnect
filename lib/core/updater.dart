import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// In-app updates from the project's GitHub Releases.
const repoUrl = 'https://github.com/Taocrypt/PureConnect';
const releasesUrl = '$repoUrl/releases';
const latestReleaseApi = 'https://api.github.com/repos/Taocrypt/PureConnect/releases/latest';

const _channel = MethodChannel('zju_connect/core');

/// Version of the running app (pubspec / `--build-name`), e.g. `1.0.0`.
Future<String> currentAppVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return '0.0.0';
  }
}

/// Compares two `x.y.z[-pre][+build]` versions (a leading `v` is ignored).
/// A pre-release sorts before its release. Returns <0, 0 or >0.
int compareVersions(String a, String b) {
  (List<int>, String) parse(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    var pre = '';
    final dash = s.indexOf('-');
    if (dash >= 0) {
      pre = s.substring(dash + 1);
      s = s.substring(0, dash);
    }
    final nums = s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (nums.length < 3) {
      nums.add(0);
    }
    return (nums, pre);
  }

  final (na, pa) = parse(a);
  final (nb, pb) = parse(b);
  for (var i = 0; i < 3; i++) {
    if (na[i] != nb[i]) return na[i].compareTo(nb[i]);
  }
  if (pa == pb) return 0;
  if (pa.isEmpty) return 1;
  if (pb.isEmpty) return -1;
  return pa.compareTo(pb);
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url, this.size);
  final String name;
  final String url;
  final int size;
}

class ReleaseInfo {
  const ReleaseInfo({required this.tag, required this.name, required this.notes, required this.pageUrl, required this.assets});

  final String tag;
  final String name;
  final String notes;
  final String pageUrl;
  final List<ReleaseAsset> assets;

  String get version => tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;

  factory ReleaseInfo.fromJson(Map<String, dynamic> j) => ReleaseInfo(
        tag: j['tag_name'] as String? ?? '',
        name: j['name'] as String? ?? '',
        notes: j['body'] as String? ?? '',
        pageUrl: j['html_url'] as String? ?? releasesUrl,
        assets: [
          for (final a in (j['assets'] as List? ?? const []).whereType<Map>())
            ReleaseAsset(a['name'] as String? ?? '', a['browser_download_url'] as String? ?? '', (a['size'] as num?)?.toInt() ?? 0),
        ],
      );
}

/// Why a check or download failed; [code] is a strings.dart key.
class UpdateException implements Exception {
  const UpdateException(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => detail == null ? code : '$code: $detail';
}

HttpClient _client() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..userAgent = 'PureConnect-updater';

/// Latest published release.
Future<ReleaseInfo> fetchLatestRelease() async {
  final client = _client();
  try {
    final req = await client.getUrl(Uri.parse(latestReleaseApi)).timeout(const Duration(seconds: 20));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    if (res.statusCode == 404) throw const UpdateException('update_no_release');
    if (res.statusCode == 403 || res.statusCode == 429) throw const UpdateException('update_rate_limited');
    if (res.statusCode != 200) throw UpdateException('update_failed', 'HTTP ${res.statusCode}');
    final info = ReleaseInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    if (info.tag.isEmpty) throw const UpdateException('update_failed', 'no tag');
    return info;
  } on UpdateException {
    rethrow;
  } on TimeoutException {
    throw const UpdateException('update_network', 'timeout');
  } on SocketException catch (e) {
    throw UpdateException('update_network', e.message);
  } on HandshakeException catch (e) {
    throw UpdateException('update_network', e.message);
  } on HttpException catch (e) {
    throw UpdateException('update_network', e.message);
  } on FormatException catch (e) {
    throw UpdateException('update_failed', e.message);
  } finally {
    client.close(force: true);
  }
}

/// Supported Android ABIs, most preferred first.
Future<List<String>> androidAbis() async {
  try {
    return (await _channel.invokeMethod<List>('supportedAbis'))?.cast<String>() ?? const [];
  } catch (_) {
    return const [];
  }
}

/// How a desktop Linux build was installed: from the .deb (/opt/pureconnect)
/// or an unpacked tarball.
bool get _linuxFromDeb => p.dirname(Platform.resolvedExecutable) == '/opt/pureconnect';

/// The release asset for this platform, or null when there is none.
/// [os] / [abis] / [debInstall] default to the running system.
ReleaseAsset? pickAsset(ReleaseInfo r, {String? os, List<String> abis = const [], bool? debInstall}) {
  os ??= Platform.operatingSystem;
  ReleaseAsset? find(bool Function(String n) test) {
    for (final a in r.assets) {
      if (test(a.name.toLowerCase())) return a;
    }
    return null;
  }

  switch (os) {
    case 'android':
      for (final abi in abis) {
        final hit = find((n) => n.endsWith('.apk') && n.contains('android-${abi.toLowerCase()}'));
        if (hit != null) return hit;
      }
      return find((n) => n.endsWith('.apk') && n.contains('universal')) ?? find((n) => n.endsWith('.apk'));
    case 'windows':
      return find((n) => n.contains('windows') && n.endsWith('setup.exe')) ?? find((n) => n.contains('windows') && n.endsWith('.zip'));
    case 'macos':
      return find((n) => n.endsWith('.dmg'));
    case 'linux':
      final deb = find((n) => n.endsWith('.deb'));
      final tar = find((n) => n.contains('linux') && n.endsWith('.tar.gz'));
      return (debInstall ?? _linuxFromDeb) ? (deb ?? tar) : (tar ?? deb);
  }
  return null;
}

/// Downloads [asset] into the updates folder, reporting (received, total).
/// Completes with the file; [cancel] aborts it.
Future<File> downloadAsset(ReleaseAsset asset, {void Function(int received, int total)? onProgress, Completer<void>? cancel}) async {
  final dir = await _updatesDir();
  final file = File(p.join(dir.path, asset.name));
  if (asset.size > 0 && await file.exists() && await file.length() == asset.size) {
    onProgress?.call(asset.size, asset.size);
    return file;
  }
  final part = File('${file.path}.part');
  final client = _client();
  cancel?.future.then((_) => client.close(force: true));
  IOSink? sink;
  try {
    final req = await client.getUrl(Uri.parse(asset.url)).timeout(const Duration(seconds: 30));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw UpdateException('update_download_failed', 'HTTP ${res.statusCode}');
    final total = res.contentLength > 0 ? res.contentLength : asset.size;
    sink = part.openWrite();
    var got = 0;
    await for (final chunk in res.timeout(const Duration(seconds: 60))) {
      if (cancel?.isCompleted == true) throw const UpdateException('update_cancelled');
      sink.add(chunk);
      got += chunk.length;
      onProgress?.call(got, total);
    }
    await sink.close();
    sink = null;
    if (total > 0 && got != total) throw const UpdateException('update_download_failed', 'incomplete');
    if (await file.exists()) await file.delete();
    return await part.rename(file.path);
  } catch (e) {
    await sink?.close().catchError((_) {});
    if (await part.exists()) await part.delete().catchError((_) => part);
    if (cancel?.isCompleted == true) throw const UpdateException('update_cancelled');
    if (e is UpdateException) rethrow;
    if (e is TimeoutException) throw const UpdateException('update_network', 'timeout');
    throw UpdateException('update_download_failed', e.toString());
  } finally {
    client.close(force: true);
  }
}

Future<Directory> _updatesDir() async {
  Directory base;
  if (Platform.isAndroid) {
    // Shared with the installer through the FileProvider's cache-path.
    base = await getApplicationCacheDirectory();
  } else {
    base = await getDownloadsDirectory() ?? await getTemporaryDirectory();
  }
  final dir = Platform.isAndroid ? Directory(p.join(base.path, 'updates')) : base;
  await dir.create(recursive: true);
  return dir;
}

/// Hands a downloaded file to the system: the package installer on Android,
/// the installer / disk image / package manager on desktop, else reveals it.
/// Returns 'ok', 'need_permission' (Android: allow installs from this app,
/// then try again) or 'revealed'.
Future<String> openDownloaded(File file) async {
  final path = file.path;
  final name = p.basename(path).toLowerCase();
  if (Platform.isAndroid) {
    final r = await _channel.invokeMethod<String>('installApk', {'path': path});
    return r ?? 'ok';
  }
  if (Platform.isWindows) {
    if (name.endsWith('.exe')) {
      try {
        await Process.start(path, const [], mode: ProcessStartMode.detached);
        return 'ok';
      } catch (_) {
        // Fall through to revealing it in Explorer.
      }
    }
    await Process.start('explorer.exe', ['/select,', path], mode: ProcessStartMode.detached);
    return 'revealed';
  }
  if (Platform.isMacOS) {
    if (name.endsWith('.dmg')) {
      await Process.run('open', [path]);
      return 'ok';
    }
    await Process.run('open', ['-R', path]);
    return 'revealed';
  }
  // Linux: a .deb opens in the software installer; a tarball is revealed.
  if (name.endsWith('.deb')) {
    final r = await Process.run('xdg-open', [path]);
    if (r.exitCode == 0) return 'ok';
  }
  await Process.run('xdg-open', [p.dirname(path)]);
  return 'revealed';
}
