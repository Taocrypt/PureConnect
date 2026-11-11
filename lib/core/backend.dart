import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'desktop_window.dart';
import 'protocol.dart';

/// Runs zjuconnect-core and turns its output into [CoreEvent]s.
abstract class CoreBackend {
  Stream<CoreEvent> get events;

  /// [tun] selects platform TUN: Android VpnService, or an elevated core on
  /// desktop (the config then carries `tun_mode: true`).
  Future<void> start({
    required Map<String, dynamic> config,
    required bool tun,
    required String workDir,
    String? sudoPassword,
  });

  Future<void> stop();

  void respond(int id, ChallengeAnswer answer);

  /// Connectivity test through the tunnel; results arrive as ProbeEvents.
  void probe(int id, List<ProbeTarget> targets);

  /// Runs a one-shot command (`auth_info`, `trust_device`) in a separate
  /// short-lived core process.
  Future<ResultEvent> oneShot(Map<String, dynamic> command);

  static CoreBackend create() =>
      Platform.isAndroid ? AndroidCoreBackend() : DesktopCoreBackend();
}

CoreEvent? _decodeLine(String line) {
  final t = line.trim();
  if (t.isEmpty) return null;
  try {
    final j = jsonDecode(t);
    if (j is Map<String, dynamic>) {
      switch (j['type']) {
        case 'raw':
          return RawLogEvent(LogEntry(DateTime.now(), j['level'] as String? ?? 'info',
              j['message'] as String? ?? ''));
        case 'exit':
          return ExitEvent((j['code'] as num?)?.toInt() ?? -1);
      }
      return CoreEvent.parse(j);
    }
  } catch (_) {}
  return RawLogEvent(LogEntry(DateTime.now(), 'info', t));
}

// ---------------------------------------------------------------------------
// Desktop: spawn the bundled binary directly.
// ---------------------------------------------------------------------------

/// One running core: a child process with pipes, or an elevated core that
/// dialled back over loopback TCP (Windows UAC / macOS admin prompt, where
/// the UI can't own the elevated process' pipes).
abstract class _CoreLink {
  Stream<String> get lines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  void send(String line);
  void kill();
  void markStopping() {}
}

class _ProcessLink implements _CoreLink {
  _ProcessLink(this.proc);
  final Process proc;

  @override
  Stream<String> get lines => proc.stdout.transform(utf8.decoder).transform(const LineSplitter());
  @override
  Stream<String> get stderrLines => proc.stderr.transform(utf8.decoder).transform(const LineSplitter());
  @override
  Future<int> get exitCode => proc.exitCode;
  @override
  void send(String line) {
    try {
      proc.stdin.writeln(line);
    } catch (_) {}
  }

  @override
  void kill() => proc.kill(ProcessSignal.sigkill);
  @override
  void markStopping() {}
}

class _SocketLink implements _CoreLink {
  _SocketLink(this.socket, this.lines, this._closed);
  final Socket socket;
  @override
  final Stream<String> lines;
  final Future<void> _closed;
  bool _stopping = false;

  @override
  Stream<String> get stderrLines => const Stream.empty();

  /// The elevated process' real exit code is out of reach: a close we asked
  /// for counts as 0, anything else (crash, killed) as 1.
  @override
  Future<int> get exitCode => _closed.then((_) => _stopping ? 0 : 1);

  @override
  void send(String line) {
    try {
      socket.writeln(line);
    } catch (_) {}
  }

  /// Closing the connection makes the core shut down (like closing stdin).
  @override
  void kill() => socket.destroy();

  @override
  void markStopping() => _stopping = true;
}

class DesktopCoreBackend implements CoreBackend {
  final _events = StreamController<CoreEvent>.broadcast();
  _CoreLink? _link;

  @override
  Stream<CoreEvent> get events => _events.stream;

  static String get binaryName =>
      Platform.isWindows ? 'zjuconnect-core.exe' : 'zjuconnect-core';

  /// Shown in the macOS administrator prompt.
  static String elevationPrompt = 'PureConnect 需要管理员权限来开启 TUN 模式。\n'
      'PureConnect needs administrator rights for TUN mode.';

