import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/autostart.dart';
import 'package:zju_connect/core/errors.dart';
import 'package:zju_connect/core/system_proxy.dart';
import 'package:zju_connect/models/settings.dart';

void main() {
  test('parses networksetup proxy output', () {
    final on = SystemProxy.parseMacProxy('Enabled: Yes\nServer: 10.1.2.3\nPort: 8080\nAuthenticated Proxy Enabled: 0\n');
    expect(on, {'enabled': true, 'server': '10.1.2.3', 'port': 8080});
    final off = SystemProxy.parseMacProxy('Enabled: No\nServer: \nPort: 0\n');
    expect(off['enabled'], false);
    expect(off['server'], '');
  });

  test('launch-at-login entries', () {
    final plist = Autostart.macPlist('/Applications/Pure & Connect.app', hidden: true);
    expect(plist, contains('<string>/Applications/Pure &amp; Connect.app</string>'));
    expect(plist, contains('<string>--hidden</string>'));
    expect(Autostart.macPlist('/Applications/PureConnect.app', hidden: false), isNot(contains('--hidden')));

    final desktop = Autostart.linuxDesktopEntry(r'/opt/my app/pure$connect', hidden: true);
    expect(desktop, contains(r'Exec="/opt/my app/pure\$connect" --hidden'));
    expect(desktop, contains('X-GNOME-Autostart-enabled=true'));
  });

  test('desktop settings round trip and defaults', () {
    final d = AppSettings.fromJson(const {});
    expect(d.closeToTray, true);
    expect(d.silentStart, false);
    expect(d.hideDockIcon, false);
    final s = AppSettings()
      ..closeToTray = false
      ..silentStart = true
      ..hideDockIcon = true;
    final r = AppSettings.fromJson(s.toJson());
    expect([r.closeToTray, r.silentStart, r.hideDockIcon], [false, true, true]);
  });

  test('elevation / wintun errors are explained', () {
    expect(errorKey('Administrator authorization cancelled'), 'elevation_cancelled');
    expect(errorKey('wintun.dll is missing next to zjuconnect-core.exe; reinstall PureConnect'), 'wintun_missing');
    expect(errorKey('TUN mode needs administrator rights (accept the UAC prompt)'), 'tun_permission');
    expect(errorKey('TUN mode needs root (administrator) rights'), 'tun_permission');
    expect(humanizeErrorIn('zh', 'Administrator authorization cancelled'), '已取消管理员授权，TUN 模式未开启');
  });
}
