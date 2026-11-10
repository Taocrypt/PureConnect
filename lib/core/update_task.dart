import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';
import 'notify.dart';
import 'updater.dart';

const _mirrorCacheKey = 'update.mirrorCache';

/// Built-in mirror candidates: the mirror list API (cached in prefs as the
/// last good list), else the cache, plus the hard-coded fallbacks.
Future<List<String>> loadMirrorCandidates(SharedPreferences prefs) async {
  final fetched = await fetchMirrorList();
  if (fetched.isNotEmpty) await prefs.setStringList(_mirrorCacheKey, fetched);
  return mergeMirrorCandidates(fetched, prefs.getStringList(_mirrorCacheKey) ?? const []);
}

/// Mirror candidates without network (cache + built-ins).
List<String> cachedMirrorCandidates(SharedPreferences prefs) =>
    mergeMirrorCandidates(const [], prefs.getStringList(_mirrorCacheKey) ?? const []);

/// Settings an update download follows.
class UpdateNetConfig {
  const UpdateNetConfig({required this.mode, required this.userMirrors, required this.prefs, required this.strings, this.notify = true});
  final MirrorMode mode;
  final List<String> userMirrors;
  final SharedPreferences prefs;
  final S strings;

  /// Desktop: system notification when the download finishes or fails.
  final bool notify;
}

enum UpdatePhase { probing, ready, downloading, done, failed, userMirrorsFailed }

/// One update download, kept outside the dialog so it carries on (with its
/// progress notification on Android) after the dialog is closed.
class UpdateDownloader extends ChangeNotifier {
  UpdateDownloader._(this.release, this.asset, this.config) {
    _prepare();
  }

  static UpdateDownloader? _current;

  /// The download for [release]: the running one when it is the same
  /// release, else a new one (testing the download routes right away).
  static UpdateDownloader forRelease(ReleaseInfo release, ReleaseAsset asset, UpdateNetConfig config) {
    final c = _current;
    if (c != null && c.release.tag == release.tag && c.asset.name == asset.name) {
      c.config = config;
      return c;
    }
    c?.cancel();
    return _current = UpdateDownloader._(release, asset, config);
  }

  final ReleaseInfo release;
  final ReleaseAsset asset;
  UpdateNetConfig config;

  UpdatePhase phase = UpdatePhase.probing;

  /// Automatic order of sources (after the direct test / speed test).
  List<DownloadSource> autoSources = const [DownloadSource.direct()];
  Future<void>? _prepared;

  /// Source in use (downloading) or to be used first.
  DownloadSource? source;
  int received = 0, total = 0;
  double speed = 0; // bytes / s
  File? file;
  UpdateException? error;

  /// Result of handing the file to the installer ('ok', 'need_permission', 'revealed').
  String? openResult;
  Completer<void>? _cancel;

  S get _s => config.strings;
  bool get downloading => phase == UpdatePhase.downloading;

  /// Every source the user may pick from: theirs, then the automatic ones.
  List<DownloadSource> get choices {
    final out = <DownloadSource>[for (final m in config.userMirrors) DownloadSource.mirror(m, kind: SourceKind.user)];
    for (final s in [const DownloadSource.direct(), ...autoSources]) {
      if (!out.contains(s) && (config.mode == MirrorMode.auto || s.isDirect)) out.add(s);
    }
    return out;
  }

  SourcePlan _plan({bool builtIn = false}) {
    if (builtIn) return SourcePlan(autoSources);
    return planSources(mode: config.mode, userMirrors: config.userMirrors, auto: () => autoSources);
  }

  void _prepare() => _prepared = () async {
        final direct = await probeSource(const DownloadSource.direct(), asset.url);
        if (direct.ok) {
          autoSources = [const DownloadSource.direct(), for (final m in cachedMirrorCandidates(config.prefs)) DownloadSource.mirror(m)];
        } else if (config.mode == MirrorMode.auto && config.userMirrors.isEmpty) {
          final mirrors = await loadMirrorCandidates(config.prefs);
          autoSources = autoPlan(directOk: false, mirrorResults: await speedTest(mirrors, asset.url));
        } else {
          autoSources = const [DownloadSource.direct()];
        }
        if (phase == UpdatePhase.probing) {
          phase = UpdatePhase.ready;
          source = _plan().sources.first;
          notifyListeners();
        }
      }();

