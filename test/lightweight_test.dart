import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/backend.dart';
import 'package:zju_connect/core/lightweight.dart';
import 'package:zju_connect/core/protocol.dart';
import 'package:zju_connect/core/system_proxy.dart';
import 'package:zju_connect/l10n/strings.dart';
import 'package:zju_connect/models/settings.dart';
import 'package:zju_connect/state/providers.dart' show connectionSettingsKey;

/// A stand-in for a detached zjuconnect-core: the attach handshake of
/// core/bridge/attach.go (token check, ping, replay, commands).
class FakeDetachedCore {
  FakeDetachedCore._(this.server, this.token);
  final ServerSocket server;
  final String token;
  final commands = StreamController<Map<String, dynamic>>.broadcast();
  final handshakes = <String>[];
  Socket? client;

  static Future<FakeDetachedCore> start(String token) async {
    final core = FakeDetachedCore._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), token);
    core.server.listen(core._serve);
    return core;
  }

  int get port => server.port;

  void _serve(Socket s) {
    var greeted = false;
    s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!greeted) {
        greeted = true;
        handshakes.add(line);
        final j = jsonDecode(line) as Map<String, dynamic>;
        if (j['token'] != token) {
          s.destroy();
          return;
        }
        if (j['mode'] == 'ping') {
          s.writeln(jsonEncode({'type': 'pong', 'state': 'connected', 'pid': 4242}));
          s.destroy();
          return;
        }
        client = s;
        for (final ev in [
          {'type': 'hello', 'version': 'test-core'},
          {'type': 'state', 'state': 'connected'},
          {'type': 'session', 'session': {'ip': '10.0.0.2', 'routes': <String>[]}},
          {'type': 'log', 'level': 'info', 'message': 'while detached'},
        ]) {
          s.writeln(jsonEncode(ev));
        }
        return;
      }
      final cmd = jsonDecode(line) as Map<String, dynamic>;
      commands.add(cmd);
      if (cmd['cmd'] == 'stop') {
        s.writeln(jsonEncode({'type': 'state', 'state': 'stopped'}));
        s.destroy();
      } else if (cmd['cmd'] == 'detach') {
        s.writeln(jsonEncode({'type': 'detached', 'ok': true, 'port': port, 'pid': 4242}));
      }
    }, onError: (_) {});
  }

  Future<void> close() async {
    client?.destroy();
    await server.close();
  }
}

