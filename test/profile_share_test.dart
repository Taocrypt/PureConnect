import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/profile_share.dart';
import 'package:zju_connect/models/profile.dart';

void main() {
  test('share carries password but not TOTP/tokens', () {
    final p = Profile(name: 'Example', serverAddress: 'vpn.example.edu.cn', username: 'u', password: 'secret', totpSecret: 'TOTPKEY');
    final text = encodeProfileShare(p);
    expect(text.contains('TOTPKEY'), isFalse);
    final q = decodeProfileShare(text)!;
    expect(q.name, 'Example');
    expect(q.serverAddress, 'vpn.example.edu.cn');
    expect(q.username, 'u');
    expect(q.password, 'secret');
    expect(q.totpSecret, '');
    expect(q.id, isNot(p.id));
  });

  test('rejects junk', () {
    expect(decodeProfileShare('hello'), isNull);
    expect(decodeProfileShare('[1,2]'), isNull);
  });
}
