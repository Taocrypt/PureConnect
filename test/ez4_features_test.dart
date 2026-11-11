import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/config_builder.dart';
import 'package:zju_connect/core/extra_args.dart';
import 'package:zju_connect/core/system_proxy.dart';
import 'package:zju_connect/l10n/strings.dart';
import 'package:zju_connect/models/profile.dart';
import 'package:zju_connect/models/settings.dart';
import 'package:zju_connect/state/providers.dart';
import 'package:zju_connect/ui/tour/guide_tour.dart';
import 'package:zju_connect/ui/widgets/connect_prompts.dart';

void main() {
  group('extra core options', () {
    test('flags, values and booleans', () {
      final r = parseExtraArgs('-disable-multi-line --dns-ttl 600\n-keep-alive-url=https://vpn.xxx.edu.cn/ -proxy-all false');
      expect(r.errors, isEmpty);
      expect(r.config, {
        'disable_multi_line': true,
        'dns_ttl': 600,
        'keep_alive_url': 'https://vpn.xxx.edu.cn/',
        'proxy_all': false,
      });
    });

    test('renamed and legacy flags map to config keys', () {
      final r = parseExtraArgs('-server vpn.example.edu.cn -port 8443 -disable-zju-dns');
      expect(r.config, {'server_address': 'vpn.example.edu.cn', 'server_port': 8443, 'disable_remote_dns': true});
    });

    test('quoted values keep spaces', () {
      expect(parseExtraArgs('-password "a b c"').config['password'], 'a b c');
    });

    test('collections use upstream comma formats and append', () {
      final r = parseExtraArgs(
          '-tcp-port-forwarding 127.0.0.1:9898-10.0.0.1:80,127.0.0.1:9899-10.0.0.2:22 -custom-dns a.example.edu.cn:10.0.0.3 -custom-proxy-domain example.org');
      expect(r.errors, isEmpty);
      expect(r.portForwarding, hasLength(2));
      expect(r.portForwarding.first, {'network_type': 'tcp', 'bind_address': '127.0.0.1:9898', 'remote_address': '10.0.0.1:80'});
      expect(r.customDns.single, {'host_name': 'a.example.edu.cn', 'ip': '10.0.0.3'});
      final c = <String, dynamic>{
        'port_forwarding': [
          {'network_type': 'udp', 'bind_address': 'x', 'remote_address': 'y'}
        ],
      };
      r.applyTo(c);
      expect(c['port_forwarding'], hasLength(3));
      expect(c['custom_proxy_domain'], ['example.org']);
    });

    test('reports unknown, managed and malformed options', () {
      final r = parseExtraArgs('-no-such-flag 1 -tun-mode -dns-ttl abc -server stray');
      expect(r.errors.length, 3);
      expect(r.config, {'server_address': 'stray'});
    });
  });

  group('config builder', () {
    final profile = Profile(name: 'x', serverAddress: 'vpn.example.edu.cn');

    test('keep-alive is on by default and an empty URL is left to the core', () {
      final s = AppSettings();
      expect(s.disableKeepAlive, isFalse);
      expect(AppSettings.fromJson(const {}).disableKeepAlive, isFalse);
      expect(AppSettings.fromJson(const {}).addRoute, isTrue);
      final c = buildCoreConfig(profile: profile, settings: s, dataDir: '/d', android: false);
      expect(c['disable_keep_alive'], isFalse);
      expect(c.containsKey('keep_alive_url'), isFalse);
    });

    test('debug capture paths and extra options', () {
      final s = AppSettings()
        ..debugPcap = true
        ..debugTlsKeyLog = true
        ..extraArgs = '-dns-ttl 60 -disable-keep-alive';
      final c = buildCoreConfig(
          profile: profile, settings: s, dataDir: '/d', android: false, now: DateTime(2026, 1, 2, 3, 4, 5));
      expect(c['debug_pcap_file'], endsWith('pureconnect-20260102-030405.pcap'));
      expect(c['debug_tls_log_file'], endsWith('pureconnect-20260102-030405.keys.log'));
      expect(c['dns_ttl'], 60);
      expect(c['disable_keep_alive'], isTrue);
    });
  });

  test('new settings survive JSON and default sensibly', () {
    final d = AppSettings.fromJson(const {});
    expect(d.autoReconnect, isFalse);
    expect(d.reconnectDelay, 5);
    expect(d.notifications, isTrue);
    expect(d.warnProxyOverride, isTrue);
    expect(d.minimizeToTray, isFalse);
    final s = AppSettings()
      ..autoReconnect = true
      ..reconnectDelay = 9
      ..systemProxyBypass = '*.example.com; 192.0.2.*\nfoo'
      ..extraArgs = '-proxy-all';
    final r = AppSettings.fromJson(s.toJson());
    expect(r.autoReconnect, isTrue);
    expect(r.reconnectDelay, 9);
    expect(r.systemProxyBypassList, ['*.example.com', '192.0.2.*', 'foo']);
    expect(r.extraArgs, '-proxy-all');
  });

  test('reconnect only for errors a retry can fix', () {
    expect(CoreController.isReconnectable(null), isTrue);
    expect(CoreController.isReconnectable('dial tcp: i/o timeout'), isTrue);
    expect(CoreController.isReconnectable('session is invalid'), isTrue);
    expect(CoreController.isReconnectable('invalid username or password'), isFalse);
    expect(CoreController.isReconnectable('authentication cancelled by user'), isFalse);
    // Kicked by a sign-in elsewhere: reconnecting would kick the other device.
    expect(CoreController.isReconnectable(
        'kicked offline: the account signed in on another device (unexpected recv handshake reply (0x00))'), isFalse);
    expect(CoreController.isReconnectable('tunnel closed: EOF'), isTrue);
  });

  group('system proxy', () {
    test('user exclusions are added once', () {
      expect(SystemProxy.bypassWith(['*.example.com', 'localhost']), [...SystemProxy.bypass, '*.example.com']);
    });

    test('detects another app\'s proxy', () {
      expect(SystemProxy.describeForeign({'windows': {'enable': 1, 'server': '127.0.0.1:7890', 'autoConfigUrl': ''}}),
          '127.0.0.1:7890');
      expect(SystemProxy.describeForeign({'windows': {'enable': 0, 'server': '127.0.0.1:7890'}}), isNull);
      expect(
          SystemProxy.describeForeign({
            'mac': {
              'Wi-Fi': {
                'web': {'enabled': false, 'server': '', 'port': 0},
                'socks': {'enabled': true, 'server': '127.0.0.1', 'port': 7891},
              }
            }
          }),
          '127.0.0.1:7891');
      expect(SystemProxy.describeForeign({'gnome': {'org.gnome.system.proxy mode': "'none'"}}), isNull);
      expect(
          SystemProxy.describeForeign({
            'gnome': {
              'org.gnome.system.proxy mode': "'manual'",
              'org.gnome.system.proxy.http host': "'127.0.0.1'",
              'org.gnome.system.proxy.http port': '7890',
            }
          }),
          '127.0.0.1:7890');
    });
  });

  test('missing sign-in details', () {
    expect(missingLogin(Profile(name: 'a')), 'password');
    expect(missingLogin(Profile(name: 'a', username: 'u', password: 'p')), isNull);
    expect(missingLogin(Profile(name: 'a', certFile: '/c.p12')), isNull);
    expect(missingLogin(Profile(name: 'a', protocol: VpnProtocol.atrust, authType: AtrustAuthType.sms)), 'phone');
    expect(missingLogin(Profile(name: 'a', protocol: VpnProtocol.atrust, authType: AtrustAuthType.cas)), isNull);
    expect(missingLogin(Profile(name: 'a', protocol: VpnProtocol.atrust)), isNull);
  });

  test('setup guide reads the auth_info list', () {
    final l = GuideAuthOption.parse([
      {'authType': 'auth/psw', 'loginDomain': 'Radius', 'authName': 'Password'},
      {'authType': '', 'loginDomain': 'x'},
      'junk',
    ]);
    expect(l, hasLength(1));
    expect(l.single.authType, 'auth/psw');
    expect(GuideAuthOption.parse(null), isEmpty);
  });

  test('new strings exist in both languages; zh descriptions stay short', () {
    for (final k in [
      'auto_reconnect_desc', 'notifications_desc', 'minimize_to_tray_desc', 'system_proxy_desc',
      'warn_proxy_override_desc', 'clear_system_proxy_desc', 'debug_pcap_desc', 'debug_tls_keylog_desc',
      'debug_files_desc', 'extra_args_desc', 'reset_settings_desc', 'advanced_desc', 'backup_restore_sub',
    ]) {
      final zh = S('zh').t(k);
      expect(zh, isNot(k));
      expect(S('en').t(k), isNot(k));
      expect(zh.runes.length, lessThanOrEqualTo(20), reason: '$k: $zh');
    }
  });
}
