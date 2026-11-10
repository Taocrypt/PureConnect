import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Where an update download comes from: GitHub itself or a GitHub proxy
/// mirror that serves `<mirror>/<full github url>`.
class DownloadSource {
  const DownloadSource.direct()
      : base = null,
        kind = SourceKind.direct;
  const DownloadSource.mirror(String this.base, {this.kind = SourceKind.builtIn});

  /// Mirror prefix without trailing slash; null for direct.
  final String? base;
  final SourceKind kind;

  bool get isDirect => base == null;

  /// Host of the mirror ("gh-proxy.com"), or "direct".
  String get name => base == null ? 'direct' : (Uri.tryParse(base!)?.host ?? base!);

  String urlFor(String githubUrl) => base == null ? githubUrl : mirrorUrl(base!, githubUrl);

  @override
  bool operator ==(Object other) => other is DownloadSource && other.base == base;
  @override
  int get hashCode => base.hashCode;
  @override
  String toString() => name;
}

enum SourceKind { direct, builtIn, user }

/// `auto`: direct when GitHub is reachable, otherwise built-in mirrors.
/// `direct`: never use built-in mirrors (user mirrors still apply).
enum MirrorMode {
  auto,
  direct;

  static MirrorMode parse(String? s) => s == 'direct' ? MirrorMode.direct : MirrorMode.auto;
}

const mirrorListApi = 'https://git.mxg.pub/api/github/list';

/// Used when the mirror list API and the cached list are both unavailable.
const builtInMirrors = [
  'https://gh-proxy.com',
  'https://fastgit.cc',
  'https://ghfile.geekertao.top',
  'https://tvv.tw',
  'https://git.yylx.win',
];

/// `https://gh-proxy.com/` + `https://github.com/...`.
String mirrorUrl(String base, String githubUrl) {
  var b = base.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  return '$b/$githubUrl';
}

/// A user-entered mirror as `scheme://host[:port][/path]` without trailing
/// slash (adds https:// when no scheme is given), or null when it is not a
/// usable http(s) URL.
String? normalizeMirrorUrl(String input) {
  var s = input.trim();
  if (s.isEmpty || s.contains(' ')) return null;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty || !u.host.contains('.') && u.host != 'localhost') {
    return null;
  }
  if (u.hasQuery || u.hasFragment) return null;
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Mirror bases from the mirror list API (`{"data":[{"url":..,"status":"success","latency":19}]}`),
/// only entries reported working, lowest latency first. Bad input gives [].
List<String> parseMirrorList(String body) {
  try {
    final j = jsonDecode(body);
    final data = j is Map ? j['data'] : null;
    if (data is! List) return const [];
    final ok = <(String, num)>[];
    for (final e in data.whereType<Map>()) {
      if (e['status'] != 'success') continue;
      final url = normalizeMirrorUrl('${e['url'] ?? ''}');
      if (url == null || !url.startsWith('https://')) continue;
      final lat = e['latency'] is num ? e['latency'] as num : 1 << 30;
      if (ok.any((x) => x.$1 == url)) continue;
      ok.add((url, lat));
    }
    ok.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final x in ok) x.$1];
  } catch (_) {
    return const [];
  }
}

/// Built-in candidates: the API list (or the cached one) first, then the
/// built-in fallbacks, without duplicates, at most [max].
List<String> mergeMirrorCandidates(List<String> fetched, List<String> cached, {int max = 10}) {
  final out = <String>[];
  for (final m in [...(fetched.isNotEmpty ? fetched : cached), ...builtInMirrors]) {
    if (!out.contains(m)) out.add(m);
  }
  return out.take(max).toList();
}

/// One stage of sources to try in order; when all of them fail the dialog
/// may offer [next] (the built-in mirrors after the user's own failed).
class SourcePlan {
  const SourcePlan(this.sources, {this.userStage = false});
  final List<DownloadSource> sources;

  /// These were the user's mirrors (plus direct): if all fail, offer the
  /// built-in ones (unless [MirrorMode.direct]).
  final bool userStage;
}

