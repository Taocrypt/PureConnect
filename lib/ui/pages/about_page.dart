import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_icon.dart';
import '../../core/updater.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';
import '../widgets/update_dialog.dart';
import 'disclaimer_page.dart';
import 'update_mirrors_page.dart';

/// PureConnect user group (QQ), the feedback channel.
const feedbackGroupUrl = 'https://qm.qq.com/q/tLAgIcTjFY';
const feedbackGroupName = 'PureConnect用户交流群';
const coreRepoUrl = 'https://github.com/Mythologyli/zju-connect';
const licenseName = 'AGPL-3.0';

/// The core's version alone. The core reports
/// `<version> (zju-connect <upstream>)`; the upstream has its own row.
String coreVersionLabel(String raw) {
  final v = raw.trim();
  final i = v.indexOf(' (');
  return (i < 0 ? v : v.substring(0, i)).trim();
}

Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// 关于 (secondary page, FlClash style): a header with the icon, name,
/// version and licence and the update check, then tiles for updates, links,
/// the disclaimer and the open-source licences, and the version details.
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  String _appVersion = '';
  bool _details = false;

  @override
  void initState() {
    super.initState();
    currentAppVersion().then((v) {
      if (mounted) setState(() => _appVersion = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final core = ref.watch(coreProvider.select((s) => s.version));
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = context.colorScheme;
    Widget external() => GlyphIcon(AppGlyphs.openExternal, size: 18, color: cs.onSurfaceVariant);
    return AppPage(
      canPop: true,
      title: context.tr('about'),
      body: PageList(children: [
        _AboutHero(
          version: _appVersion,
          icon: s.appIcon,
          onCheckUpdate: () => checkForUpdate(context, ref, manual: true),
        ),
        const SizedBox(height: 24),
        SettingsGroup(title: context.tr('about_updates'), children: [
          SwitchTile(
            glyph: AppGlyphs.clock,
            title: context.tr('auto_check_update'),
            subtitle: context.tr('auto_check_update_desc'),
            value: s.autoCheckUpdate,
            onChanged: (v) => n.update((x) => x.autoCheckUpdate = v),
          ),
          SettingsTile(
            glyph: AppGlyphs.cloudDownload,
            title: context.tr('update_mirrors'),
            subtitle: s.updateMirrors.isNotEmpty
                ? context.tr('update_mirrors_desc_custom', {'n': '${s.updateMirrors.length}'})
                : context.tr(MirrorMode.parse(s.updateMirrorMode) == MirrorMode.direct
                    ? 'update_mirrors_desc_direct'
                    : 'update_mirrors_desc_auto'),
            chevron: true,
            onTap: () => pushPage(
                context, (_) => AppPage(canPop: true, title: context.tr('update_mirrors'), body: const UpdateMirrorsPage())),
          ),
        ]),
        SettingsGroup(title: context.tr('about_more'), children: [
          SettingsTile(
            glyph: AppGlyphs.code,
            title: context.tr('project_home'),
            subtitle: 'github.com/Taocrypt/PureConnect',
            trailing: external(),
            onTap: () => _open(repoUrl),
          ),
          SettingsTile(
            glyph: AppGlyphs.send,
            title: context.tr('feedback_group'),
            subtitle: feedbackGroupName,
            trailing: external(),
            onTap: () => _open(feedbackGroupUrl),
          ),
          SettingsTile(
            glyph: AppGlyphs.cpu,
            title: context.tr('upstream_core'),
            subtitle: 'github.com/Mythologyli/zju-connect',
            trailing: external(),
            onTap: () => _open(coreRepoUrl),
          ),
        ]),
        SettingsGroup(children: [
          SettingsTile(
            glyph: AppGlyphs.gavel,
            title: context.tr('disclaimer'),
            chevron: true,
            onTap: () => pushPage(context, (_) => const DisclaimerPage()),
          ),
          SettingsTile(
            glyph: AppGlyphs.verified,
            title: context.tr('open_source_licenses'),
            subtitle: context.tr('open_source_licenses_desc'),
            chevron: true,
            onTap: () => showAppLicensePage(context, _appVersion),
          ),
          SettingsTile(
            glyph: AppGlyphs.info,
            title: context.tr('version_details'),
            subtitle: context.tr('version_details_desc'),
            trailing: AnimatedRotation(
              turns: _details ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: GlyphIcon(AppGlyphs.chevronDown, size: 18, color: cs.onSurfaceVariant),
            ),
            onTap: () => setState(() => _details = !_details),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: !_details
                ? const SizedBox(width: double.infinity)
                : Column(children: [
                    _DetailRow(
                        title: context.tr('core_version'),
                        value: coreVersionLabel(core).isEmpty ? context.tr('core_version_unknown') : coreVersionLabel(core)),
                    const _DetailRow(title: 'zju-connect', value: 'Mythologyli/zju-connect', url: coreRepoUrl),
                    _DetailRow(
                      title: context.tr('ui_design'),
                      value: 'FlClash / prism_ui',
                      url: 'https://github.com/chen08209/FlClash',
                    ),
                  ]),
          ),
        ]),
      ]),
    );
  }
}

class _AboutHero extends StatelessWidget {
  const _AboutHero({required this.version, required this.icon, required this.onCheckUpdate});
  final String version;
  final String icon;
  final VoidCallback onCheckUpdate;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    Widget pill(String label, Color color, Color fg) => DecoratedBox(
          decoration: ShapeDecoration(color: color, shape: AppShape.full),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(label, style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(color: fg)),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: Column(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Image.asset(appIconPreview(appIcons.contains(icon) ? icon : defaultAppIcon), width: 96, height: 96),
        ),
        const SizedBox(height: 20),
        Text('PureConnect', style: AppTextStyle.title2.of(context, emphasized: true)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          if (version.isNotEmpty) pill('v$version', cs.primary, cs.onPrimary),
          pill(licenseName, cs.surfaceContainerHighest, cs.onSurfaceVariant),
        ]),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(context.tr('about_desc'),
              textAlign: TextAlign.center,
              style: AppTextStyle.subheadline.of(context).copyWith(color: cs.onSurfaceVariant, height: 1.5)),
        ),
        const SizedBox(height: 20),
        TonalButton(
          size: TonalButtonSize.bar,
          glyph: AppGlyphs.sync,
          label: context.tr('check_update'),
          onPressed: onCheckUpdate,
        ),
      ]),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.title, required this.value, this.url});
  final String title;
  final String value;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(58, 10, 20, 10),
      // Title and value share the line when they fit; otherwise the value
      // moves under the title, and wraps there, rather than being cut off.
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            Text(title, style: AppTextStyle.subheadline.of(context)),
            Row(mainAxisSize: MainAxisSize.min, spacing: 12, children: [
              Flexible(
                child: Text(value,
                    textAlign: TextAlign.end,
                    softWrap: true,
                    style: DashboardText.label(context, color: url == null ? null : cs.primary)),
              ),
              if (url != null) GlyphIcon(AppGlyphs.openExternal, size: 16, color: cs.onSurfaceVariant),
            ]),
          ],
        ),
      ),
    );
    if (url == null) return row;
    return PressRegion(onTap: () => _open(url!), overlay: PressRegion.hoverOverlay, child: row);
  }
}

/// Flutter's licence page (every package's licence, plus PureConnect's
/// AGPL-3.0 notice registered in main.dart), in a Material theme made from
/// the app's colours since the rest of the app is not Material.
Future<void> showAppLicensePage(BuildContext context, String version) {
  final cs = context.colorScheme;
  final theme = material.ThemeData(
    colorScheme: material.ColorScheme.fromSeed(seedColor: cs.primary, brightness: cs.brightness),
  );
  return Navigator.of(context).push(material.MaterialPageRoute<void>(
    builder: (_) => material.Theme(
      data: theme,
      child: material.LicensePage(
        applicationName: 'PureConnect',
        applicationVersion: version.isEmpty ? null : 'v$version',
        applicationLegalese: 'Copyright (C) PureConnect contributors\nGNU AGPL-3.0-only',
      ),
    ),
  ));
}
