import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/backup.dart';
import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';
import 'list_editors.dart';

/// Backup & restore (FlClash's page): WebDAV remote with auto backup and
/// retention, local file, and the restore strategy / password options.
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  bool? _davOk; // null = checking
  DavConfig? _checked;
  bool _busy = false;

  AutoBackupNotifier get _svc => ref.read(autoBackupProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ping());
  }

  Future<void> _ping() async {
    final c = ref.read(davProvider);
    _checked = c;
    if (c == null) return;
    setState(() => _davOk = null);
    final client = DavClient(c);
    final ok = await client.ping();
    client.close();
    if (mounted && identical(_checked, c)) setState(() => _davOk = ok);
  }

  void _setPrefs(BackupPrefs Function(BackupPrefs p) f) =>
      ref.read(backupPrefsProvider.notifier).set(f(ref.read(backupPrefsProvider)));

  Future<void> _run(String title, String done, Future<bool> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (await task() && mounted) await notice(context, title: title, message: done);
    } catch (e) {
      if (!mounted) return;
      await notice(context, title: title, message: e is BackupException ? context.tr(e.key) : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<RestoreOption?> _pickOption() => pickOne<RestoreOption>(
        context,
        title: context.tr('restore'),
        options: [
          (RestoreOption.all, context.tr('restore_all')),
          (RestoreOption.onlyProfiles, context.tr('restore_profiles')),
        ],
        current: RestoreOption.all,
      );

  Future<bool> _confirmRestore(BackupData d) {
    final override = ref.read(backupPrefsProvider).strategy == RestoreStrategy.override;
    final from = d.created == null
        ? ''
        : '\n${d.device.isEmpty ? '' : '${d.device} · '}${d.created!.toLocal().toString().substring(0, 16)}';
    return confirm(
      context,
      title: context.tr('restore'),
      message: context.tr(override ? 'restore_confirm_override' : 'restore_confirm_merge')
              .replaceAll('{n}', '${d.profiles.length}') +
          from,
      destructive: override,
    );
  }

  /// Decodes a backup, using the saved password first and asking for one
  /// when the file is encrypted with a different (or no saved) password.
  Future<BackupData?> _decode(List<int> bytes) async {
    String? pw = ref.read(backupPrefsProvider).password;
    while (true) {
      try {
        return await decodeBackupAsync(bytes, password: pw);
      } on BackupException catch (e) {
        if (e.key != 'backup_need_password' && e.key != 'backup_wrong_password') rethrow;
        if (!mounted) return null;
        final again = await editTextDialog(context,
            title: context.tr('backup_password'),
            initial: '',
            obscure: true,
            message: context.tr(e.key == 'backup_wrong_password' && (pw ?? '').isNotEmpty
                ? 'backup_wrong_password'
                : 'backup_need_password'));
        if (again == null || again.isEmpty) return null;
        pw = again;
      }
    }
  }

  Future<void> _editPassword() async {
    final v = await editTextDialog(context,
        title: context.tr('backup_password'),
        initial: ref.read(backupPrefsProvider).password,
        obscure: true,
        message: context.tr('backup_password_hint'));
    if (v == null) return;
    _setPrefs((p) => p.copyWith(password: v));
  }

  Future<void> _backupDav() => _run(context.tr('backup'), context.tr('backup_success'), () async {
        await _svc.backupToDav();
        return true;
      });

  Future<void> _restoreDav() async {
    final client = DavClient(ref.read(davProvider)!);
    try {
      List<DavEntry> entries;
      try {
        entries = await client.list();
      } catch (e) {
        if (mounted) await notice(context, title: context.tr('restore'), message: '$e');
        return;
      }
      if (!mounted) return;
      if (entries.isEmpty) {
        await notice(context, title: context.tr('restore'), message: context.tr('dav_no_backups'));
        return;
      }
      final pick = await pickOne<DavEntry>(
        context,
        title: context.tr('dav_pick_backup'),
        options: [for (final e in entries.take(30)) (e, _entryLabel(e))],
        current: entries.first,
      );
      if (pick == null || !mounted) return;
      final opt = await _pickOption();
      if (opt == null || !mounted) return;
      await _run(context.tr('restore'), context.tr('restore_success'), () async {
        final d = await _decode(await client.download(pick.name));
        if (d == null || !mounted || !await _confirmRestore(d)) return false;
        _svc.applyBackup(d, opt);
        return true;
      });
    } finally {
      client.close();
    }
  }

  /// Every app setting back to its default; profiles and the selected
  /// profile stay.
  Future<void> _resetSettings() async {
    final ok = await confirm(context,
        title: context.tr('reset_settings'), message: context.tr('reset_settings_confirm'), destructive: true);
    if (!ok || !mounted) return;
    final old = ref.read(settingsProvider);
    ref.read(settingsProvider.notifier).replace(AppSettings(
          selectedProfileId: old.selectedProfileId,
          setupGuideShown: true,
          shareWarningSeen: old.shareWarningSeen,
        ));
    showToast(context, context.tr('reset_settings_done'), level: BannerLevel.success);
  }

  Future<void> _backupLocal() => _run(context.tr('backup'), context.tr('backup_success'), () async {
        final res = await FilePicker.saveFile(
          fileName: backupFileName(),
          bytes: await _svc.buildBackup(),
          mimeType: 'application/json',
        );
        return res != null;
      });

  Future<void> _restoreLocal() async {
    final r = await FilePicker.pickFiles(type: FileType.any);
    final path = r.isEmpty ? null : r.first.path;
    if (path == null || !mounted) return;
    final opt = await _pickOption();
    if (opt == null || !mounted) return;
    await _run(context.tr('restore'), context.tr('restore_success'), () async {
      final d = await _decode(await File(path).readAsBytes());
      if (d == null || !mounted || !await _confirmRestore(d)) return false;
      _svc.applyBackup(d, opt);
      return true;
    });
  }

  Future<void> _editDav() async {
    final r = await showFloatingDialog<DavConfig?>(context: context, child: _DavForm(initial: ref.read(davProvider)));
    if (r == null || !mounted) return;
    ref.read(davProvider.notifier).set(r.uri.isEmpty ? null : r);
    await _ping();
  }

  Future<void> _editDevice() async {
    final c = ref.read(davProvider);
    if (c == null) return;
    final v = await editTextDialog(context,
        title: context.tr('dav_device'), initial: c.device, message: context.tr('dav_device_hint'));
    if (v == null) return;
    ref.read(davProvider.notifier).set(c.copyWith(fileName: v.trim()));
  }

  String _entryLabel(DavEntry e) {
    final t = e.modified?.toLocal();
    final name = e.name.endsWith('.json') ? e.name.substring(0, e.name.length - 5) : e.name;
    return t == null ? name : '$name\n${t.toString().substring(0, 16)}';
  }

  String _strategyLabel(RestoreStrategy s) =>
      context.tr(s == RestoreStrategy.compatible ? 'restore_strategy_compatible' : 'restore_strategy_override');

  @override
  Widget build(BuildContext context) {
    final dav = ref.watch(davProvider);
    final prefs = ref.watch(backupPrefsProvider);
    final cs = context.colorScheme;
    final status = switch (_davOk) {
      true => (context.tr('dav_ok'), const Color(0xFF34C759)),
      false => (context.tr('dav_fail'), cs.error),
      null => (context.tr('dav_checking'), cs.onSurfaceVariant),
    };
    final canDav = dav != null && _davOk == true && !_busy;
    String autoSub() {
      final base = context.tr('auto_backup_hint');
      if (prefs.auto == AutoBackup.off || prefs.lastAuto == null) return base;
      final key = prefs.lastAutoError == null ? 'auto_backup_last' : 'auto_backup_failed';
      return '$base · ${context.tr(key)} ${prefs.lastAuto!.toLocal().toString().substring(5, 16)}';
    }

    return PageList(children: [
      SettingsGroup(title: context.tr('remote'), children: [
        if (dav == null)
          SettingsTile(
            glyph: AppGlyphs.cloudSync,
            title: context.tr('dav_not_bound'),
            subtitle: context.tr('dav_bind_hint'),
            chevron: true,
            onTap: _editDav,
          )
        else ...[
          SettingsTile(
            glyph: AppGlyphs.cloudSync,
            title: dav.user.isEmpty ? dav.uri : dav.user,
            subtitle: dav.uri,
            trailing: Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: status.$2, shape: BoxShape.circle)),
              Text(status.$1, style: DashboardText.label(context)),
            ]),
            chevron: true,
            onTap: _editDav,
          ),
          SettingsTile(title: context.tr('dav_device'), subtitle: dav.device, chevron: true, onTap: _editDevice),
          SwitchTile(
            title: context.tr('auto_backup'),
            subtitle: autoSub(),
            value: prefs.auto != AutoBackup.off,
            onChanged: (v) => _setPrefs((p) => p.copyWith(auto: v ? AutoBackup.onChange : AutoBackup.off)),
          ),
          IntTile(
            title: context.tr('backup_keep'),
            value: prefs.keep,
            min: 1,
            max: 100,
            onChanged: (v) => _setPrefs((p) => p.copyWith(keep: v)),
          ),
          SettingsTile(glyph: AppGlyphs.upload, title: context.tr('backup'), onTap: canDav ? _backupDav : null),
          SettingsTile(glyph: AppGlyphs.cloudDownload, title: context.tr('restore'), onTap: canDav ? _restoreDav : null),
        ],
      ]),
      SettingsGroup(title: context.tr('local'), children: [
        SettingsTile(glyph: AppGlyphs.export, title: context.tr('backup_to_file'), onTap: _busy ? null : _backupLocal),
        SettingsTile(glyph: AppGlyphs.cloudDownload, title: context.tr('restore_from_file'), onTap: _busy ? null : _restoreLocal),
      ]),
      SettingsGroup(title: context.tr('options'), children: [
        SettingsTile(
          title: context.tr('backup_password'),
          subtitle: context.tr(prefs.password.isEmpty ? 'backup_password_hint' : 'backup_password_on'),
          trailing: GlyphIcon(prefs.password.isEmpty ? AppGlyphs.lockOpen : AppGlyphs.lock),
          onTap: _editPassword,
        ),
        SettingsTile(
          title: context.tr('restore_strategy'),
          subtitle: context.tr(prefs.strategy == RestoreStrategy.compatible
              ? 'restore_strategy_compatible_hint'
              : 'restore_strategy_override_hint'),
          trailing: Text(_strategyLabel(prefs.strategy), style: DashboardText.label(context)),
          chevron: true,
          onTap: () async {
            final v = await pickOne<RestoreStrategy>(context,
                title: context.tr('restore_strategy'),
                options: [for (final x in RestoreStrategy.values) (x, _strategyLabel(x))],
                current: prefs.strategy);
            if (v != null) _setPrefs((p) => p.copyWith(strategy: v));
          },
        ),
      ]),
      SettingsGroup(children: [
        SettingsTile(
          glyph: AppGlyphs.clearAll,
          title: context.tr('reset_settings'),
          subtitle: context.tr('reset_settings_desc'),
          destructive: true,
          onTap: _resetSettings,
        ),
      ]),
    ]);
  }
}

