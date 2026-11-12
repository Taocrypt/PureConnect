import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/update_task.dart';
import '../../core/updater.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

const _lastLatestKey = 'update.lastLatest';
const _forceMinKey = 'update.forceMin';
bool _checking = false;

/// What the launch-time check shows once it has the latest release.
///
/// The launch check runs on every launch whatever the "check for updates on
/// launch" setting says, because a forced update (the running version is
/// below the release's minimum supported version) must always be caught; it
/// is shown even with automatic checks off. A normal newer version is only
/// offered while automatic checks are on.
bool shouldPromptOnLaunch({
  required bool autoEnabled,
  required String current,
  required String latest,
  String? minSupported,
}) {
  if (compareVersions(latest, current) <= 0) return false;
  if (isForcedUpdate(current, minSupported)) return true;
  return autoEnabled;
}

UpdateNetConfig updateNetConfig(WidgetRef ref) {
  final s = ref.read(settingsProvider);
  final lang = s.locale.isNotEmpty ? s.locale : PlatformDispatcher.instance.locale.languageCode;
  return UpdateNetConfig(
    mode: MirrorMode.parse(s.updateMirrorMode),
    userMirrors: List.of(s.updateMirrors),
    prefs: ref.read(prefsProvider),
    strings: S(lang == 'zh' ? 'zh' : 'en'),
    notify: s.notifications,
  );
}

/// Checks for a newer version (API, else update.json through mirrors).
///
/// [manual]: from the "Check for updates" button: says when it is already
/// up to date or the check failed. Otherwise (launch, every launch) it stays
/// silent, offline included, unless there is an update to show; see
/// [shouldPromptOnLaunch].
Future<void> checkForUpdate(BuildContext context, WidgetRef ref, {bool manual = false}) async {
  if (_checking) return;
  final SharedPreferences prefs = ref.read(prefsProvider);
  final settings = ref.read(settingsProvider);
  final current = await currentAppVersion();
  if (!context.mounted) return;
  _checking = true;
  try {
    if (manual) showToast(context, context.tr('update_checking'));
    final cfg = updateNetConfig(ref);
    final forcedKnown = isForcedUpdate(current, prefs.getString(_forceMinKey));
    Future<ReleaseInfo> fetch(bool builtIn) => fetchRelease(
          mode: cfg.mode,
          userMirrors: cfg.userMirrors,
          candidates: () => loadMirrorCandidates(prefs),
          allowBuiltIn: builtIn,
        );
    ReleaseInfo latest;
    try {
      try {
        latest = await fetch(!manual && forcedKnown);
      } on UpdateException catch (e) {
        if (e.code != 'update_user_mirrors_failed' || !manual || !context.mounted) rethrow;
        final ok = await confirmBuiltInMirrors(context);
        if (!ok) return;
        latest = await fetch(true);
      }
    } on UpdateException catch (e) {
      if (manual && context.mounted) {
        showToast(context, e.code == 'update_no_release' ? context.tr('update_latest', {'v': current}) : updateErrorText(context, e),
            level: e.code == 'update_no_release' ? BannerLevel.info : BannerLevel.error);
      }
      return;
    }
    await prefs.setString(_lastLatestKey, latest.version);
    await prefs.setString(_forceMinKey, latest.minSupportedVersion ?? '');
    if (!context.mounted) return;
    if (compareVersions(latest.version, current) <= 0) {
      if (manual) showToast(context, context.tr('update_latest', {'v': current}));
      return;
    }
    final forced = latest.forces(current);
    if (!manual &&
        !shouldPromptOnLaunch(
          autoEnabled: settings.autoCheckUpdate,
          current: current,
          latest: latest.version,
          minSupported: latest.minSupportedVersion,
        )) {
      return;
    }
    await showFloatingDialog<void>(
      context: context,
      dismissible: false,
      child: UpdateDialog(current: current, release: latest, forced: forced),
    );
  } finally {
    _checking = false;
  }
}

