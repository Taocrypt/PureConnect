import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/updater.dart';
import 'package:zju_connect/ui/widgets/update_dialog.dart' show shouldPromptOnLaunch;

/// Local HTTP server standing in for GitHub and the mirrors: `handler`
/// gets the request path (for a mirror: `/https://github.com/...`).
Future<(HttpServer, String)> _server(Future<void> Function(HttpRequest r) handler) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen(handler);
  return (s, 'http://127.0.0.1:${s.port}');
}

void main() {
  const gh = 'https://github.com/Taocrypt/PureConnect/releases/download/v1.0.2/x.apk';

  group('mirror list', () {
    test('parses only working entries, fastest first', () {
      final body = jsonEncode({
        'data': [
          {'name': 'a', 'url': 'https://a.example.com/', 'status': 'success', 'latency': 300},
          {'name': 'b', 'url': 'https://b.example.com', 'status': 'error', 'latency': 5},
          {'name': 'c', 'url': 'https://c.example.com', 'status': 'success', 'latency': 19},
          {'name': 'd', 'url': 'not a url', 'status': 'success', 'latency': 1},
          {'name': 'e', 'url': 'http://plain.example.com', 'status': 'success', 'latency': 2},
          {'name': 'c2', 'url': 'https://c.example.com/', 'status': 'success', 'latency': 50},
        ]
      });
      expect(parseMirrorList(body), ['https://c.example.com', 'https://a.example.com']);
    });

    test('bad input gives an empty list', () {
      expect(parseMirrorList('oops'), isEmpty);
      expect(parseMirrorList('{"data": 3}'), isEmpty);
      expect(parseMirrorList('[]'), isEmpty);
    });

    test('candidates: fetched, else cached, then built-ins, no duplicates', () {
      expect(mergeMirrorCandidates(['https://x.com', 'https://gh-proxy.com'], ['https://old.com']).take(3),
          ['https://x.com', 'https://gh-proxy.com', 'https://fastgit.cc']);
      expect(mergeMirrorCandidates([], ['https://old.com']).first, 'https://old.com');
      expect(mergeMirrorCandidates([], []), builtInMirrors);
    });
  });

  group('URLs', () {
    test('mirror URL is <mirror>/<github url>', () {
      expect(mirrorUrl('https://gh-proxy.com', gh), 'https://gh-proxy.com/$gh');
      expect(mirrorUrl('https://gh-proxy.com//', gh), 'https://gh-proxy.com/$gh');
      expect(const DownloadSource.mirror('https://tvv.tw').urlFor(gh), 'https://tvv.tw/$gh');
      expect(const DownloadSource.direct().urlFor(gh), gh);
      expect(const DownloadSource.mirror('https://tvv.tw').name, 'tvv.tw');
    });

    test('user mirror validation', () {
      expect(normalizeMirrorUrl('gh-proxy.com'), 'https://gh-proxy.com');
      expect(normalizeMirrorUrl(' https://gh-proxy.com/ '), 'https://gh-proxy.com');
      expect(normalizeMirrorUrl('https://my.host/gh'), 'https://my.host/gh');
      expect(normalizeMirrorUrl('ftp://a.com'), isNull);
      expect(normalizeMirrorUrl('https://a.com/?x=1'), isNull);
      expect(normalizeMirrorUrl('nonsense'), isNull);
      expect(normalizeMirrorUrl(''), isNull);
    });
  });

  group('source order', () {
    List<DownloadSource> auto() => const [DownloadSource.mirror('https://auto.com')];

    test('user mirrors first, in order, then direct', () {
      final p = planSources(mode: MirrorMode.auto, userMirrors: ['https://u1.com', 'https://u2.com'], auto: auto);
      expect(p.userStage, isTrue);
      expect(p.sources.map((s) => s.name), ['u1.com', 'u2.com', 'direct']);
      expect(p.sources.first.kind, SourceKind.user);
    });

    test('direct-only never uses built-in mirrors', () {
      final p = planSources(mode: MirrorMode.direct, userMirrors: const [], auto: auto);
      expect(p.sources, [const DownloadSource.direct()]);
      expect(p.userStage, isFalse);
    });

    test('auto uses the automatic plan', () {
      expect(planSources(mode: MirrorMode.auto, userMirrors: const [], auto: auto).sources.single.name, 'auto.com');
    });

    test('auto plan: direct first when reachable, else fastest mirrors, then direct, then failed ones', () {
      const a = DownloadSource.mirror('https://a.com'), b = DownloadSource.mirror('https://b.com'), c = DownloadSource.mirror('https://c.com');
      final results = [
        SpeedResult(a, ok: true, bytes: 65536, elapsed: const Duration(milliseconds: 800)),
        SpeedResult(b, ok: false),
        SpeedResult(c, ok: true, bytes: 65536, elapsed: const Duration(milliseconds: 200)),
      ];
      expect(autoPlan(directOk: false, mirrorResults: results), [c, a, const DownloadSource.direct(), b]);
      expect(autoPlan(directOk: true, mirrorResults: results).first, const DownloadSource.direct());
    });

    test('MirrorMode.parse', () {
      expect(MirrorMode.parse('direct'), MirrorMode.direct);
      expect(MirrorMode.parse(null), MirrorMode.auto);
      expect(MirrorMode.parse('x'), MirrorMode.auto);
    });
  });

  group('network (local mock server)', () {
    final payload = List<int>.generate(200 * 1024, (i) => i % 251);

    test('probe and download fall back to the next source', () async {
      final (server, base) = await _server((r) async {
        final p = r.uri.path;
        if (p.startsWith('/bad/')) {
          r.response.statusCode = 502;
        } else if (p.startsWith('/html/')) {
          r.response.headers.contentType = ContentType.html;
          r.response.write('<html>blocked</html>');
        } else if (p.startsWith('/good/')) {
          r.response.headers.contentLength = payload.length;
          r.response.add(payload);
        }
        await r.response.close();
      });
      addTearDown(() => server.close(force: true));

      final bad = DownloadSource.mirror('$base/bad', kind: SourceKind.user);
      final html = DownloadSource.mirror('$base/html');
      final good = DownloadSource.mirror('$base/good');
      expect((await probeSource(bad, gh)).ok, isFalse);
      expect((await probeSource(html, gh)).ok, isFalse);
      final ok = await probeSource(good, gh);
      expect(ok.ok, isTrue);
      expect(ok.bytes, greaterThanOrEqualTo(64 * 1024));

      final dir = await Directory.systemTemp.createTemp('pc_upd');
      addTearDown(() => dir.delete(recursive: true));
      final used = <String>[];
      final (f, src) = await downloadFromSources(ReleaseAsset('x.apk', gh, payload.length), [bad, html, good],
          dir: dir, onSource: (s) => used.add(s.name));
      expect(src, good);
      expect(used.length, 3);
      expect(await f.readAsBytes(), payload);
    });

    test('all sources failing throws', () async {
      final (server, base) = await _server((r) async {
        r.response.statusCode = 404;
        await r.response.close();
      });
      addTearDown(() => server.close(force: true));
      final dir = await Directory.systemTemp.createTemp('pc_upd');
      addTearDown(() => dir.delete(recursive: true));
      expect(
        downloadFromSources(ReleaseAsset('y.apk', gh, 10), [DownloadSource.mirror('$base/a')], dir: dir),
        throwsA(isA<UpdateException>()),
      );
    });

    test('release info: API blocked -> update.json via mirror', () async {
      final updateJson = jsonEncode({
        'version': '1.0.3',
        'tag': 'v1.0.3',
        'notes': '### 变更\n- x\n\n<!-- min-version: 1.0.2 -->',
        'min_supported_version': '1.0.2',
        'assets': [
          {'name': 'a.apk', 'size': 5, 'url': 'https://github.com/x/a.apk'}
        ],
      });
      final (server, base) = await _server((r) async {
        final p = r.uri.path;
        if (p.startsWith('/api')) {
          r.response.statusCode = 403;
        } else if (p.startsWith('/mirror/')) {
          r.response.headers.contentType = ContentType.json;
          r.response.write(updateJson);
        } else {
          r.response.statusCode = 500;
        }
        await r.response.close();
      });
      addTearDown(() => server.close(force: true));
      final updUrl = '$base/direct/update.json';

      // Built-in mirrors (auto mode).
      final r = await fetchRelease(
        mode: MirrorMode.auto,
        userMirrors: const [],
        candidates: () async => ['$base/dead', '$base/mirror'],
        api: '$base/api',
        updateJsonUrl: updUrl,
      );
      expect(r.tag, 'v1.0.3');
      expect(r.minSupportedVersion, '1.0.2');
      expect(r.notes, isNot(contains('min-version')));
      expect(r.assets.single.url, 'https://github.com/x/a.apk');

      // User mirror first.
      final u = await fetchRelease(
        mode: MirrorMode.direct,
        userMirrors: ['$base/mirror'],
        candidates: () async => fail('built-ins must not be used'),
        api: '$base/api',
        updateJsonUrl: updUrl,
      );
      expect(u.version, '1.0.3');

      // Direct-only: no mirrors at all.
      await expectLater(
        fetchRelease(
          mode: MirrorMode.direct,
          userMirrors: const [],
          candidates: () async => fail('built-ins must not be used'),
          api: '$base/api',
          updateJsonUrl: updUrl,
        ),
        throwsA(isA<UpdateException>()),
      );

      // User mirrors failed, built-ins not allowed yet -> asks.
      await expectLater(
        fetchRelease(
          mode: MirrorMode.auto,
          userMirrors: ['$base/dead'],
          candidates: () async => ['$base/mirror'],
          allowBuiltIn: false,
          api: '$base/api',
          updateJsonUrl: updUrl,
        ),
        throwsA(isA<UpdateException>().having((e) => e.code, 'code', 'update_user_mirrors_failed')),
      );
    });
  });

  group('forced update', () {
    test('min-version markers', () {
      expect(parseMinVersion('### 变更\n- a\n最低支持版本: 1.0.2\n'), '1.0.2');
      expect(parseMinVersion('最低支持版本：v1.1.0'), '1.1.0');
      expect(parseMinVersion('- a\n<!-- min-version: 2.0.0 -->'), '2.0.0');
      expect(parseMinVersion('min-version: 1.0.0-beta.1'), '1.0.0-beta.1');
      expect(parseMinVersion('- 修复最低支持版本的显示'), isNull);
      expect(parseMinVersion(''), isNull);
      expect(stripMinVersionMarker('- a\n\n<!-- min-version: 2.0.0 -->\n'), '- a');
    });

    test('comparison', () {
      expect(isForcedUpdate('1.0.1', '1.0.2'), isTrue);
      expect(isForcedUpdate('1.0.2', '1.0.2'), isFalse);
      expect(isForcedUpdate('1.1.0', '1.0.2'), isFalse);
      expect(isForcedUpdate('1.0.2-beta', '1.0.2'), isTrue);
      expect(isForcedUpdate('1.0.0', null), isFalse);
      expect(isForcedUpdate('1.0.0', ''), isFalse);
    });

    test('API release body carries the marker', () {
      final r = ReleaseInfo.fromJson({
        'tag_name': 'v1.0.3',
        'body': '- x\n\n<!-- min-version: 1.0.2 -->',
        'assets': const [],
      });
      expect(r.minSupportedVersion, '1.0.2');
      expect(r.forces('1.0.1'), isTrue);
      expect(r.forces('1.0.2'), isFalse);
      expect(r.notes, '- x');
    });
  });

  group('launch check', () {
    test('a forced update is shown even with auto-check off', () {
      expect(shouldPromptOnLaunch(autoEnabled: false, current: '1.0.1', latest: '1.0.4', minSupported: '1.0.2'), isTrue);
      expect(shouldPromptOnLaunch(autoEnabled: true, current: '1.0.1', latest: '1.0.4', minSupported: '1.0.2'), isTrue);
    });

    test('a normal update is not shown with auto-check off', () {
      expect(shouldPromptOnLaunch(autoEnabled: false, current: '1.0.3', latest: '1.0.4'), isFalse);
      expect(shouldPromptOnLaunch(autoEnabled: false, current: '1.0.3', latest: '1.0.4', minSupported: '1.0.2'), isFalse);
      expect(shouldPromptOnLaunch(autoEnabled: false, current: '1.0.3', latest: '1.0.4', minSupported: ''), isFalse);
    });

    test('a normal update is shown with auto-check on', () {
      expect(shouldPromptOnLaunch(autoEnabled: true, current: '1.0.3', latest: '1.0.4'), isTrue);
    });

    test('nothing newer, nothing shown', () {
      expect(shouldPromptOnLaunch(autoEnabled: true, current: '1.0.4', latest: '1.0.4'), isFalse);
      expect(shouldPromptOnLaunch(autoEnabled: false, current: '1.0.4', latest: '1.0.3', minSupported: '1.0.5'), isFalse);
    });
  });
}
