import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/backup.dart';

/// Tiny in-memory WebDAV server requiring Basic auth.
Future<(HttpServer, Map<String, List<int>>)> fakeDav() async {
  final files = <String, List<int>>{};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final auth = req.headers.value('authorization');
    if (auth != 'Basic ${base64.encode(utf8.encode('u:p'))}') {
      req.response.statusCode = 401;
      req.response.headers.set('WWW-Authenticate', 'Basic realm="x"');
      await req.response.close();
      return;
    }
    final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    final path = req.uri.path;
    switch (req.method) {
      case 'OPTIONS':
        req.response.statusCode = 200;
      case 'MKCOL':
        req.response.statusCode = 201;
      case 'PUT':
        files[path] = body;
        req.response.statusCode = 201;
      case 'GET':
        final f = files[path];
        req.response.statusCode = f == null ? 404 : 200;
        if (f != null) req.response.add(f);
      case 'DELETE':
        req.response.statusCode = files.remove(path) == null ? 404 : 204;
      case 'PROPFIND':
        req.response.statusCode = 207;
        final b = StringBuffer('<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
            '<D:response><D:href>$path</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>');
        var i = 0;
        for (final e in files.entries.where((e) => e.key.startsWith(path))) {
          final t = HttpDate.format(DateTime.utc(2026, 1, 1).add(Duration(minutes: i++)));
          b.write('<D:response><D:href>${e.key}</D:href><D:propstat><D:prop><D:getlastmodified>$t</D:getlastmodified>'
              '<D:getcontentlength>${e.value.length}</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>');
        }
        b.write('</D:multistatus>');
        req.response.write(b);
      default:
        req.response.statusCode = 405;
    }
    await req.response.close();
  });
  return (server, files);
}

void main() {
  test('encode / decode without secrets', () {
    final bytes = encodeBackup(
      profiles: [
        {'id': 'a', 'name': 'A', 'password': 'pw', 'totpSecret': 's'},
      ],
      settings: {'socksPort': 1080},
      includeSecrets: false,
      device: 'phone',
    );
    final d = decodeBackup(bytes);
    expect(d.profiles.single['name'], 'A');
    expect(d.profiles.single.containsKey('password'), isFalse);
    expect(d.device, 'phone');
    expect(() => decodeBackup(utf8.encode('{}')), throwsA(isA<BackupException>()));
  });

  test('encrypted backup round trip', () {
    final bytes = encodeBackup(profiles: [
      {'id': 'a', 'name': 'A', 'password': 'pw-Distinctive-Plaintext-Marker-9271'},
    ], settings: {}, password: 'secret');
    expect(isEncryptedBackup(bytes), isTrue);
    expect(utf8.decode(bytes).contains('Distinctive-Plaintext-Marker'), isFalse);
    expect(() => decodeBackup(bytes), throwsA(predicate((e) => e is BackupException && e.key == 'backup_need_password')));
    expect(() => decodeBackup(bytes, password: 'nope'),
        throwsA(predicate((e) => e is BackupException && e.key == 'backup_wrong_password')));
    expect(decodeBackup(bytes, password: 'secret').profiles.single['password'], 'pw-Distinctive-Plaintext-Marker-9271');
    // legacy plain format still reads
    final legacy = utf8.encode('{"format":"zju-connect-backup","version":1,"profiles":[]}');
    expect(decodeBackup(legacy).profiles, isEmpty);
  });

  test('merge strategies keep local secrets', () {
    final cur = [
      {'id': 'a', 'name': 'A', 'password': 'local'},
      {'id': 'b', 'name': 'B'},
    ];
    final bak = [
      {'id': 'a', 'name': 'A2', 'password': ''},
      {'id': 'c', 'name': 'C'},
    ];
    final compat = mergeProfiles(cur, bak, RestoreStrategy.compatible);
    expect(compat.map((e) => e['id']), ['a', 'b', 'c']);
    expect(compat.first['name'], 'A2');
    expect(compat.first['password'], 'local');
    final over = mergeProfiles(cur, bak, RestoreStrategy.override);
    expect(over.map((e) => e['id']), ['a', 'c']);
    expect(over.first['password'], 'local');
  });

  test('webdav upload, list, retention, download', () async {
    final (server, files) = await fakeDav();
    final c = DavClient(DavConfig(uri: 'http://127.0.0.1:${server.port}/dav/', user: 'u', password: 'p', fileName: 'phone'));
    expect(await c.ping(), isTrue);
    for (var i = 0; i < 4; i++) {
      await c.upload('phone-2026010$i-000000.json', utf8.encode('{"n":$i}'), device: 'phone', keep: 2);
    }
    await c.upload('pc-20260101-000000.json', utf8.encode('{}'), device: 'pc', keep: 2);
    final list = await c.list();
    expect(list.where((e) => e.name.startsWith('phone-')).length, 2);
    expect(list.any((e) => e.name.startsWith('pc-')), isTrue);
    expect(utf8.decode(await c.download('phone-20260103-000000.json')), '{"n":3}');
    expect(files.keys.every((k) => k.startsWith('/dav/PureConnect/')), isTrue);
    files['/dav/zju-connect/old-20251201-000000.json'] = utf8.encode('{"old":1}');
    expect((await c.list()).any((e) => e.name.startsWith('old-')), isFalse);
    final bad = DavClient(DavConfig(uri: 'http://127.0.0.1:${server.port}/dav/', user: 'u', password: 'x'));
    expect(await bad.ping(), isFalse);
    c.close();
    bad.close();
    await server.close(force: true);
  });
}