/// "Your mirrors failed — use the built-in ones?"
Future<bool> confirmBuiltInMirrors(BuildContext context) async {
  final r = await showFloatingDialog<bool>(
    context: context,
    child: Builder(
      builder: (ctx) => AlertDialog(
        title: ctx.tr('update_user_mirrors_failed'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('update_use_builtin'))),
        ],
        child: Text(ctx.tr('update_user_mirrors_failed_desc')),
      ),
    ),
  );
  return r == true;
}

String updateErrorText(BuildContext context, UpdateException e) {
  final base = context.tr(e.code);
  return e.detail == null || e.code == 'update_rate_limited' ? base : '$base（${e.detail}）';
}

/// "New version" dialog: release notes, then download (progress, source,
/// speed) and hand the file to the system installer. The download itself
/// lives in [UpdateDownloader], so closing the dialog keeps it going.
/// [forced]: this version is no longer supported — the dialog cannot be
/// closed until the update is installed.
class UpdateDialog extends ConsumerStatefulWidget {
  const UpdateDialog({super.key, required this.current, required this.release, this.forced = false});

  final String current;
  final ReleaseInfo release;
  final bool forced;

  @override
  ConsumerState<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<UpdateDialog> {
  ReleaseAsset? _asset;
  bool _resolved = false;
  UpdateDownloader? _task;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _task?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _resolve() async {
    final abis = Platform.isAndroid ? await androidAbis() : const <String>[];
    if (!mounted) return;
    final asset = pickAsset(widget.release, abis: abis);
    setState(() {
      _asset = asset;
      _resolved = true;
      if (asset != null) {
        // Tests the download routes right away (direct, else mirrors).
        _task = UpdateDownloader.forRelease(widget.release, asset, updateNetConfig(ref))..addListener(_changed);
      }
    });
  }

  void _close() => Navigator.of(context).pop();

  Future<void> _pickSource() async {
    final t = _task;
    if (t == null || t.downloading) return;
    final pick = await pickOne<DownloadSource?>(
      context,
      title: context.tr('update_source'),
      current: null,
      options: [
        (null, context.tr('update_source_auto')),
        for (final s in t.choices) (s, t.sourceLabel(s) + (s.kind == SourceKind.user ? ' · ${context.tr('update_source_mine')}' : '')),
      ],
    );
    if (!mounted) return;
    if (pick != null) t.start(preferred: pick);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final t = _task;
    final notes = r.notes.trim().isEmpty ? context.tr('update_no_notes') : _plainNotes(r.notes);
    final label = DashboardText.label(context);
    final forced = widget.forced;
    final mode = MirrorMode.parse(ref.read(settingsProvider).updateMirrorMode);

    final actions = <Widget>[];
    void action(String text, VoidCallback? onPressed) => actions.add(TextButton(onPressed: onPressed, child: Text(text)));
    final phase = t?.phase;
    if (_resolved && _asset == null) {
      if (!forced) action(context.tr('update_later'), _close);
      action(context.tr('update_open_page'), () {
        launchUrl(Uri.parse(r.pageUrl), mode: LaunchMode.externalApplication);
        if (!forced) _close();
      });
    } else if (phase == UpdatePhase.downloading) {
      if (!forced) action(context.tr('update_background'), _close);
      action(context.tr('cancel_download'), () => t!.cancel());
    } else if (phase == UpdatePhase.userMirrorsFailed) {
      action(context.tr('cancel'), forced ? () => t!.start() : _close);
      if (mode == MirrorMode.auto) action(context.tr('update_use_builtin'), () => t!.start(builtIn: true));
    } else if (phase == UpdatePhase.done) {
      if (!forced) action(context.tr('update_later'), _close);
      action(context.tr(Platform.isAndroid ? 'update_install' : 'update_open'), () async {
        await t!.install();
        if (mounted && !Platform.isAndroid && t.openResult != 'need_permission' && !forced) _close();
      });
    } else {
      if (!forced) action(context.tr('update_later'), _close);
      action(
        context.tr(phase == UpdatePhase.failed ? 'retry' : (Platform.isAndroid ? 'update_download_install' : 'update_download')),
        t == null || phase == UpdatePhase.probing ? null : () => t.start(),
      );
    }

    String? status;
    Color? statusColor;
    if (phase == UpdatePhase.userMirrorsFailed) {
      status = context.tr('update_user_mirrors_failed_desc');
      statusColor = context.colorScheme.error;
    } else if (phase == UpdatePhase.failed && t?.error != null) {
      status = updateErrorText(context, t!.error!);
      statusColor = context.colorScheme.error;
    } else if (phase == UpdatePhase.done && t?.openResult == 'need_permission') {
      status = context.tr('update_need_install_permission');
      statusColor = context.colorScheme.error;
    } else if (phase == UpdatePhase.done && t?.openResult == 'revealed') {
      status = context.tr('update_saved', {'path': t!.file!.path});
    } else if (phase == UpdatePhase.done && t?.openResult == 'error') {
      status = context.tr('update_open_failed', {'path': t!.file!.path});
      statusColor = context.colorScheme.error;
    }

    final sourceText = t == null
        ? ''
        : phase == UpdatePhase.probing
            ? context.tr('update_source_testing')
            : t.source == null
                ? ''
                : context.tr('update_source_using', {'s': t.sourceLabel(t.source!)});

    return PopScope(
      canPop: !forced,
      child: AlertDialog(
        title: context.tr(forced ? 'update_forced_title' : 'update_available', {'v': r.tag}),
        actions: actions,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
          if (forced)
            Text(context.tr('update_forced_desc', {'min': r.minSupportedVersion ?? ''}),
                style: label.copyWith(color: context.colorScheme.error)),
          Text(context.tr('update_versions', {'cur': widget.current, 'new': r.version}), style: label),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(child: Text(notes, style: AppTextStyle.subheadline.of(context))),
          ),
          Row(spacing: 8, children: [
            Expanded(
              child: Text(_asset == null ? '' : '${_asset!.name} · ${UpdateDownloader.mb(_asset!.size)} MB',
                  overflow: TextOverflow.ellipsis, style: label),
            ),
            PressRegion(
              onTap: () => launchUrl(Uri.parse(r.pageUrl), mode: LaunchMode.externalApplication),
              child: Text(context.tr('update_open_page'), style: label.copyWith(color: context.colorScheme.primary)),
            ),
          ]),
          if (t != null)
            Row(spacing: 8, children: [
              Expanded(child: Text(sourceText, overflow: TextOverflow.ellipsis, style: label)),
              if (!t.downloading && phase != UpdatePhase.probing)
                PressRegion(
                  onTap: _pickSource,
                  child: Text(context.tr('update_source_switch'), style: label.copyWith(color: context.colorScheme.primary)),
                ),
            ]),
          if (phase == UpdatePhase.downloading) ...[
            LinearProgressIndicator(value: t!.total > 0 ? t.received / t.total : null),
            Text(
              [
                if (t.total > 0) '${(t.received * 100 ~/ t.total)}%',
                t.total > 0
                    ? '${UpdateDownloader.mb(t.received)} / ${UpdateDownloader.mb(t.total)} MB'
                    : '${UpdateDownloader.mb(t.received)} MB',
                UpdateDownloader.speedText(t.speed),
              ].join(' · '),
              style: label,
            ),
          ],
          if (status != null) Text(status, style: statusColor == null ? label : label.copyWith(color: statusColor)),
        ]),
      ),
    );
  }
}

/// Release notes are Markdown; show them as readable plain text.
String _plainNotes(String md) {
  final out = <String>[];
  for (var line in md.replaceAll('\r\n', '\n').split('\n')) {
    line = line.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    line = line.replaceFirst(RegExp(r'^\s*[-*+]\s+'), '• ');
    line = line.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!);
    line = line.replaceAll('**', '').replaceAll('`', '');
    out.add(line);
  }
  return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