  /// Looks for the core next to the executable (Windows/Linux bundles),
  /// in the macOS app's Resources, or via $ZJU_CONNECT_CORE.
  static String? locateBinary() {
    final env = Platform.environment['ZJU_CONNECT_CORE'];
    if (env != null && File(env).existsSync()) return env;
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      p.join(exeDir, binaryName),
      p.join(exeDir, 'lib', binaryName),
      p.join(exeDir, '..', 'Resources', binaryName),
      p.join(exeDir, 'data', binaryName),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return p.normalize(c);
    }
    return null;
  }

  static Future<bool> hasPkexec() async {
    if (!Platform.isLinux) return false;
    try {
      final r = await Process.run('sh', ['-c', 'command -v pkexec']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isWindowsAdmin() => DesktopWindow.isElevated();

  /// Desktop TUN needs an administrator password typed into the app only on
  /// Linux without pkexec (sudo -S). Windows uses UAC, macOS the system
  /// admin prompt, Linux pkexec's polkit dialog.
  static Future<bool> needsSudoPassword() async =>
      Platform.isLinux && !await hasPkexec();

  Future<_CoreLink> _spawn({bool elevated = false, String? sudoPassword}) async {
    final bin = locateBinary();
    if (bin == null) {
      throw StateError('zjuconnect-core not found. Build it with core/build.sh '
          'and place it next to the app (or set ZJU_CONNECT_CORE).');
    }
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', bin]);
      } catch (_) {}
    }
    if (!elevated) return _ProcessLink(await Process.start(bin, const []));

    if (Platform.isWindows) {
      if (await isWindowsAdmin()) return _ProcessLink(await Process.start(bin, const []));
      return _dialBack((addr, token) => _runAsWindows(bin, addr, token));
    }
    if (Platform.isMacOS) {
      return _dialBack((addr, token) => _runAsMac(bin, addr, token));
    }
    if (Platform.isLinux && sudoPassword == null && await hasPkexec()) {
      // pkexec keeps our stdin/stdout pipes, so the protocol keeps working.
      return _ProcessLink(await Process.start('pkexec', [bin]));
    }
    // Linux without pkexec: sudo reads the password from the first stdin
    // line, then hands stdin over to the core.
    final proc = await Process.start('sudo', ['-S', '-k', '-p', '', bin]);
    proc.stdin.writeln(sudoPassword ?? '');
    return _ProcessLink(proc);
  }

  /// Starts an elevated core with `--dial 127.0.0.1:<port> --token <t>` and
  /// waits for it to connect back. [launch] returns once the OS prompt was
  /// answered (it throws when the user declined).
  static Future<_CoreLink> _dialBack(Future<void> Function(String addr, String token) launch) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final rnd = Random.secure();
    final token = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final accepted = Completer<_CoreLink>();
    final sub = server.listen((sock) {
      final lines = StreamController<String>();
      final closed = Completer<void>();
      var authed = false;
      sock.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          if (authed) {
            lines.add(line);
          } else if (line.trim() == token && !accepted.isCompleted) {
            authed = true;
            accepted.complete(_SocketLink(sock, lines.stream, closed.future));
          } else {
            sock.destroy();
          }
        },
        onError: (_) {},
        onDone: () {
          lines.close();
          if (!closed.isCompleted) closed.complete();
        },
        cancelOnError: false,
      );
    });
    try {
      await launch('127.0.0.1:${server.port}', token);
      return await accepted.future.timeout(const Duration(seconds: 60),
          onTimeout: () => throw StateError('The elevated core did not start (no connection). '
              'TUN mode needs administrator rights.'));
    } finally {
      await sub.cancel();
      await server.close();
    }
  }

  /// Windows: UAC prompt through the runner (ShellExecuteEx "runas", no
  /// window, no PowerShell).
  static Future<void> _runAsWindows(String bin, String addr, String token) async {
    final r = await DesktopWindow.runElevated(bin, '--dial $addr --token $token', p.dirname(bin));
    if (r == null) throw StateError('Could not start the core as administrator');
    if (r.cancelled) throw StateError('Administrator authorization cancelled');
    if (!r.ok) throw StateError('Could not start the core as administrator (error ${r.error})');
  }

  /// macOS: the system administrator prompt via AppleScript. The core runs
  /// detached (as root) and connects back.
  static Future<void> _runAsMac(String bin, String addr, String token) async {
    String sh(String s) => "'${s.replaceAll("'", r"'\''")}'";
    String as(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    final shell = '${sh(bin)} --dial $addr --token $token >/dev/null 2>&1 &';
    final script = 'do shell script ${as(shell)} with prompt ${as(elevationPrompt)} with administrator privileges';
    final r = await Process.run('osascript', ['-e', script]);
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      if (err.contains('-128') || err.toLowerCase().contains('cancel')) {
        throw StateError('Administrator authorization cancelled');
      }
      throw StateError('Could not start the core as administrator: $err');
    }
  }

  void _attach(_CoreLink link, void Function(CoreEvent) sink) {
    link.lines.listen((line) {
      final ev = _decodeLine(line);
      if (ev != null) sink(ev);
    }, onError: (_) {});
    link.stderrLines.listen((line) {
      if (line.trim().isEmpty) return;
      sink(RawLogEvent(LogEntry(DateTime.now(),
          line.contains('panic') || line.contains('rror') ? 'error' : 'info', line)));
    }, onError: (_) {});
  }

  @override
  Future<void> start({
    required Map<String, dynamic> config,
    required bool tun,
    required String workDir,
    String? sudoPassword,
  }) async {
    await stop();
    final link = await _spawn(elevated: tun, sudoPassword: sudoPassword);
    _link = link;
    _attach(link, _events.add);
    unawaited(link.exitCode.then((code) {
      if (identical(_link, link)) _link = null;
      _events.add(ExitEvent(code));
    }));
    _send(link, {
      'cmd': 'start',
      'config': config,
      'tun': 'none',
      'work_dir': workDir,
    });
  }

  void _send(_CoreLink link, Map<String, dynamic> cmd) => link.send(jsonEncode(cmd));

  @override
  void probe(int id, List<ProbeTarget> targets) {
    final link = _link;
    if (link != null) {
      _send(link, {'cmd': 'probe', 'id': id, 'targets': [for (final t in targets) t.toJson()]});
    }
  }

  @override
  void respond(int id, ChallengeAnswer answer) {
    final link = _link;
    if (link != null) {
      _send(link, {'cmd': 'challenge_response', 'id': id, 'response': answer.toJson()});
    }
  }

  @override
  Future<void> stop() async {
    final link = _link;
    if (link == null) return;
    link.markStopping();
    _send(link, {'cmd': 'stop'});
    try {
      await link.exitCode.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      link.kill();
    }
    _link = null;
  }

  @override
  Future<ResultEvent> oneShot(Map<String, dynamic> command) async {
    final link = await _spawn();
    final proc = (link as _ProcessLink).proc;
    final done = Completer<ResultEvent>();
    _attach(link, (ev) {
      if (ev is ResultEvent && !done.isCompleted) done.complete(ev);
    });
    _send(link, command);
    try {
      return await done.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      return const ResultEvent(false, 'timeout', null);
    } finally {
      await proc.stdin.close();
      proc.kill();
    }
  }
}

