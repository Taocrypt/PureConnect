import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/updater.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

const _lastCheckKey = 'update.lastCheck';
bool _checking = false;

/// Checks GitHub Releases for a newer version.
///
/// [manual]: from the "Check for updates" button: says when it is already
/// up to date or the check failed. Otherwise (launch) it stays silent unless
/// there is an update, and runs at most once a day.
Future<void> checkForUpdate(BuildContext context, WidgetRef ref, {bool manual = false}) async {
  if (_checking) return;
  final prefs = ref.read(prefsProvider);
  if (!manual) {
    if (!ref.read(settingsProvider).autoCheckUpdate) return;
    final last = prefs.getInt(_lastCheckKey) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - last < const Duration(days: 1).inMilliseconds) return;
  }
  _checking = true;
  try {
    if (manual) showToast(context, context.tr('update_checking'));
    final current = await currentAppVersion();
    final ReleaseInfo latest;
    try {
      latest = await fetchLatestRelease();
    } on UpdateException catch (e) {
      if (manual && context.mounted) {
        showToast(context, e.code == 'update_no_release' ? context.tr('update_latest', {'v': current}) : _errorText(context, e),
            level: e.code == 'update_no_release' ? BannerLevel.info : BannerLevel.error);
      }
      return;
    }
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
    if (!context.mounted) return;
    if (compareVersions(latest.version, current) <= 0) {
      if (manual) showToast(context, context.tr('update_latest', {'v': current}));
      return;
    }
    await showFloatingDialog<void>(
      context: context,
      dismissible: false,
      child: UpdateDialog(current: current, release: latest),
    );
  } finally {
    _checking = false;
  }
}

String _errorText(BuildContext context, UpdateException e) {
  final base = context.tr(e.code);
  return e.detail == null || e.code == 'update_rate_limited' ? base : '$base（${e.detail}）';
}

/// "New version" dialog: release notes, then download (with progress) and
/// hand the file to the system installer.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.current, required this.release});

  final String current;
  final ReleaseInfo release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  ReleaseAsset? _asset;
  bool _resolved = false;
  Completer<void>? _cancel;
  double? _progress;
  String? _progressText;
  String? _error;
  File? _file;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final abis = Platform.isAndroid ? await androidAbis() : const <String>[];
    if (!mounted) return;
    setState(() {
      _asset = pickAsset(widget.release, abis: abis);
      _resolved = true;
    });
  }

  bool get _downloading => _cancel != null;

  static String _mb(int b) => (b / 1048576).toStringAsFixed(1);

  Future<void> _download() async {
    final asset = _asset;
    if (asset == null) return;
    final cancel = Completer<void>();
    setState(() {
      _cancel = cancel;
      _error = null;
      _progress = null;
      _progressText = null;
    });
    try {
      final f = await downloadAsset(asset, cancel: cancel, onProgress: (got, total) {
        if (!mounted) return;
        setState(() {
          _progress = total > 0 ? got / total : null;
          _progressText = total > 0 ? '${_mb(got)} / ${_mb(total)} MB' : '${_mb(got)} MB';
        });
      });
      if (!mounted) return;
      setState(() {
        _file = f;
        _cancel = null;
      });
      await _open();
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _cancel = null;
        _progress = null;
        _progressText = null;
        if (e.code != 'update_cancelled') _error = _errorText(context, e);
      });
    }
  }

  Future<void> _open() async {
    final f = _file;
    if (f == null) return;
    try {
      final r = await openDownloaded(f);
      if (!mounted) return;
      if (r == 'need_permission') {
        setState(() => _error = context.tr('update_need_install_permission'));
      } else if (r == 'revealed') {
        showToast(context, context.tr('update_saved', {'path': f.path}));
        Navigator.of(context).pop();
      } else if (!Platform.isAndroid) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) setState(() => _error = context.tr('update_open_failed', {'path': f.path}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    final notes = r.notes.trim().isEmpty ? context.tr('update_no_notes') : _plainNotes(r.notes);
    final label = DashboardText.label(context);
    final String primary;
    final VoidCallback? onPrimary;
    if (_downloading) {
      primary = context.tr('cancel_download');
      onPrimary = () => _cancel?.complete();
    } else if (_file != null) {
      primary = context.tr(Platform.isAndroid ? 'update_install' : 'update_open');
      onPrimary = _open;
    } else if (_resolved && _asset == null) {
      primary = context.tr('update_open_page');
      onPrimary = () {
        launchUrl(Uri.parse(r.pageUrl), mode: LaunchMode.externalApplication);
        Navigator.of(context).pop();
      };
    } else {
      primary = context.tr(Platform.isAndroid ? 'update_download_install' : 'update_download');
      onPrimary = _resolved ? _download : null;
    }
    return AlertDialog(
      title: context.tr('update_available', {'v': r.tag}),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
        Text(context.tr('update_versions', {'cur': widget.current, 'new': r.version}), style: label),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: SingleChildScrollView(child: Text(notes, style: AppTextStyle.subheadline.of(context))),
        ),
        Row(spacing: 8, children: [
          Expanded(
            child: Text(_asset == null ? '' : '${_asset!.name} · ${_mb(_asset!.size)} MB',
                overflow: TextOverflow.ellipsis, style: label),
          ),
          PressRegion(
            onTap: () => launchUrl(Uri.parse(r.pageUrl), mode: LaunchMode.externalApplication),
            child: Text(context.tr('update_open_page'), style: label.copyWith(color: context.colorScheme.primary)),
          ),
        ]),
        if (_downloading) ...[
          LinearProgressIndicator(value: _progress),
          if (_progressText != null) Text(_progressText!, style: label),
        ],
        if (_error != null) Text(_error!, style: label.copyWith(color: context.colorScheme.error)),
      ]),
      actions: [
        TextButton(
          onPressed: () {
            _cancel?.complete();
            Navigator.of(context).pop();
          },
          child: Text(context.tr('update_later')),
        ),
        TextButton(onPressed: onPrimary, child: Text(primary)),
      ],
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
