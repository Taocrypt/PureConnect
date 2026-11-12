import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'protocol.dart';

/// Lightweight mode (轻量模式): after the window has been hidden (desktop: in
/// the tray; Android: app in the background) for N minutes, the UI exits
/// completely and only zjuconnect-core keeps the VPN / proxy running.
///
/// Desktop: the UI sends `detach` to the core, which then outlives it and
/// listens on a loopback port; the port and a random token are kept in
/// [attachFileName] in the app data dir (user-only permissions). The next
/// launch re-attaches there ([pingDetachedCore], then
/// DesktopCoreBackend.reattach). There is no tray icon while the UI is gone:
/// opening the app again (Start menu, Dock, launcher, autostart) re-attaches.
///
/// Android: CoreService already owns the core; the activity is finished (the
/// Flutter engine goes away) and the VPN notification stays. Tapping it opens
/// the app, which replays the running session.
class Lightweight {
  static const attachFileName = 'core_attach.json';
  static const exitNoteName = 'core_exit.json';
  static const defaultMinutes = 3;
  static const minMinutes = 1;
  static const maxMinutes = 1440;

  static File attachFile(String dataDir) => File(p.join(dataDir, attachFileName));
  static File exitNoteFile(String dataDir) => File(p.join(dataDir, exitNoteName));

  /// 32 random bytes as hex (64 chars; the core wants at least 32).
  static String newToken([Random? rnd]) {
    final r = rnd ?? Random.secure();
    return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static AttachInfo? read(String dataDir) {
    try {
      final f = attachFile(dataDir);
      if (!f.existsSync()) return null;
      return AttachInfo.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Writes the attach file readable by the user only (it holds the token).
  static Future<void> write(String dataDir, AttachInfo info) async {
    final f = attachFile(dataDir);
    final tmp = File('${f.path}.tmp');
    if (!Platform.isWindows) {
      // Create empty, lock down, then fill: the token never sits in a
      // world-readable file, not even briefly.
      await tmp.writeAsString('', flush: true);
      try {
        await Process.run('chmod', ['600', tmp.path]);
      } catch (_) {}
    }
    await tmp.writeAsString(jsonEncode(info.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  static void remove(String dataDir) {
    try {
      final f = attachFile(dataDir);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// The error a detached core stopped with while no UI was around (kicked
  /// offline, tunnel died), consumed once.
  static String? takeExitNote(String dataDir) {
    try {
      final f = exitNoteFile(dataDir);
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      f.deleteSync();
      final e = (j['error'] as String? ?? '').trim();
      return e.isEmpty ? 'core exited with code ${j['code']}' : e;
    } catch (_) {
      try {
        exitNoteFile(dataDir).deleteSync();
      } catch (_) {}
      return null;
    }
  }

  /// The first line a UI sends on the attach port.
  static String handshake(String token, {bool ping = false}) =>
      jsonEncode({'token': token, 'mode': ping ? 'ping' : 'attach'});
}

/// What a re-launched UI needs to find and show a detached session.
class AttachInfo {
  const AttachInfo({
    this.port = 0,
    this.token = '',
    this.pid = 0,
    this.profileName = '',
    this.trafficMode = '',
    this.startedAt,
    this.applied,
  });

  final int port;
  final String token;
  final int pid;
  final String profileName;
  /// TrafficMode.name at connect time.
  final String trafficMode;
  final DateTime? startedAt;
  /// connectionSettingsKey of the running session (the "applies on next
  /// connection" banner).
  final String? applied;

  bool get canAttach => port > 0 && port < 65536 && token.length >= 32;

  Map<String, dynamic> toJson() => {
        'port': port,
        'token': token,
        'pid': pid,
        'profileName': profileName,
        'trafficMode': trafficMode,
        if (startedAt != null) 'startedAt': startedAt!.millisecondsSinceEpoch,
        if (applied != null) 'applied': applied,
      };

  factory AttachInfo.fromJson(Map<String, dynamic> j) => AttachInfo(
        port: (j['port'] as num?)?.toInt() ?? 0,
        token: j['token'] as String? ?? '',
        pid: (j['pid'] as num?)?.toInt() ?? 0,
        profileName: j['profileName'] as String? ?? '',
        trafficMode: j['trafficMode'] as String? ?? '',
        startedAt: j['startedAt'] is num ? DateTime.fromMillisecondsSinceEpoch((j['startedAt'] as num).toInt()) : null,
        applied: j['applied'] as String?,
      );

  AttachInfo copyWith({int? port, String? token, int? pid}) => AttachInfo(
        port: port ?? this.port,
        token: token ?? this.token,
        pid: pid ?? this.pid,
        profileName: profileName,
        trafficMode: trafficMode,
        startedAt: startedAt,
        applied: applied,
      );
}

/// Desktop launch check: is a detached core from an earlier run alive? A
/// stale attach file (core died, machine rebooted) is removed, so the caller
/// then restores a leftover system proxy as after any crash.
Future<AttachInfo?> pingDetachedCore(String dataDir, {Duration timeout = const Duration(seconds: 2)}) async {
  final info = Lightweight.read(dataDir);
  if (info == null) {
    Lightweight.remove(dataDir);
    return null;
  }
  if (!info.canAttach) {
    Lightweight.remove(dataDir);
    return null;
  }
  Socket? sock;
  try {
    sock = await Socket.connect(InternetAddress.loopbackIPv4, info.port, timeout: timeout);
    sock.writeln(Lightweight.handshake(info.token, ping: true));
    final line = await sock
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(timeout);
    final ev = CoreEvent.parse(jsonDecode(line) as Map<String, dynamic>);
    if (ev is PongEvent) return info.copyWith(pid: ev.pid);
  } catch (_) {
    // refused / timed out / wrong token: not ours any more
  } finally {
    sock?.destroy();
  }
  Lightweight.remove(dataDir);
  return null;
}

/// Starts the countdown once the window is hidden while connected, and
/// cancels it when the window comes back, the session ends or the setting
/// goes off. Pure logic (tested); the shells feed it.
class LightweightTimer {
  LightweightTimer({required this.onExpire, Timer Function(Duration, void Function())? timerFactory})
      : _factory = timerFactory ?? Timer.new;

  final FutureOr<void> Function() onExpire;
  final Timer Function(Duration, void Function()) _factory;
  Timer? _timer;
  Duration? _delay;

  bool get armed => _timer != null;
  Duration? get delay => _delay;

  static bool shouldArm({required bool enabled, required bool hidden, required bool connected}) =>
      enabled && hidden && connected;

  void update({required bool enabled, required int minutes, required bool hidden, required bool connected}) {
    if (!shouldArm(enabled: enabled, hidden: hidden, connected: connected)) {
      cancel();
      return;
    }
    final d = Duration(minutes: minutes.clamp(Lightweight.minMinutes, Lightweight.maxMinutes));
    if (_timer != null && d == _delay) return;
    _timer?.cancel();
    _delay = d;
    _timer = _factory(d, () {
      _timer = null;
      _delay = null;
      onExpire();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _delay = null;
  }
}
