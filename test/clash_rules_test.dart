import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/clash_rules.dart';
import 'package:zju_connect/core/protocol.dart';

void main() {
  test('cidr', () {
    expect(rangeToCidrs('10.0.0.0', '10.255.255.255'), ['10.0.0.0/8']);
    expect(rangeToCidrs('10.0.0.1', '10.0.0.6'), ['10.0.0.1/32', '10.0.0.2/31', '10.0.0.4/31', '10.0.0.6/32']);
    expect(rangeToCidrs('0.0.0.0', '255.255.255.255'), ['0.0.0.0/0']);
  });
  test('yaml', () {
    final s = SessionInfo(protocol: 'easyconnect', server: 'vpn.example.edu.cn', ip: '1.2.3.4', dnsServer: '10.10.0.21', secondaryDns: '', routes: ['10.0.0.0/8'], stack: 'gvisor', socksBind: '127.0.0.1:1080', httpBind: '', dnsServerBind: '', shadowsocks: false, portForwarding: [], ipResources: [IpResource('198.51.100.1', '198.51.100.254', 1, 65535, 'tcp')], domainResources: ['*.example.edu.cn', 'lib.example.edu.cn'], mtu: 1400);
    final y = buildClashRules(s);
    expect(y, contains('DOMAIN-SUFFIX,example.edu.cn,PureConnect'));
  });
}
