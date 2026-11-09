import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'desktop_window.dart';

/// Sets / restores the OS-wide proxy on desktop platforms.
///
/// Before the first change the current settings are saved to
/// `system_proxy_backup.json` in the data dir and put back on disable, so a
/// proxy (or PAC) the user had before survives. If PureConnect dies with the
/// proxy on, the next start restores it from that file ([recoverStale]); on
/// Windows the runner also restores it itself at logoff/shutdown.
///
/// Windows: per-user WinINet settings through the runner (registry +
/// InternetSetOption, so running browsers notice at once).
/// macOS: `networksetup` for every network service.
/// Linux: GNOME `gsettings`, plus KDE `kioslaverc` on Plasma.
class SystemProxy {
  static const bypass = [
    'localhost',
    '127.*',
    '10.*',
    '172.16.*',
    '192.168.*',
    '<local>',
  ];

  static bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static File _backupFile(String dataDir) => File(p.join(dataDir, 'system_proxy_backup.json'));

  /// Restores the settings saved by a run that never turned the proxy off
  /// (crash, kill, power loss). Returns true when something was restored.
  static Future<bool> recoverStale(String dataDir) async {
    if (!supported) return false;
    final f = _backupFile(dataDir);
    if (!f.existsSync()) return false;
    try {
      await _restore(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      await _forceOff();
    }
    try {
      await f.delete();
    } catch (_) {}
    return true;
  }

  /// Built-in exclusions plus the user's own ([extra]), without duplicates.
  static List<String> bypassWith(List<String> extra) => [
        ...bypass,
        for (final e in extra)
          if (!bypass.contains(e)) e,
      ];

  /// A system proxy that someone else (Clash, another VPN client) has turned
  /// on, as a short description; null when there is none or it is ours.
  static Future<String?> foreignProxy(String dataDir) async {
    if (!supported) return null;
    // Our own backup exists: the current proxy is ours (reconnect).
    if (_backupFile(dataDir).existsSync()) return null;
    try {
      final snap = await _snapshot();
      return describeForeign(snap);
    } catch (_) {
      return null;
    }
  }

  /// Pure part of [foreignProxy], on a [_snapshot] map (tested).
  static String? describeForeign(Map<String, dynamic> snap) {
    final w = snap['windows'];
    if (w is Map) {
      final pac = (w['autoConfigUrl'] as String? ?? '').trim();
      if (pac.isNotEmpty) return 'PAC $pac';
      if (const ['1', 'true'].contains('${w['enable']}') && (w['server'] as String? ?? '').isNotEmpty) return w['server'] as String;
      return null;
    }
    final mac = snap['mac'];
    if (mac is Map) {
      for (final v in mac.values) {
        if (v is! Map) continue;
        for (final k in const ['web', 'secure', 'socks']) {
          final x = v[k];
          if (x is Map && x['enabled'] == true && (x['server'] as String? ?? '').isNotEmpty) {
            return '${x['server']}:${x['port']}';
          }
        }
      }
      return null;
    }
    final gnome = snap['gnome'];
    if (gnome is Map) {
      final mode = (gnome['org.gnome.system.proxy mode'] as String? ?? '').replaceAll("'", '').trim();
      if (mode == 'manual') {
        final host = (gnome['org.gnome.system.proxy.http host'] as String? ?? '').replaceAll("'", '').trim();
        final port = (gnome['org.gnome.system.proxy.http port'] as String? ?? '').trim();
        return host.isEmpty ? 'manual' : '$host:$port';
      }
      if (mode == 'auto') return 'PAC';
    }
    final kde = snap['kde'];
    if (kde is Map && (kde['ProxyType'] ?? '0') != '0' && kde['ProxyType'] != '') return 'KDE';
    return null;
  }

  /// Turns the system proxy off right now (tools menu "clear system proxy"):
  /// restores our backup when there is one, else switches every proxy off.
  static Future<void> clear(String dataDir) => disable(dataDir);

  static Future<void> enable({
    required String dataDir,
    required int httpPort,
    required int socksPort,
    List<String> extraBypass = const [],
  }) async {
    final bypass = bypassWith(extraBypass);
    final f = _backupFile(dataDir);
    Map<String, dynamic>? snap;
    if (f.existsSync()) {
      // Already ours (reconnect): keep the user's original settings.
      try {
        snap = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
    }
    if (snap == null) {
      snap = await _snapshot();
      try {
        await f.writeAsString(jsonEncode(snap), flush: true);
      } catch (_) {}
    }
    if (Platform.isWindows) {
      await DesktopWindow.proxyGuard(snap['windows'] as Map<String, dynamic>?);
      final server = httpPort > 0 ? '127.0.0.1:$httpPort' : 'socks=127.0.0.1:$socksPort';
      await DesktopWindow.proxySet({
        'enable': 1,
        'server': server,
        'bypass': bypass.join(';'),
        'autoConfigUrl': null,
      });
    } else if (Platform.isMacOS) {
      for (final s in await _macServices()) {
        if (httpPort > 0) {
          await _run('networksetup', ['-setwebproxy', s, '127.0.0.1', '$httpPort']);
          await _run('networksetup', ['-setsecurewebproxy', s, '127.0.0.1', '$httpPort']);
        }
        if (socksPort > 0) {
          await _run('networksetup', ['-setsocksfirewallproxy', s, '127.0.0.1', '$socksPort']);
        }
        await _run('networksetup', ['-setproxybypassdomains', s, ...bypass.where((b) => b != '<local>')]);
      }
    } else if (Platform.isLinux) {
      Future<void> g(List<String> a) => _run('gsettings', ['set', ...a]);
      await g(['org.gnome.system.proxy', 'mode', 'manual']);
      if (httpPort > 0) {
        await g(['org.gnome.system.proxy.http', 'host', '127.0.0.1']);
        await g(['org.gnome.system.proxy.http', 'port', '$httpPort']);
        await g(['org.gnome.system.proxy.https', 'host', '127.0.0.1']);
        await g(['org.gnome.system.proxy.https', 'port', '$httpPort']);
      }
      if (socksPort > 0) {
        await g(['org.gnome.system.proxy.socks', 'host', '127.0.0.1']);
        await g(['org.gnome.system.proxy.socks', 'port', '$socksPort']);
      }
      final hosts = ['localhost', '127.0.0.0/8', '::1', '10.0.0.0/8', '192.168.0.0/16', '172.16.0.0/12', ...extraBypass];
      await g(['org.gnome.system.proxy', 'ignore-hosts', '[${hosts.map((h) => "'${h.replaceAll("'", '')}'").join(', ')}]']);
      if (_isKde) {
        await _kdeWrite({
          'ProxyType': '1',
          'httpProxy': httpPort > 0 ? 'http://127.0.0.1 $httpPort' : '',
          'httpsProxy': httpPort > 0 ? 'http://127.0.0.1 $httpPort' : '',
          'socksProxy': socksPort > 0 ? 'socks://127.0.0.1 $socksPort' : '',
          'NoProxyFor': ['localhost', '127.0.0.0/8', '::1', '10.0.0.0/8', '192.168.0.0/16', '172.16.0.0/12', ...extraBypass].join(','),
        });
      }
    }
  }

  static Future<void> disable(String dataDir) async {
    final f = _backupFile(dataDir);
    try {
      if (f.existsSync()) {
        await _restore(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      } else {
        await _forceOff();
      }
    } catch (_) {
      await _forceOff();
    }
    try {
      if (f.existsSync()) await f.delete();
    } catch (_) {}
    if (Platform.isWindows) await DesktopWindow.proxyGuard(null);
  }

  // --- snapshot / restore ---------------------------------------------------

  static Future<Map<String, dynamic>> _snapshot() async {
    try {
      if (Platform.isWindows) {
        return {'windows': await DesktopWindow.proxyGet()};
      }
      if (Platform.isMacOS) {
        final services = <String, dynamic>{};
        for (final s in await _macServices()) {
          services[s] = {
            'web': await _macGet('-getwebproxy', s),
            'secure': await _macGet('-getsecurewebproxy', s),
            'socks': await _macGet('-getsocksfirewallproxy', s),
            'bypass': await _macBypass(s),
          };
        }
        return {'mac': services};
      }
      if (Platform.isLinux) {
        final gnome = <String, String>{};
        for (final k in _gnomeKeys) {
          final r = await _out('gsettings', ['get', k.$1, k.$2]);
          if (r != null) gnome['${k.$1} ${k.$2}'] = r;
        }
        return {
          'gnome': gnome,
          if (_isKde) 'kde': await _kdeRead(),
        };
      }
    } catch (_) {}
    return {};
  }

  static Future<void> _restore(Map<String, dynamic> snap) async {
    if (Platform.isWindows) {
      final w = snap['windows'];
      if (w is Map) {
        await DesktopWindow.proxySet(w.cast<String, dynamic>());
      } else {
        await _forceOff();
      }
    } else if (Platform.isMacOS) {
      final mac = snap['mac'];
      if (mac is! Map) return _forceOff();
      for (final e in mac.entries) {
        final s = e.key as String;
        final v = (e.value as Map).cast<String, dynamic>();
        Future<void> one(String set, String state, Object? m) async {
          final x = m is Map ? m : const {};
          if (x['enabled'] == true && (x['server'] as String? ?? '').isNotEmpty) {
            await _run('networksetup', [set, s, x['server'] as String, '${x['port'] ?? 0}']);
          } else {
            await _run('networksetup', [state, s, 'off']);
          }
        }
        await one('-setwebproxy', '-setwebproxystate', v['web']);
        await one('-setsecurewebproxy', '-setsecurewebproxystate', v['secure']);
        await one('-setsocksfirewallproxy', '-setsocksfirewallproxystate', v['socks']);
        final b = (v['bypass'] as List?)?.cast<String>() ?? const [];
        await _run('networksetup', ['-setproxybypassdomains', s, ...(b.isEmpty ? ['Empty'] : b)]);
      }
    } else if (Platform.isLinux) {
      final gnome = snap['gnome'];
      if (gnome is Map && gnome.isNotEmpty) {
        // Mode last, so apps never see "manual" with half-restored hosts.
        final entries = gnome.entries.toList()
          ..sort((a, b) => (a.key as String).endsWith(' mode') ? 1 : (b.key as String).endsWith(' mode') ? -1 : 0);
        for (final e in entries) {
          final k = (e.key as String).split(' ');
          if (k.length == 2) await _run('gsettings', ['set', k[0], k[1], e.value as String]);
        }
      } else {
        await _run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'none']);
      }
      final kde = snap['kde'];
      if (kde is Map) await _kdeWrite(kde.cast<String, String>());
    }
  }

  /// Last resort when no snapshot is readable: just turn the proxy off.
  static Future<void> _forceOff() async {
    try {
      if (Platform.isWindows) {
        final cur = await DesktopWindow.proxyGet();
        if (cur != null) await DesktopWindow.proxySet({...cur, 'enable': 0});
      } else if (Platform.isMacOS) {
        for (final s in await _macServices()) {
          await _run('networksetup', ['-setwebproxystate', s, 'off']);
          await _run('networksetup', ['-setsecurewebproxystate', s, 'off']);
          await _run('networksetup', ['-setsocksfirewallproxystate', s, 'off']);
        }
      } else if (Platform.isLinux) {
        await _run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'none']);
        if (_isKde) await _kdeWrite({'ProxyType': '0'});
      }
    } catch (_) {}
  }

  // --- macOS ------------------------------------------------------------------

  static Future<List<String>> _macServices() async {
    final out = await _out('networksetup', ['-listallnetworkservices']) ?? '';
    return out
        .split('\n')
        .skip(1)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('*'))
        .toList();
  }

  /// Parses `networksetup -get…proxy` ("Enabled: Yes / Server: … / Port: …").
  static Future<Map<String, dynamic>> _macGet(String cmd, String service) async {
    final out = await _out('networksetup', [cmd, service]) ?? '';
    return parseMacProxy(out);
  }

  static Map<String, dynamic> parseMacProxy(String out) {
    String field(String name) {
      for (final l in out.split('\n')) {
        final i = l.indexOf(':');
        if (i > 0 && l.substring(0, i).trim() == name) return l.substring(i + 1).trim();
      }
      return '';
    }

    return {
      'enabled': field('Enabled').toLowerCase() == 'yes',
      'server': field('Server'),
      'port': int.tryParse(field('Port')) ?? 0,
    };
  }

  static Future<List<String>> _macBypass(String service) async {
    final out = await _out('networksetup', ['-getproxybypassdomains', service]) ?? '';
    if (out.contains("aren't any")) return const [];
    return out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  }

  // --- Linux --------------------------------------------------------------------

  static const _gnomeKeys = [
    ('org.gnome.system.proxy', 'mode'),
    ('org.gnome.system.proxy', 'ignore-hosts'),
    ('org.gnome.system.proxy.http', 'host'),
    ('org.gnome.system.proxy.http', 'port'),
    ('org.gnome.system.proxy.https', 'host'),
    ('org.gnome.system.proxy.https', 'port'),
    ('org.gnome.system.proxy.socks', 'host'),
    ('org.gnome.system.proxy.socks', 'port'),
  ];

  static bool get _isKde =>
      (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().contains('KDE');

  static const _kdeKeys = ['ProxyType', 'httpProxy', 'httpsProxy', 'socksProxy', 'NoProxyFor'];

  static Future<String?> _kdeTool(String base) async {
    for (final v in ['6', '5', '']) {
      final r = await _out('sh', ['-c', 'command -v $base$v']);
      if (r != null && r.trim().isNotEmpty) return r.trim();
    }
    return null;
  }

  static Future<Map<String, String>> _kdeRead() async {
    final tool = await _kdeTool('kreadconfig');
    final out = <String, String>{};
    if (tool == null) return out;
    for (final k in _kdeKeys) {
      out[k] = (await _out(tool, ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', k]))?.trim() ?? '';
    }
    return out;
  }

  static Future<void> _kdeWrite(Map<String, String> values) async {
    final tool = await _kdeTool('kwriteconfig');
    if (tool == null) return;
    for (final e in values.entries) {
      await _run(tool, ['--file', 'kioslaverc', '--group', 'Proxy Settings', '--key', e.key, e.value]);
    }
    await _run('dbus-send', ['--type=signal', '/KIO/Scheduler',
      'org.kde.KIO.Scheduler.reparseSlaveConfiguration', "string:''"]);
  }

  // --- helpers ------------------------------------------------------------------

  static Future<void> _run(String exe, List<String> args) async {
    try {
      await Process.run(exe, args);
    } catch (_) {}
  }

  static Future<String?> _out(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args);
      if (r.exitCode != 0) return null;
      return (r.stdout as String).trim();
    } catch (_) {
      return null;
    }
  }
}