class _DavForm extends StatefulWidget {
  const _DavForm({this.initial});
  final DavConfig? initial;

  @override
  State<_DavForm> createState() => _DavFormState();
}

class _DavFormState extends State<_DavForm> {
  late final _uri = TextEditingController(text: widget.initial?.uri ?? '');
  late final _user = TextEditingController(text: widget.initial?.user ?? '');
  late final _pass = TextEditingController(text: widget.initial?.password ?? '');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: 'WebDAV',
      hasFields: true,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
        TextField(
          controller: _uri,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://dav.jianguoyun.com/dav/'),
        ),
        TextField(controller: _user, decoration: InputDecoration(hintText: context.tr('username'))),
        TextField(controller: _pass, obscureText: true, decoration: InputDecoration(hintText: context.tr('password'))),
      ]),
      actions: [
        if (widget.initial != null)
          TextButton(
            onPressed: () => Navigator.pop(context, const DavConfig(uri: '', user: '', password: '')),
            child: Text(context.tr('unbind')),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('cancel'))),
        TextButton(
          onPressed: () {
            final u = Uri.tryParse(_uri.text.trim());
            if (u == null || !u.hasScheme || u.host.isEmpty) return;
            Navigator.pop(
              context,
              DavConfig(
                uri: _uri.text.trim(),
                user: _user.text.trim(),
                password: _pass.text,
                fileName: widget.initial?.fileName ?? '',
              ),
            );
          },
          child: Text(context.tr('ok')),
        ),
      ],
    );
  }
}