  /// Downloads, then hands the file to the installer. [builtIn]: the one-shot
  /// switch to built-in mirrors after the user's own failed. [preferred]: a
  /// source the user picked, tried first.
  Future<void> start({bool builtIn = false, DownloadSource? preferred}) async {
    if (downloading) return;
    final cancel = _cancel = Completer<void>();
    phase = UpdatePhase.downloading;
    error = null;
    openResult = null;
    received = 0;
    total = asset.size;
    speed = 0;
    notifyListeners();
    if (builtIn && config.mode == MirrorMode.auto && config.userMirrors.isNotEmpty) {
      // The routes were not speed-tested for the user's mirrors; do it now.
      final mirrors = await loadMirrorCandidates(config.prefs);
      final direct = await probeSource(const DownloadSource.direct(), asset.url);
      autoSources = autoPlan(directOk: direct.ok, mirrorResults: await speedTest(mirrors, asset.url));
    } else {
      await _prepared;
    }
    if (cancel.isCompleted) return;
    final plan = _plan(builtIn: builtIn);
    final sources = [?preferred, ...plan.sources.where((s) => s != preferred)];

    var lastTick = DateTime.now();
    var lastBytes = 0;
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final (f, used) = await downloadFromSources(
        asset,
        sources,
        cancel: cancel,
        onSource: (s) {
          source = s;
          received = 0;
          lastBytes = 0;
          speed = 0;
          notifyListeners();
          _progressNotification();
        },
        onProgress: (got, all) {
          received = got;
          total = all;
          final now = DateTime.now();
          final dt = now.difference(lastTick).inMilliseconds;
          if (dt >= 500) {
            final inst = (got - lastBytes) * 1000 / dt;
            speed = speed == 0 ? inst : speed * 0.5 + inst * 0.5;
            lastTick = now;
            lastBytes = got;
            notifyListeners();
          }
          if (now.difference(lastNotify).inMilliseconds >= 1000) {
            lastNotify = now;
            _progressNotification();
          }
        },
      );
      source = used;
      file = f;
      phase = UpdatePhase.done;
      _cancel = null;
      notifyListeners();
      await _doneNotification(f);
      await install();
    } on UpdateException catch (e) {
      _cancel = null;
      if (e.code == 'update_cancelled') {
        phase = UpdatePhase.ready;
        await UpdateNotification.clear();
      } else if (plan.userStage && !builtIn && preferred == null && config.mode == MirrorMode.auto) {
        phase = UpdatePhase.userMirrorsFailed;
        error = e;
        await _failNotification(_s.t('update_user_mirrors_failed'));
      } else {
        phase = UpdatePhase.failed;
        error = e;
        await _failNotification('${_s.t(e.code)}${e.detail == null ? '' : ' (${e.detail})'}');
      }
      notifyListeners();
    }
  }

  void cancel() {
    if (_cancel?.isCompleted == false) _cancel!.complete();
  }

  /// Opens the downloaded file in the system installer.
  Future<void> install() async {
    final f = file;
    if (f == null) return;
    try {
      openResult = await openDownloaded(f);
    } catch (_) {
      openResult = 'error';
    }
    notifyListeners();
  }

  String sourceLabel(DownloadSource s) => s.isDirect ? _s.t('update_source_direct') : s.name;

  static String mb(int b) => (b / 1048576).toStringAsFixed(1);

  static String speedText(double bps) =>
      bps >= 1048576 ? '${(bps / 1048576).toStringAsFixed(1)} MB/s' : '${(bps / 1024).toStringAsFixed(0)} KB/s';

  void _progressNotification() {
    final pct = total > 0 ? (received * 100 ~/ total) : -1;
    final size = total > 0 ? '${mb(received)} / ${mb(total)} MB' : '${mb(received)} MB';
    final text = '${pct >= 0 ? '$pct% · ' : ''}$size · ${speedText(speed)} · ${source == null ? '' : sourceLabel(source!)}';
    UpdateNotification.progress(_s.t('update_notify_downloading', {'v': release.tag}), text, pct);
  }

  Future<void> _doneNotification(File f) async {
    if (Platform.isAndroid) {
      await UpdateNotification.done(_s.t('update_notify_done'), release.tag, f.path);
    } else if (config.notify) {
      await SystemNotify.show(_s.t('update_notify_done_desktop', {'v': release.tag}), f.path);
    }
  }

  Future<void> _failNotification(String text) async {
    if (Platform.isAndroid) {
      await UpdateNotification.failed(_s.t('update_download_failed'), text);
    } else if (config.notify) {
      await SystemNotify.show(_s.t('update_download_failed'), text);
    }
  }
}

/// Android "更新下载" channel notification (MainActivity); no-op elsewhere.
class UpdateNotification {
  static const _ch = MethodChannel('zju_connect/core');

  static Future<void> _call(String m, Map<String, Object?> args) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod(m, args);
    } catch (_) {}
  }

  /// [percent] -1 = indeterminate.
  static Future<void> progress(String title, String text, int percent) =>
      _call('updateProgress', {'title': title, 'text': text, 'percent': percent});
  static Future<void> done(String title, String text, String path) =>
      _call('updateDone', {'title': title, 'text': text, 'path': path});
  static Future<void> failed(String title, String text) => _call('updateFailed', {'title': title, 'text': text});
  static Future<void> clear() => _call('updateClear', const {});
}