// ---------------------------------------------------------------------------
// Android: the Kotlin CoreService owns the process (it must survive in the
// background and owns the VpnService TUN fd).
// ---------------------------------------------------------------------------

class AndroidCoreBackend implements CoreBackend {
  AndroidCoreBackend() {
    _eventChannel.receiveBroadcastStream().listen((dynamic line) {
      if (line is String) {
        final ev = _decodeLine(line);
        if (ev != null) _events.add(ev);
      }
    });
  }

  static const _method = MethodChannel('zju_connect/core');
  static const _eventChannel = EventChannel('zju_connect/events');
  final _events = StreamController<CoreEvent>.broadcast();

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  Future<void> start({
    required Map<String, dynamic> config,
    required bool tun,
    required String workDir,
    String? sudoPassword,
  }) async {
    final ok = await _method.invokeMethod<bool>('start', {
      'config': jsonEncode(config),
      'vpn': tun,
      'workDir': workDir,
    });
    if (ok != true) {
      throw StateError('VPN permission denied');
    }
  }

  @override
  Future<void> stop() => _method.invokeMethod('stop');

  @override
  void probe(int id, List<ProbeTarget> targets) {
    _method.invokeMethod('send', jsonEncode({
      'cmd': 'probe',
      'id': id,
      'targets': [for (final t in targets) t.toJson()],
    }));
  }

  @override
  void respond(int id, ChallengeAnswer answer) {
    _method.invokeMethod('send', jsonEncode({
      'cmd': 'challenge_response',
      'id': id,
      'response': answer.toJson(),
    }));
  }

  @override
  Future<ResultEvent> oneShot(Map<String, dynamic> command) async {
    final line = await _method.invokeMethod<String>('oneShot', jsonEncode(command));
    final ev = line == null ? null : _decodeLine(line);
    return ev is ResultEvent ? ev : const ResultEvent(false, 'no result', null);
  }

  /// Current state, replayed by the service after the UI (re)attaches.
  Future<void> requestReplay() => _method.invokeMethod('replay');
}
