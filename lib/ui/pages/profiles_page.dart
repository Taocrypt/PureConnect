import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:prism_ui/shapes/shapes.dart';

import '../../core/profile_share.dart';
import '../../l10n/strings.dart';
import '../../models/profile.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';
import '../home_shell.dart' show switchProfile;
import 'profile_edit_page.dart';
import 'setup_guide_page.dart';

class ProfilesPage extends ConsumerWidget {
  const ProfilesPage({super.key});

  Future<void> _add(BuildContext context) async {
    final kind = await pickOne<String>(
      context,
      title: context.tr('add_profile'),
      current: '',
      options: [
        ('guide', context.tr('setup_guide')),
        ('custom', context.tr('custom')),
        ('clip', context.tr('import_clipboard')),
      ],
    );
    if (kind == null || !context.mounted) return;
    if (kind == 'guide') {
      await pushPage(context, (_) => const SetupGuidePage());
      return;
    }
    Profile p;
    if (kind == 'clip') {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      final parsed = decodeProfileShare(text);
      if (!context.mounted) return;
      if (parsed == null) {
        showToast(context, context.tr('import_clipboard_invalid'), level: BannerLevel.warning);
        return;
      }
      p = parsed;
    } else {
      p = Profile(name: context.tr('custom'), disableZjuConfig: true);
    }
    await pushPage(context, (_) => ProfileEditPage(profile: p, isNew: true));
  }

  /// First-time warning that the shared text contains the password, with a
  /// "don't show again" box that is remembered in settings.
  Future<bool> _confirmShare(BuildContext context, WidgetRef ref) async {
    if (ref.read(settingsProvider).shareWarningSeen) return true;
    var dontAsk = false;
    final ok = await showFloatingDialog<bool>(
      context: context,
      child: StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: ctx.tr('share_warn_title'),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ctx.tr('share_warn_body')),
            const SizedBox(height: 4),
            // The checkbox's 48px tap target pads its 18px box by 15px; shift
            // the row so the box lines up with the text above.
            Transform.translate(
              offset: const Offset(-15, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => dontAsk = !dontAsk),
                child: Row(children: [
                  Checkbox(value: dontAsk, onChanged: (_) => setState(() => dontAsk = !dontAsk)),
                  Text(ctx.tr('dont_show_again')),
                ]),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('share_profile_go'))),
          ],
        ),
      ),
    );
    if (ok == true && dontAsk) {
      ref.read(settingsProvider.notifier).update((x) => x.shareWarningSeen = true);
    }
    return ok == true;
  }

  Future<void> _more(BuildContext context, WidgetRef ref, Profile p, bool locked) async {
    final action = await pickOne<String>(
      context,
      title: p.name,
      current: '',
      options: [
        ('edit', context.tr('edit_profile')),
        ('dup', context.tr('duplicate')),
        ('share', context.tr('share_profile')),
        if (!locked) ('del', context.tr('delete')),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'edit':
        await pushPage(context, (_) => ProfileEditPage(profile: p.copy()));
      case 'dup':
        ref.read(profilesProvider.notifier).upsert(
              Profile.fromJson({...p.toJson(), 'id': null, 'name': '${p.name} (2)'}),
            );
      case 'share':
        if (!await _confirmShare(context, ref)) return;
        await Clipboard.setData(ClipboardData(text: encodeProfileShare(p)));
        if (context.mounted) showToast(context, context.tr('share_profile_done'));
      case 'del':
        if (await confirm(context, title: context.tr('delete'), message: p.name, destructive: true)) {
          ref.read(profilesProvider.notifier).remove(p.id);
        }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final selected = ref.watch(selectedProfileProvider);
    final active = ref.watch(coreProvider.select((s) => s.isActive));
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);

    return AppPage(
      title: context.tr('profiles'),
      actions: [HeaderAction(glyph: AppGlyphs.add, tooltip: context.tr('add_profile'), onPressed: () => _add(context))],
      body: profiles.isEmpty
          ? EmptyHint(glyph: AppGlyphs.profiles, text: context.tr('empty'))
          : PageList(children: [
              for (final p in profiles) ...[
                Builder(builder: (context) {
                  final isSel = p.id == selected?.id;
                  final at = p.protocol == VpnProtocol.atrust;
                  return Container(
                    decoration: ShapeDecoration(
                      color: colors.card,
                      shape: AppShape.all(26).copyWith(
                        side: isSel ? BorderSide(color: colorScheme.primary, width: 1.5) : BorderSide.none,
                      ),
                      shadows: DashboardShadows.e1(context),
                    ),
                    child: PressSurface(
                      fill: Colors.transparent,
                      shape: AppShape.all(26),
                      childFills: true,
                      onPressed: isSel ? null : () => switchProfile(context, ref, p.id),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 8, 14),
                        child: Row(spacing: 14, children: [
                          ShapeBadge(
                            shape: isSel ? MaterialShapes.cookie9Sided : MaterialShapes.circle,
                            color: isSel ? colorScheme.primary : colors.tone,
                            size: 48,
                            child: Text(at ? 'AT' : 'EC',
                                style: AppTextStyle.subheadline
                                    .of(context, emphasized: true)
                                    .copyWith(color: isSel ? colorScheme.onPrimary : colorScheme.onSurfaceVariant)),
                          ),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 6, children: [
                              Text(p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyle.headline.of(context, emphasized: true)),
                              Wrap(spacing: 6, runSpacing: 4, children: [
                                if (isSel)
                                  DashboardChip(
                                    label: active ? context.tr('running') : context.tr('selected'),
                                    tone: active ? DashboardChipTone.ok : DashboardChipTone.idle,
                                    dot: active,
                                  ),
                                DashboardChip(label: at ? 'aTrust' : 'EasyConnect'),
                                DashboardChip(label: '${p.effectiveServer}:${p.serverPort}'),
                                if (p.username.isNotEmpty) DashboardChip(label: p.username),
                              ]),
                            ]),
                          ),
                          IconButton(
                            tooltip: UiLocalizations.of(context).more,
                            onPressed: () => _more(context, ref, p, isSel && active),
                            icon: const GlyphIcon(AppGlyphs.more),
                          ),
                        ]),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
              ],
            ]),
    );
  }
}