void main() {
  group('settings', () {
    test('lightweight mode is off by default, 3 minutes', () {
      final d = AppSettings.fromJson(const {});
      expect(d.lightweightMode, isFalse);
      expect(d.lightweightMinutes, 3);
      expect(AppSettings().lightweightMode, isFalse);
      expect(Lightweight.defaultMinutes, 3);
    });

    test('round trip and clamping', () {
      final s = AppSettings()
        ..lightweightMode = true
        ..lightweightMinutes = 10;
      final r = AppSettings.fromJson(s.toJson());
      expect([r.lightweightMode, r.lightweightMinutes], [true, 10]);
      expect(AppSettings.fromJson(const {'lightweightMinutes': 0}).lightweightMinutes, 1);
      expect(AppSettings.fromJson(const {'lightweightMinutes': 99999}).lightweightMinutes, 1440);
    });

    test('changing it does not ask for a reconnect', () {
      final a = AppSettings();
      final b = AppSettings()
        ..lightweightMode = true
        ..lightweightMinutes = 7;
      expect(connectionSettingsKey(a), connectionSettingsKey(b));
    });

    test('strings exist in zh and en', () {
      for (final lang in ['zh', 'en']) {
        final s = S(lang);
        for (final k in ['lightweight_mode', 'lightweight_mode_desc', 'lightweight_mode_desc_android', 'lightweight_minutes']) {
          expect(s.t(k), isNot(k), reason: '$lang $k');
        }
      }
    });
  });

  group('timer', () {
    late List<(Duration, void Function())> started;
    late List<_FakeTimer> timers;
    late int expired;
    late LightweightTimer t;

    setUp(() {
      started = [];
      timers = [];
      expired = 0;
      t = LightweightTimer(
        onExpire: () => expired++,
        timerFactory: (d, cb) {
          started.add((d, cb));
          final ft = _FakeTimer();
          timers.add(ft);
          return ft;
        },
      );
    });

    test('arms only when enabled, hidden and connected', () {
      t.update(enabled: false, minutes: 3, hidden: true, connected: true);
      t.update(enabled: true, minutes: 3, hidden: false, connected: true);
      t.update(enabled: true, minutes: 3, hidden: true, connected: false);
      expect(started, isEmpty);
      expect(t.armed, isFalse);
      t.update(enabled: true, minutes: 3, hidden: true, connected: true);
      expect(t.armed, isTrue);
      expect(started.single.$1, const Duration(minutes: 3));
    });

    test('repeated updates keep one countdown; showing the window cancels it', () {
      t.update(enabled: true, minutes: 3, hidden: true, connected: true);
      t.update(enabled: true, minutes: 3, hidden: true, connected: true);
      expect(started, hasLength(1));
      t.update(enabled: true, minutes: 3, hidden: false, connected: true);
      expect(t.armed, isFalse);
      expect(timers.single.cancelled, isTrue);
    });

    test('a disconnect or switching it off cancels', () {
      t.update(enabled: true, minutes: 3, hidden: true, connected: true);
      t.update(enabled: true, minutes: 3, hidden: true, connected: false);
      expect(timers.last.cancelled, isTrue);
      t.update(enabled: true, minutes: 3, hidden: true, connected: true);
      t.update(enabled: false, minutes: 3, hidden: true, connected: true);
      expect(timers.last.cancelled, isTrue);
      expect(expired, 0);
    });

    test('a new delay restarts; minutes are clamped', () {
      t.update(enabled: true, minutes: 3, hidden: true, connected: true);
      t.update(enabled: true, minutes: 5, hidden: true, connected: true);
      expect(timers.first.cancelled, isTrue);
      expect(started.last.$1, const Duration(minutes: 5));
      t.update(enabled: true, minutes: 0, hidden: true, connected: true);
      expect(started.last.$1, const Duration(minutes: 1));
    });

    test('expiring calls back once and disarms', () {
      t.update(enabled: true, minutes: 3, hidden: true, connected: true);
      started.single.$2();
      expect(expired, 1);
      expect(t.armed, isFalse);
    });

    test('with real timers', () {
      final fired = Completer<void>();
      final real = LightweightTimer(onExpire: () => fired.complete());
      real.update(enabled: true, minutes: 1, hidden: true, connected: true);
      expect(real.armed, isTrue);
      real.cancel();
      expect(real.armed, isFalse);
      expect(fired.isCompleted, isFalse);
    });
  });

  group('attach file and token', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pc_lw'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('token is 64 hex chars and random', () {
      final a = Lightweight.newToken();
      final b = Lightweight.newToken();
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a, isNot(b));
      expect(Lightweight.newToken(Random(1)), Lightweight.newToken(Random(1)));
    });

    test('write / read round trip, user-only permissions', () async {
      final info = AttachInfo(
        port: 50123,
        token: Lightweight.newToken(),
        profileName: 'ZJU',
        trafficMode: TrafficMode.systemProxy.name,
        startedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        applied: '{"x":1}',
      );
      await Lightweight.write(dir.path, info);
      final r = Lightweight.read(dir.path)!;
      expect(r.port, 50123);
      expect(r.token, info.token);
      expect(r.profileName, 'ZJU');
      expect(r.trafficMode, 'systemProxy');
      expect(r.startedAt, info.startedAt);
      expect(r.applied, '{"x":1}');
      expect(r.canAttach, isTrue);
      if (!Platform.isWindows) {
        final mode = Lightweight.attachFile(dir.path).statSync().mode & 0x1ff;
        expect(mode, 0x180, reason: 'attach file must be 0600, is ${mode.toRadixString(8)}');
      }
      Lightweight.remove(dir.path);
      expect(Lightweight.read(dir.path), isNull);
    });

    test('incomplete info cannot attach', () {
      expect(const AttachInfo(port: 1234, token: 'short').canAttach, isFalse);
      expect(AttachInfo(port: 0, token: Lightweight.newToken()).canAttach, isFalse);
      expect(const AttachInfo().canAttach, isFalse); // Android meta only
    });

    test('exit note is read once', () {
      Lightweight.exitNoteFile(dir.path).writeAsStringSync(jsonEncode({'error': 'kicked offline', 'code': 1}));
      expect(Lightweight.takeExitNote(dir.path), 'kicked offline');
      expect(Lightweight.takeExitNote(dir.path), isNull);
    });

    test('handshake lines', () {
      expect(jsonDecode(Lightweight.handshake('t')), {'token': 't', 'mode': 'attach'});
      expect(jsonDecode(Lightweight.handshake('t', ping: true)), {'token': 't', 'mode': 'ping'});
    });
  });

  group('re-attach protocol', () {
    late Directory dir;
    late FakeDetachedCore core;
    final token = Lightweight.newToken();

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('pc_lw');
      core = await FakeDetachedCore.start(token);
    });
    tearDown(() async {
      await core.close();
      dir.deleteSync(recursive: true);
    });

    test('ping finds a live core with the right token', () async {
      await Lightweight.write(dir.path, AttachInfo(port: core.port, token: token, profileName: 'P'));
      final info = await pingDetachedCore(dir.path);
      expect(info, isNotNull);
      expect(info!.pid, 4242);
      expect(info.profileName, 'P');
      expect(jsonDecode(core.handshakes.single), {'token': token, 'mode': 'ping'});
      expect(Lightweight.attachFile(dir.path).existsSync(), isTrue);
    });

    test('a wrong token is refused and the stale file removed', () async {
      await Lightweight.write(dir.path, AttachInfo(port: core.port, token: Lightweight.newToken()));
      expect(await pingDetachedCore(dir.path), isNull);
      expect(Lightweight.attachFile(dir.path).existsSync(), isFalse);
    });

    test('a dead core (nothing listening) leaves no attach file', () async {
      final port = core.port;
      await core.close();
      await Lightweight.write(dir.path, AttachInfo(port: port, token: token));
      expect(await pingDetachedCore(dir.path, timeout: const Duration(seconds: 1)), isNull);
      expect(Lightweight.attachFile(dir.path).existsSync(), isFalse);
    });

    test('reattach replays state, forwards commands, stop ends cleanly', () async {
      final backend = DesktopCoreBackend();
      final events = <CoreEvent>[];
      final sub = backend.events.listen(events.add);
      expect(await backend.reattach(AttachInfo(port: core.port, token: token)), isTrue);
      await _until(() => events.whereType<LogEvent>().isNotEmpty);
      expect(events.whereType<HelloEvent>().single.version, 'test-core');
      expect(events.whereType<StateEvent>().single.state, CoreState.connected);
      expect(events.whereType<SessionEvent>().single.session.ip, '10.0.0.2');
      expect(events.whereType<LogEvent>().single.entry.message, 'while detached');

      final cmds = <Map<String, dynamic>>[];
      final csub = core.commands.stream.listen(cmds.add);
      backend.probe(7, const [ProbeTarget('example.com', 443)]);
      await _until(() => cmds.isNotEmpty);
      expect(cmds.single['cmd'], 'probe');

      // Lightweight mode again from the re-attached UI.
      final port = await backend.detach(token: token, restore: const {});
      expect(port, core.port);

      await backend.stop();
      await _until(() => events.whereType<ExitEvent>().isNotEmpty);
      expect(cmds.map((c) => c['cmd']), containsAllInOrder(['probe', 'detach', 'stop']));
      expect(events.whereType<ExitEvent>().single.code, 0);
      expect(events.whereType<StateEvent>().last.state, CoreState.stopped);
      await csub.cancel();
      await sub.cancel();
    });

    test('reattach fails cleanly when the core is gone', () async {
      final port = core.port;
      await core.close();
      final backend = DesktopCoreBackend();
      expect(await backend.reattach(AttachInfo(port: port, token: token), timeout: const Duration(seconds: 1)), isFalse);
      expect(await backend.reattach(const AttachInfo(port: 1, token: 'x')), isFalse);
    });
  });

  group('protocol', () {
    test('detached and pong events', () {
      final d = CoreEvent.parse({'type': 'detached', 'ok': true, 'port': 51000, 'pid': 9});
      expect(d, isA<DetachedEvent>().having((e) => e.port, 'port', 51000).having((e) => e.pid, 'pid', 9));
      final p = CoreEvent.parse({'type': 'pong', 'state': 'connected', 'pid': 9});
      expect(p, isA<PongEvent>().having((e) => e.state, 'state', CoreState.connected));
    });
  });

  group('system proxy restore plan for the core', () {
    test('macOS: snapshot to networksetup commands', () {
      final cmds = SystemProxy.restoreCommands({
        'mac': {
          'Wi-Fi': {
            'web': {'enabled': true, 'server': '10.0.0.1', 'port': 3128},
            'secure': {'enabled': false, 'server': '', 'port': 0},
            'socks': {'enabled': false},
            'bypass': <String>[],
          },
        },
      }, os: 'macos');
      expect(cmds, [
        ['networksetup', '-setwebproxy', 'Wi-Fi', '10.0.0.1', '3128'],
        ['networksetup', '-setsecurewebproxystate', 'Wi-Fi', 'off'],
        ['networksetup', '-setsocksfirewallproxystate', 'Wi-Fi', 'off'],
        ['networksetup', '-setproxybypassdomains', 'Wi-Fi', 'Empty'],
      ]);
    });

    test('macOS without a snapshot switches every proxy off', () {
      final cmds = SystemProxy.restoreCommands(const {}, os: 'macos', macServices: ['Wi-Fi', 'Ethernet']);
      expect(cmds, hasLength(6));
      expect(cmds.every((c) => c.first == 'networksetup' && c.last == 'off'), isTrue);
    });

    test('Linux: gsettings with mode last, KDE when present', () {
      final cmds = SystemProxy.restoreCommands({
        'gnome': {
          'org.gnome.system.proxy mode': "'none'",
          'org.gnome.system.proxy.http host': "''",
        },
        'kde': {'ProxyType': '0'},
      }, os: 'linux', kdeTool: '/usr/bin/kwriteconfig6');
      expect(cmds.first, ['gsettings', 'set', 'org.gnome.system.proxy.http', 'host', "''"]);
      expect(cmds[1], ['gsettings', 'set', 'org.gnome.system.proxy', 'mode', "'none'"]);
      expect(cmds[2].first, '/usr/bin/kwriteconfig6');
      expect(cmds.last.first, 'dbus-send');
      // Only binaries the core accepts (attach.go allowedRestoreExec).
      const allowed = {'networksetup', 'gsettings', 'dbus-send', 'kwriteconfig', 'kwriteconfig5', 'kwriteconfig6'};
      expect(cmds.every((c) => allowed.contains(c.first.split('/').last)), isTrue);
    });

    test('Linux without a snapshot: proxy mode none', () {
      expect(SystemProxy.restoreCommands(const {}, os: 'linux'), [
        ['gsettings', 'set', 'org.gnome.system.proxy', 'mode', 'none'],
      ]);
    });

    test('Windows WinINet values in the core field names', () {
      expect(SystemProxy.winProxyPlan({'enable': 1, 'server': 'p:1', 'bypass': '<local>', 'autoConfigUrl': null}),
          {'enable': 1, 'server': 'p:1', 'bypass': '<local>', 'autoConfigUrl': null});
      expect(SystemProxy.winProxyPlan({'enable': '0'})['enable'], 0);
    });
  });
}

class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

Future<void> _until(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
