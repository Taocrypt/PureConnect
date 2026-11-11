import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/backend.dart';
import '../core/backup.dart';
import '../core/config_builder.dart';
import '../core/errors.dart';
import '../core/extra_args.dart';
import '../core/notify.dart';
import '../core/updater.dart' show currentAppVersion;
import '../l10n/strings.dart';
import '../core/protocol.dart';
import '../core/system_proxy.dart';
import '../models/profile.dart';
import '../models/settings.dart';

/// Overridden in main() once SharedPreferences is loaded.
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError());

final dataDirProvider = Provider<String>((ref) => throw UnimplementedError());

Future<String> resolveDataDir() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return dir.path;
}

// --------------------------------------------------------------------------
// Settings & profiles (persisted as JSON in SharedPreferences)
// --------------------------------------------------------------------------

/// WebDAV account for backups. Kept apart from AppSettings so a restore
/// never overwrites the account it was fetched with.
class DavNotifier extends Notifier<DavConfig?> {
  static const _key = 'webdav.v1';

  @override
  DavConfig? build() {
    final raw = ref.read(prefsProvider).getString(_key);
    if (raw == null) return null;
    try {
      return DavConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  void set(DavConfig? c) {
    state = c;
    final prefs = ref.read(prefsProvider);
    if (c == null) {
      prefs.remove(_key);
    } else {
      prefs.setString(_key, jsonEncode(c.toJson()));
    }
  }
}

final davProvider = NotifierProvider<DavNotifier, DavConfig?>(DavNotifier.new);

class BackupPrefsNotifier extends Notifier<BackupPrefs> {
  static const _key = 'backup.v1';

  @override
  BackupPrefs build() {
    final raw = ref.read(prefsProvider).getString(_key);
    if (raw == null) return const BackupPrefs();
    try {
      return BackupPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const BackupPrefs();
    }
  }

  void set(BackupPrefs p) {
    state = p;
    ref.read(prefsProvider).setString(_key, jsonEncode(p.toJson()));
  }
}

final backupPrefsProvider = NotifierProvider<BackupPrefsNotifier, BackupPrefs>(BackupPrefsNotifier.new);

/// WebDAV auto backup (off / after changes / daily). Kept alive by the
/// home shell; failures are recorded on the backup page and in the log.
class AutoBackupNotifier extends Notifier<bool> {
  Timer? _debounce;
  Timer? _daily;
  bool _running = false;

  @override
  bool build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _daily?.cancel();
    });
    ref.listen(settingsProvider, (_, _) => _changed());
    ref.listen(profilesProvider, (_, _) => _changed());
    final mode = ref.watch(backupPrefsProvider.select((p) => p.auto));
    final bound = ref.watch(davProvider.select((d) => d != null));
    _daily?.cancel();
    if (mode == AutoBackup.daily && bound) {
      _daily = Timer.periodic(const Duration(hours: 1), (_) => _dailyCheck());
      Future.delayed(const Duration(seconds: 20), _dailyCheck);
    }
    return false;
  }

  void _changed() {
    if (ref.read(backupPrefsProvider).auto != AutoBackup.onChange || ref.read(davProvider) == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 30), _run);
  }

  void _dailyCheck() {
    final p = ref.read(backupPrefsProvider);
    if (p.auto != AutoBackup.daily || ref.read(davProvider) == null) return;
    final last = p.lastAuto;
    if (last == null || DateTime.now().difference(last) >= const Duration(hours: 24)) _run();
  }

  /// Builds this device's backup document.
  Future<Uint8List> buildBackup({bool? includeSecrets}) => encodeBackupAsync(
        profiles: [for (final p in ref.read(profilesProvider)) p.toJson()],
        settings: ref.read(settingsProvider).toJson(),
        includeSecrets: includeSecrets ?? ref.read(backupPrefsProvider).includeSecrets,
        device: ref.read(davProvider)?.device ?? defaultDeviceName(),
        password: ref.read(backupPrefsProvider).password,
      );

  /// Uploads a backup to WebDAV and prunes this device's old ones.
  Future<void> backupToDav() async {
    final c = ref.read(davProvider);
    if (c == null) throw StateError('WebDAV not bound');
    final client = DavClient(c);
    try {
      await client.upload(remoteBackupName(c.device), await buildBackup(),
          device: c.device, keep: ref.read(backupPrefsProvider).keep);
    } finally {
      client.close();
    }
  }

  /// Applies a backup with the chosen scope and the saved restore strategy.
  void applyBackup(BackupData d, RestoreOption opt) {
    final strategy = ref.read(backupPrefsProvider).strategy;
    final merged = mergeProfiles([for (final p in ref.read(profilesProvider)) p.toJson()], d.profiles, strategy);
    final profiles = [for (final p in merged) Profile.fromJson(p)];
    if (profiles.isNotEmpty) ref.read(profilesProvider.notifier).replaceAll(profiles);
    final s = d.settings;
    if (opt == RestoreOption.all && s != null) {
      final restored = AppSettings.fromJson(s);
      // Apps picked on this phone stay when the backup has none (desktop).
      if (restored.bypassApps.isEmpty) restored.bypassApps..clear()..addAll(ref.read(settingsProvider).bypassApps);
      ref.read(settingsProvider.notifier).replace(restored);
    }
    final sel = ref.read(settingsProvider).selectedProfileId;
    if (profiles.isNotEmpty && !profiles.any((p) => p.id == sel)) {
      ref.read(settingsProvider.notifier).update((x) => x.selectedProfileId = profiles.first.id);
    }
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    state = true;
    final prefs = ref.read(backupPrefsProvider.notifier);
    try {
      await backupToDav();
      prefs.set(ref.read(backupPrefsProvider).copyWith(lastAuto: DateTime.now(), lastAutoError: null));
      ref.read(logsProvider.notifier).add(LogEntry(DateTime.now(), 'info', 'Auto backup uploaded to WebDAV'));
    } catch (e) {
      prefs.set(ref.read(backupPrefsProvider).copyWith(lastAuto: DateTime.now(), lastAutoError: '$e'));
      ref.read(logsProvider.notifier).add(LogEntry(DateTime.now(), 'warning', 'Auto backup failed: $e'));
    } finally {
      _running = false;
      if (ref.mounted) state = false;
    }
  }
}

