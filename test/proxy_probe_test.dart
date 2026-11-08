import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/proxy_probe.dart';

void main() {
  test('parse', () {
    expect(ProxyUrl.parse('socks5://127.0.0.1:7890')!.isLocal, true);
    expect(ProxyUrl.parse('http://a:b@10.0.0.1:8080')!.user, 'a');
    expect(ProxyUrl.parse('ftp://x:1'), isNull);
    expect(ProxyUrl.parse('socks5://127.0.0.1'), isNull);
  });
  test('socks5 ok, closed port fails, wrong kind detected', () async {
    final srv = await ServerSocket.bind('127.0.0.1', 0);
    srv.listen((c) => c.listen((_) => c.add([5, 0])));
    expect((await probeProxy(ProxyUrl.parse('socks5://127.0.0.1:${srv.port}')!)).ok, true);
    final http = await probeProxy(ProxyUrl.parse('http://127.0.0.1:${srv.port}')!, timeout: const Duration(seconds: 1));
    expect(http.wrongKind, true);
    await srv.close();
    final closed = await probeProxy(ProxyUrl.parse('socks5://127.0.0.1:${srv.port}')!);
    expect(closed.ok, false);
    expect(closed.wrongKind, false);
  });
}
