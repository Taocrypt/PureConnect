import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Parsed external proxy URL (socks5:// socks5h:// socks:// http://).
class ProxyUrl {
  ProxyUrl(this.kind, this.host, this.port, {this.user, this.pass});
  final String kind; // socks | http
  final String host;
  final int port;
  final String? user, pass;

  bool get isLocal => const {'127.0.0.1', 'localhost', '::1', '0.0.0.0'}.contains(host);

  static ProxyUrl? parse(String s) {
    final m = RegExp(r'^(socks5h?|socks|http)://(?:([^:@/]*)(?::([^@/]*))?@)?(\[[^\]]+\]|[^:/]+):(\d{1,5})/?$')
        .firstMatch(s.trim());
    if (m == null) return null;
    final port = int.parse(m[5]!);
    if (port < 1 || port > 65535) return null;
    final host = m[4]!.replaceAll('[', '').replaceAll(']', '');
    return ProxyUrl(m[1] == 'http' ? 'http' : 'socks', host, port,
        user: (m[2]?.isEmpty ?? true) ? null : Uri.decodeComponent(m[2]!),
        pass: m[3] == null ? null : Uri.decodeComponent(m[3]!));
  }
}

/// Result of a connectivity check: null error = the proxy answered correctly.
class ProbeResult {
  const ProbeResult.ok() : error = null, wrongKind = false;
  const ProbeResult.fail(this.error, {this.wrongKind = false});
  final String? error;
  final bool wrongKind;
  bool get ok => error == null;
}

/// Connects and speaks the first step of the protocol (SOCKS5 greeting, or an
/// HTTP CONNECT) to make sure a proxy of the right kind is listening.
Future<ProbeResult> probeProxy(ProxyUrl p, {Duration timeout = const Duration(seconds: 3)}) async {
  Socket s;
  try {
    s = await Socket.connect(p.host, p.port, timeout: timeout);
  } on SocketException catch (e) {
    return ProbeResult.fail(e.osError?.message ?? e.message);
  } catch (e) {
    return ProbeResult.fail('$e');
  }
  final buf = BytesBuilder();
  final got = Completer<void>();
  final sub = s.listen((d) {
    buf.add(d);
    if (!got.isCompleted && buf.length >= (p.kind == 'socks' ? 2 : 12)) got.complete();
  }, onError: (_) {
    if (!got.isCompleted) got.complete();
  }, onDone: () {
    if (!got.isCompleted) got.complete();
  });
  try {
    if (p.kind == 'socks') {
      s.add(p.user != null ? [5, 2, 0, 2] : [5, 1, 0]);
    } else {
      s.add('CONNECT connectivitycheck.gstatic.com:443 HTTP/1.1\r\nHost: connectivitycheck.gstatic.com:443\r\n\r\n'.codeUnits);
    }
    await s.flush();
    await got.future.timeout(timeout);
  } on TimeoutException {
    // fall through: checked below
  } catch (_) {}
  await sub.cancel();
  s.destroy();
  final b = buf.toBytes();
  if (b.isEmpty) return const ProbeResult.fail('no answer', wrongKind: true);
  if (p.kind == 'socks') {
    return b[0] == 5 && b.length >= 2 && b[1] != 0xff
        ? const ProbeResult.ok()
        : const ProbeResult.fail('bad greeting', wrongKind: true);
  }
  return String.fromCharCodes(b.take(5)) == 'HTTP/'
      ? const ProbeResult.ok()
      : const ProbeResult.fail('not HTTP', wrongKind: true);
}

const _channel = MethodChannel('zju_connect/core');

/// Android: which app listens on 127.0.0.1:[port]. Keys: status
/// (found | not_found | other_vpn | no_permission | unsupported | unreachable
/// | error), package, label, message.
Future<Map<String, Object?>> probeProxyOwner(int port) async {
  try {
    final r = await _channel.invokeMethod<Map>('probeProxyOwner', {'port': port, 'askPermission': true});
    return (r ?? const {}).cast<String, Object?>();
  } catch (e) {
    return {'status': 'error', 'message': '$e'};
  }
}