final autoBackupProvider = NotifierProvider<AutoBackupNotifier, bool>(AutoBackupNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _key = 'settings.v1';

  @override
  AppSettings build() {
    final raw = ref.read(prefsProvider).getString(_key);
    if (raw == null) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  /// Restore: replace all settings at once.
  void replace(AppSettings next) {
    state = next;
    ref.read(prefsProvider).setString(_key, jsonEncode(next.toJson()));
  }

  void update(void Function(AppSettings s) change) {
    final next = state.copy();
    change(next);
    state = next;
    ref.read(prefsProvider).setString(_key, jsonEncode(next.toJson()));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class ProfilesNotifier extends Notifier<List<Profile>> {
  static const _key = 'profiles.v1';

  @override
  List<Profile> build() {
    final raw = ref.read(prefsProvider).getString(_key);
    if (raw != null) {
      try {
        return (jsonDecode(raw) as List)
            .map((e) => Profile.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      } catch (_) {}
    }
    return [];
  }

  void _save(List<Profile> list) {
    state = list;
    ref.read(prefsProvider).setString(_key, jsonEncode([for (final p in list) p.toJson()]));
  }

  void upsert(Profile p) {
    final list = [...state];
    final i = list.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      list[i] = p;
    } else {
      list.add(p);
    }
    _save(list);
  }

  void remove(String id) => _save(state.where((e) => e.id != id).toList());

  void reorder(int oldIndex, int newIndex) {
    // newIndex is already adjusted for the removed item (onReorderItem).
    final list = [...state];
    list.insert(newIndex, list.removeAt(oldIndex));
    _save(list);
  }
}

extension ProfilesReplace on ProfilesNotifier {
  /// Restore: replace every profile with the backup's.
  void replaceAll(List<Profile> list) => _save(list);
}

final profilesProvider = NotifierProvider<ProfilesNotifier, List<Profile>>(ProfilesNotifier.new);

final selectedProfileProvider = Provider<Profile?>((ref) {
  final profiles = ref.watch(profilesProvider);
  final id = ref.watch(settingsProvider.select((s) => s.selectedProfileId));
  if (profiles.isEmpty) return null;
  return profiles.firstWhere((p) => p.id == id, orElse: () => profiles.first);
});

// --------------------------------------------------------------------------
// Logs
// --------------------------------------------------------------------------

class LogsNotifier extends Notifier<List<LogEntry>> {
  static const max = 3000;
  File? _file;
  IOSink? _sink;

  @override
  List<LogEntry> build() {
    ref.onDispose(() => _sink?.close());
    try {
      final f = File('${ref.read(dataDirProvider)}${Platform.pathSeparator}logs.jsonl');
      _file = f;
      if (!f.existsSync()) return const [];
      final lines = f.readAsLinesSync();
      final tail = lines.length > max ? lines.sublist(lines.length - max) : lines;
      if (lines.length > max * 2) f.writeAsStringSync('${tail.join('\n')}\n');
      final out = <LogEntry>[];
      for (final l in tail) {
        try {
          final j = jsonDecode(l) as Map<String, dynamic>;
          out.add(LogEntry(DateTime.fromMillisecondsSinceEpoch(j['t'] as int), j['l'] as String, j['m'] as String));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  void add(LogEntry e) {
    final next = state.length >= max ? state.sublist(state.length - max + 1) : [...state];
    next.add(e);
    state = next;
    try {
      _sink ??= _file?.openWrite(mode: FileMode.append);
      _sink?.writeln(jsonEncode({'t': e.time.millisecondsSinceEpoch, 'l': e.level, 'm': e.message}));
    } catch (_) {}
  }

  void clear() {
    state = const [];
    try {
      _sink?.close();
      _sink = null;
      _file?.writeAsStringSync('');
    } catch (_) {}
  }
}

/// Connection topology pushed by the core every couple of seconds.
class FlowsNotifier extends Notifier<List<FlowInfo>> {
  @override
  List<FlowInfo> build() => const [];
  void set(List<FlowInfo> v) => state = v;
}

/// External proxy health: null = unknown / not used.
class ProxyHealth {
  const ProxyHealth(this.ok, this.proxy);
  final bool ok;
  final String proxy;
}

class ProxyHealthNotifier extends Notifier<ProxyHealth?> {
  @override
  ProxyHealth? build() => null;
  void set(ProxyHealth? v) => state = v;
}

final proxyHealthProvider = NotifierProvider<ProxyHealthNotifier, ProxyHealth?>(ProxyHealthNotifier.new);

/// Settings that only take effect on the next connection, as JSON.
String connectionSettingsKey(AppSettings s) {
  final j = s.toJson();
  for (final k in const ['favoriteResources', 'browserPackage', 'themeMode', 'seedColor', 'appIcon', 'useDynamicColor', 'locale', 'autoConnect', 'closeToTray', 'silentStart', 'hideDockIcon', 'shareWarningSeen', 'autoCheckUpdate', 'autoReconnect', 'reconnectDelay', 'notifications', 'minimizeToTray', 'warnProxyOverride', 'setupGuideShown']) {
    j.remove(k);
  }
  return jsonEncode(j);
}

/// Snapshot of [connectionSettingsKey] taken when the current connection started.
class AppliedSettingsNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

final appliedSettingsProvider = NotifierProvider<AppliedSettingsNotifier, String?>(AppliedSettingsNotifier.new);

/// True while connected with settings changed since the connection started.
final settingsPendingProvider = Provider<bool>((ref) {
  final snap = ref.watch(appliedSettingsProvider);
  if (snap == null || !ref.watch(coreProvider.select((c) => c.isActive))) return false;
  return snap != ref.watch(settingsProvider.select(connectionSettingsKey));
});

enum ProbeStatus { testing, ok, slow, fail }

class ProbeState {
  const ProbeState(this.status, {this.ms = 0, this.error});
  final ProbeStatus status;
  final int ms;
  final String? error;
}

/// Latency (ms) at or above which a reachable host shows orange (the core
/// retries with 1s, 3s, then 5s timeouts before calling it unreachable).
const probeSlowMs = 1000;

/// Connectivity test results by ProbeTarget.key (host#port as requested).
class ProbeNotifier extends Notifier<Map<String, ProbeState>> {
  int _nextId = 1;
  final _pending = <String, ProbeTarget>{}; // "host#reqPort" -> target

  @override
  Map<String, ProbeState> build() => const {};

  void run(List<ProbeTarget> targets) {
    if (targets.isEmpty) return;
    state = {...state, for (final t in targets) t.key: const ProbeState(ProbeStatus.testing)};
    for (final t in targets) {
      _pending[t.key] = t;
    }
    ref.read(backendProvider).probe(_nextId++, targets);
  }

  void onResult(ProbeEvent e) {
    // The core reports the port it ended up using; match the request.
    final key = _pending.containsKey('${e.host}#${e.port}')
        ? '${e.host}#${e.port}'
        : _pending.containsKey('${e.host}#0')
            ? '${e.host}#0'
            : '${e.host}#${e.port}';
    _pending.remove(key);
    state = {
      ...state,
      key: e.ok
          ? ProbeState(e.ms >= probeSlowMs ? ProbeStatus.slow : ProbeStatus.ok, ms: e.ms)
          : ProbeState(ProbeStatus.fail, error: e.error),
    };
  }

  void clear() {
    _pending.clear();
    state = const {};
  }
}

final probeProvider = NotifierProvider<ProbeNotifier, Map<String, ProbeState>>(ProbeNotifier.new);

class TrafficNotifier extends Notifier<TrafficStats> {
  @override
  TrafficStats build() => TrafficStats.zero;
  void set(TrafficStats v) => state = v;
}

final trafficProvider = NotifierProvider<TrafficNotifier, TrafficStats>(TrafficNotifier.new);

final flowsProvider = NotifierProvider<FlowsNotifier, List<FlowInfo>>(FlowsNotifier.new);

final logsProvider = NotifierProvider<LogsNotifier, List<LogEntry>>(LogsNotifier.new);

// --------------------------------------------------------------------------
// Core status
// --------------------------------------------------------------------------

class CoreStatus {
  const CoreStatus({
    this.state = CoreState.idle,
    this.error,
    this.session,
    this.startedAt,
    this.version = '',
    this.profileName = '',
    this.trafficMode,
    this.challenges = const [],
    this.reconnectAt,
  });

  final CoreState state;
  final String? error;
  final SessionInfo? session;
  final DateTime? startedAt;
  final String version;
  final String profileName;
  final TrafficMode? trafficMode;
  final List<Challenge> challenges;

  /// Auto reconnect is waiting until this time (state stays error/stopped).
  final DateTime? reconnectAt;

  bool get isBusy =>
      state == CoreState.starting || state == CoreState.connecting || state == CoreState.stopping;
  bool get isConnected => state == CoreState.connected;
  /// Busy, connected, or waiting to reconnect (the button then disconnects).
  bool get isActive => isBusy || isConnected || reconnectAt != null;

  CoreStatus copyWith({
    CoreState? state,
    Object? error = _keep,
    Object? session = _keep,
    Object? startedAt = _keep,
    String? version,
    String? profileName,
    Object? trafficMode = _keep,
    List<Challenge>? challenges,
    Object? reconnectAt = _keep,
  }) =>
      CoreStatus(
        state: state ?? this.state,
        error: error == _keep ? this.error : error as String?,
        session: session == _keep ? this.session : session as SessionInfo?,
        startedAt: startedAt == _keep ? this.startedAt : startedAt as DateTime?,
        version: version ?? this.version,
        profileName: profileName ?? this.profileName,
        trafficMode: trafficMode == _keep ? this.trafficMode : trafficMode as TrafficMode?,
        challenges: challenges ?? this.challenges,
        reconnectAt: reconnectAt == _keep ? this.reconnectAt : reconnectAt as DateTime?,
      );

  static const _keep = Object();
}

final backendProvider = Provider<CoreBackend>((ref) => CoreBackend.create());

class CoreController extends Notifier<CoreStatus> {
  StreamSubscription<CoreEvent>? _sub;
  bool _systemProxySet = false;

  // Auto reconnect / disconnect notification bookkeeping.
  bool _userStop = false;
  bool _wasConnected = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  /// Linux `sudo -S` password of this run, kept in memory only so an
  /// automatic reconnect in TUN mode can start the core again.
  String? _sudoPassword;
  static const maxReconnectAttempts = 20;

  /// Errors worth retrying: the tunnel or network went away, not the login.
  static const reconnectableErrors = {
    'session_expired', 'shutdown', 'reconnect_later', 'tunnel', 'network', 'dns', 'no_node', 'core_crashed',
  };

  static bool isReconnectable(String? error) {
    if (error == null) return true;
    final key = errorKey(error);
    return key == null || reconnectableErrors.contains(key);
  }

  S get _s {
    final l = ref.read(settingsProvider).locale;
    final lang = l.isNotEmpty ? l : PlatformDispatcher.instance.locale.languageCode;
    return S(lang == 'zh' ? 'zh' : 'en');
  }

  void _notify(String title, String body) {
    if (ref.read(settingsProvider).notifications) SystemNotify.show(title, body);
  }

  @override
  CoreStatus build() {
    final backend = ref.read(backendProvider);
    _sub = backend.events.listen(_onEvent);
    ref.onDispose(() => _sub?.cancel());
    if (backend is AndroidCoreBackend) {
      // Re-attach to a session that kept running while the UI was gone.
      Future.microtask(backend.requestReplay);
    }
    return const CoreStatus();
  }

  void _log(String level, String msg) =>
      ref.read(logsProvider.notifier).add(LogEntry(DateTime.now(), level, msg));

  void _onEvent(CoreEvent ev) {
    switch (ev) {
      case HelloEvent(:final version):
        state = state.copyWith(version: version);
      case LogEvent(:final entry):
        ref.read(logsProvider.notifier).add(entry);
      case RawLogEvent(:final entry):
        ref.read(logsProvider.notifier).add(entry);
      case StateEvent(state: final s, :final error):
        if (s == CoreState.connecting) ref.read(trafficProvider.notifier).set(TrafficStats.zero);
        if (s == CoreState.connected) {
          _wasConnected = true;
          _reconnectAttempts = 0;
          state = state.copyWith(state: s, error: null, startedAt: state.startedAt ?? DateTime.now());
          _applySystemProxy();
        } else if (s == CoreState.error) {
          state = state.copyWith(state: s, error: error, challenges: const []);
          if (error != null) _log('error', error);
        } else if (state.state == CoreState.error &&
            (s == CoreState.stopping || s == CoreState.stopped)) {
          // Keep the error visible while the core shuts itself down.
          if (s == CoreState.stopped) _onStopped(keepError: true);
        } else if (s == CoreState.stopped) {
          _onStopped();
        } else {
          state = state.copyWith(state: s);
        }
      case ChallengeEvent(:final challenge):
        state = state.copyWith(challenges: [...state.challenges, challenge]);
      case SessionEvent(:final session):
        state = state.copyWith(session: session);
      case ExitEvent(:final code):
        final prev = state.state;
        if (prev == CoreState.error) {
          _onStopped(keepError: true);
        } else if (prev != CoreState.stopped && prev != CoreState.idle) {
          // Exited without saying goodbye (crash, killed, panic).
          _onStopped();
          if (code != 0) {
            state = state.copyWith(state: CoreState.error, error: 'core exited with code $code');
          }
        }
      case FlowsEvent(:final flows):
        ref.read(flowsProvider.notifier).set(flows);
      case ProbeEvent():
        ref.read(probeProvider.notifier).onResult(ev);
      case TrafficEvent(:final stats):
        ref.read(trafficProvider.notifier).set(stats);
      case ProxyStatusEvent(:final ok, :final proxy):
        ref.read(proxyHealthProvider.notifier).set(ProxyHealth(ok, proxy));
      case ResultEvent():
        break;
    }
  }

  void _onStopped({bool keepError = false}) {
    final error = keepError ? state.error : null;
    _clearSystemProxy();
    ref.read(flowsProvider.notifier).set(const []);
    ref.read(trafficProvider.notifier).set(TrafficStats.zero);
    ref.read(appliedSettingsProvider.notifier).set(null);
    ref.read(probeProvider.notifier).clear();
    ref.read(proxyHealthProvider.notifier).set(null);
    state = CoreStatus(
      state: keepError ? CoreState.error : CoreState.stopped,
      error: error,
      version: state.version,
    );
    _afterDrop(error);
  }

  /// The session ended without the user asking: notify, and reconnect when
  /// that is turned on and the cause is one a retry can fix.
  void _afterDrop(String? error) {
    if (_userStop || _reconnectTimer != null) return;
    final wasConnected = _wasConnected;
    final retrying = _reconnectAttempts > 0;
    _wasConnected = false;
    if (!wasConnected && !retrying) return;
    final settings = ref.read(settingsProvider);
    final s = _s;
    final reason = error == null ? '' : humanizeErrorIn(s.lang, error);
    final canRetry = settings.autoReconnect &&
        isReconnectable(error) &&
        _reconnectAttempts < maxReconnectAttempts &&
        ref.read(selectedProfileProvider) != null;
    if (!canRetry) {
      _reconnectAttempts = 0;
      if (wasConnected) _notify(s.t('notify_dropped'), reason);
      return;
    }
    final delay = settings.reconnectDelay.clamp(1, 3600);
    _reconnectAttempts++;
    final at = DateTime.now().add(Duration(seconds: delay));
    state = state.copyWith(reconnectAt: at);
    final msg = s.t('notify_reconnecting', {'s': '$delay'});
    _log('warning', '$msg ($_reconnectAttempts/$maxReconnectAttempts)');
    if (wasConnected) _notify(s.t('notify_dropped'), reason.isEmpty ? msg : '$reason\n$msg');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      _reconnectTimer = null;
      if (_userStop || state.reconnectAt == null) return;
      state = state.copyWith(reconnectAt: null);
      connect(sudoPassword: _sudoPassword, reconnect: true);
    });
  }

  /// The core opens PCAP / TLS key-log files but does not create folders.
  void _ensureDebugDir() {
    final s = ref.read(settingsProvider);
    if (!s.debugPcap && !s.debugTlsKeyLog) return;
    try {
      Directory(debugDir(ref.read(dataDirProvider))).createSync(recursive: true);
    } catch (_) {}
  }

  /// Stops a pending automatic reconnect.
  void cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    if (state.reconnectAt != null) state = state.copyWith(reconnectAt: null);
  }

  Future<void> _applySystemProxy() async {
    final s = ref.read(settingsProvider);
    final mode = state.trafficMode;
    if (mode == null || !s.setsSystemProxy(mode, android: Platform.isAndroid)) return;
    try {
      _systemProxySet = true;
      await SystemProxy.enable(
          dataDir: ref.read(dataDirProvider),
          httpPort: s.httpPort,
          socksPort: s.socksPort,
          extraBypass: s.systemProxyBypassList);
      _log('info', 'System proxy enabled');
    } catch (e) {
      _log('warning', 'System proxy: $e');
    }
  }

  Future<void> _clearSystemProxy() async {
    if (!_systemProxySet) return;
    _systemProxySet = false;
    await SystemProxy.disable(ref.read(dataDirProvider));
    _log('info', 'System proxy restored');
  }

  /// Credentials typed at connect time and not saved (kept for reconnects).
  Profile? _oneTimeProfile;

  Future<void> connect({String? sudoPassword, bool reconnect = false, Profile? profileOverride}) async {
    if (!reconnect) {
      cancelReconnect();
      _oneTimeProfile = profileOverride;
    }
    if (state.isActive) return;
    _userStop = false;
    _wasConnected = false;
    if (sudoPassword != null) _sudoPassword = sudoPassword;
    final selected = ref.read(selectedProfileProvider);
    final profile = _oneTimeProfile != null && _oneTimeProfile!.id == selected?.id ? _oneTimeProfile : selected;
    if (profile == null) {
      state = state.copyWith(state: CoreState.error, error: 'No profile selected');
      return;
    }
    final settings = ref.read(settingsProvider);
    final dataDir = ref.read(dataDirProvider);
    final android = Platform.isAndroid;
    final tun = settings.trafficMode == TrafficMode.tun;
    if (settings.extraArgs.trim().isNotEmpty) {
      final errs = parseExtraArgs(settings.extraArgs).errors;
      if (errs.isNotEmpty) {
        final msg = 'config: extra options: ${errs.join('; ')}';
        state = state.copyWith(state: CoreState.error, error: msg);
        _log('error', msg);
        return;
      }
    }
    _ensureDebugDir();
    final config = buildCoreConfig(
        profile: profile, settings: settings, dataDir: dataDir, android: android);
    ref.read(appliedSettingsProvider.notifier).set(connectionSettingsKey(settings));
    state = CoreStatus(
      state: CoreState.starting,
      version: state.version,
      profileName: profile.name,
      trafficMode: settings.trafficMode,
    );
    if (!reconnect) {
      final v = await currentAppVersion().catchError((_) => '');
      _log('info', 'PureConnect ${v.isEmpty ? '' : 'v$v '}on ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    }
    _log('info', 'Connecting to ${profile.effectiveServer} (${profile.protocol.name}, ${settings.trafficMode.name})');
    try {
      await ref.read(backendProvider).start(
            config: config,
            tun: tun,
            workDir: dataDir,
            sudoPassword: sudoPassword,
          );
    } catch (e) {
      state = state.copyWith(state: CoreState.error, error: e.toString());
      _log('error', e.toString());
    }
  }

  Future<void> disconnect() async {
    _userStop = true;
    final pending = state.reconnectAt != null;
    cancelReconnect();
    if (state.state == CoreState.idle || state.state == CoreState.stopped) return;
    if (pending && state.state == CoreState.error) {
      state = CoreStatus(state: CoreState.stopped, version: state.version);
      return;
    }
    for (final c in state.challenges) {
      ref.read(backendProvider).respond(c.id, const ChallengeAnswer.cancelled());
    }
    state = state.copyWith(state: CoreState.stopping, challenges: const []);
    await ref.read(backendProvider).stop();
    await _clearSystemProxy();
    if (state.state == CoreState.stopping) _onStopped();
  }

  /// App exit: stop the core and put the system proxy back (bounded, so a
  /// stuck core never blocks quitting).
  Future<void> shutdown() async {
    try {
      await disconnect().timeout(const Duration(seconds: 8));
    } catch (_) {}
    try {
      await _clearSystemProxy().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Waits (bounded) until the core has fully stopped.
  Future<void> waitStopped({Duration timeout = const Duration(seconds: 8)}) async {
    final end = DateTime.now().add(timeout);
    while (state.isActive && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> toggle({String? sudoPassword}) =>
      state.isActive ? disconnect() : connect(sudoPassword: sudoPassword);

  void answer(Challenge c, ChallengeAnswer a) {
    ref.read(backendProvider).respond(c.id, a);
    state = state.copyWith(challenges: state.challenges.where((e) => e.id != c.id).toList());
  }

  /// aTrust: list the auth methods the server offers.
  Future<ResultEvent> fetchAuthInfo(Profile profile) {
    _ensureDebugDir();
    final cfg = buildCoreConfig(
        profile: profile,
        settings: ref.read(settingsProvider),
        dataDir: ref.read(dataDirProvider),
        android: Platform.isAndroid);
    return ref.read(backendProvider).oneShot({'cmd': 'auth_info', 'config': cfg});
  }

  /// aTrust: trust / untrust this device (needs saved client data).
  Future<ResultEvent> setTrusted(Profile profile, bool trust) {
    _ensureDebugDir();
    final cfg = buildCoreConfig(
        profile: profile,
        settings: ref.read(settingsProvider),
        dataDir: ref.read(dataDirProvider),
        android: Platform.isAndroid);
    return ref.read(backendProvider).oneShot({'cmd': 'trust_device', 'config': cfg, 'trust': trust});
  }
}

final coreProvider = NotifierProvider<CoreController, CoreStatus>(CoreController.new);