/// What to try first. User mirrors in their own order (then direct), else
/// in direct mode just GitHub, else the automatic plan from [autoPlan].
SourcePlan planSources({required MirrorMode mode, required List<String> userMirrors, required List<DownloadSource> Function() auto}) {
  final users = [for (final m in userMirrors) DownloadSource.mirror(m, kind: SourceKind.user)];
  if (users.isNotEmpty) return SourcePlan([...users, const DownloadSource.direct()], userStage: true);
  if (mode == MirrorMode.direct) return const SourcePlan([DownloadSource.direct()]);
  return SourcePlan(auto());
}

/// Automatic order: direct first when it tested fine; otherwise the mirrors
/// that passed the speed test (fastest first), then direct, then mirrors that
/// failed the test (they may just have been slow to answer).
List<DownloadSource> autoPlan({required bool directOk, required List<SpeedResult> mirrorResults}) {
  final good = mirrorResults.where((r) => r.ok).toList()..sort((a, b) => b.bytesPerSecond.compareTo(a.bytesPerSecond));
  final bad = mirrorResults.where((r) => !r.ok);
  return [
    if (directOk) const DownloadSource.direct(),
    for (final r in good) r.source,
    if (!directOk) const DownloadSource.direct(),
    for (final r in bad) r.source,
  ];
}

class SpeedResult {
  const SpeedResult(this.source, {required this.ok, this.bytes = 0, this.elapsed = Duration.zero});
  final DownloadSource source;
  final bool ok;
  final int bytes;
  final Duration elapsed;
  double get bytesPerSecond => elapsed.inMicroseconds <= 0 ? 0 : bytes * 1e6 / elapsed.inMicroseconds;
}

HttpClient _client(Duration timeout) => HttpClient()
  ..connectionTimeout = timeout
  ..userAgent = 'PureConnect-updater';

/// Ranged GET of the first [limit] bytes of [url]. OK when it answers 200/206
/// with a non-HTML body and delivers [limit] bytes (or the whole, smaller,
/// file) within [timeout].
Future<SpeedResult> probeSource(DownloadSource source, String githubUrl,
    {int limit = 64 * 1024, Duration timeout = const Duration(seconds: 5)}) async {
  final client = _client(timeout);
  final sw = Stopwatch()..start();
  var got = 0;
  try {
    Future<bool> run() async {
      final req = await client.getUrl(Uri.parse(source.urlFor(githubUrl)));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${limit - 1}');
      final res = await req.close();
      if (res.statusCode != 200 && res.statusCode != 206) return false;
      if (res.headers.contentType?.mimeType == 'text/html') return false;
      final expected = res.statusCode == 206 || res.contentLength < 0 ? null : res.contentLength;
      final done = Completer<bool>();
      late StreamSubscription<List<int>> sub;
      sub = res.listen((chunk) {
        got += chunk.length;
        if (got >= limit && !done.isCompleted) {
          done.complete(true);
          sub.cancel();
        }
      }, onDone: () {
        if (!done.isCompleted) done.complete(got >= limit || (expected != null && got == expected) || (res.statusCode == 206 && got > 0));
      }, onError: (_) {
        if (!done.isCompleted) done.complete(false);
      }, cancelOnError: true);
      return done.future;
    }

    final ok = await run().timeout(timeout, onTimeout: () => false);
    sw.stop();
    return SpeedResult(source, ok: ok, bytes: got, elapsed: sw.elapsed);
  } catch (_) {
    return SpeedResult(source, ok: false, bytes: got, elapsed: sw.elapsed);
  } finally {
    client.close(force: true);
  }
}

/// Mirror bases from [api] ([] when unreachable or malformed).
Future<List<String>> fetchMirrorList({String api = mirrorListApi, Duration timeout = const Duration(seconds: 6)}) async {
  final client = _client(timeout);
  try {
    Future<List<String>> run() async {
      final req = await client.getUrl(Uri.parse(api));
      final res = await req.close();
      if (res.statusCode != 200) return const <String>[];
      return parseMirrorList(await res.transform(utf8.decoder).join());
    }

    return await run().timeout(timeout, onTimeout: () => const <String>[]);
  } catch (_) {
    return const [];
  } finally {
    client.close(force: true);
  }
}

/// Speed-tests [mirrors] in parallel.
Future<List<SpeedResult>> speedTest(List<String> mirrors, String githubUrl, {Duration timeout = const Duration(seconds: 5)}) =>
    Future.wait([for (final m in mirrors) probeSource(DownloadSource.mirror(m), githubUrl, timeout: timeout)]);
