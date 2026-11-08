import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/errors.dart';

void main() {
  final catalog = File('test/fixtures/core_errors.txt')
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .toList();

  test('every core error yields a clean message in zh and en', () {
    final unmatched = <String>[];
    for (final raw in catalog) {
      for (final lang in ['zh', 'en']) {
        final m = humanizeErrorIn(lang, raw);
        expect(m, isNotEmpty, reason: raw);
        expect(m.contains('VPN client setup error'), isFalse, reason: raw);
        expect(m.contains('<?xml'), isFalse, reason: raw);
      }
      if (errorKey(raw) == null) unmatched.add(raw);
    }
    File('build/unmatched_errors.txt').writeAsStringSync(unmatched.join('\n'));
    // Internal protocol errors may fall back to the generic message, but
    // they must stay a small minority.
    expect(unmatched.length, lessThan(catalog.length ~/ 10), reason: unmatched.join('\n'));
  });

  test('reported login errors', () {
    const cases = {
      'VPN client setup error: complete EasyConnect captcha challenge: authentication cancelled by user': 'cancelled',
      'VPN client setup error: Login failed: You are trying brute-force login on this IP address. Word verification is enabled!': 'bruteforce',
      'VPN client setup error: Login failed: Invalid username or password!': 'bad_password',
      'VPN client setup error: Login failed: Rand code error!': 'captcha_wrong',
      'missing credentials for the selected aTrust auth type': 'missing_credentials',
      'VPN client setup error: failed to connect to aTrust server: dial tcp: lookup a.b: no such host': 'dns',
      'listen tcp 127.0.0.1:1080: bind: address already in use': 'port_in_use',
      'sangfor: SHUTDOWN (cmd 0x08)': 'shutdown',
    };
    cases.forEach((raw, key) => expect(errorKey(raw), key, reason: raw));
    expect(humanizeErrorIn('zh', cases.keys.elementAt(2)), '用户名或密码错误，请检查配置后重试');
    expect(humanizeErrorIn('en', cases.keys.elementAt(2)), startsWith('Wrong username or password'));
    expect(humanizeErrorIn('zh', 'password authentication failed with code 10: 账号未激活'), contains('账号未激活'));
  });
}
