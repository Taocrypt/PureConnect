import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/update_mirrors.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';

/// 关于 → 下载镜像: automatic / always-direct, and the user's own mirrors
/// (tried first, in order).
class UpdateMirrorsPage extends ConsumerWidget {
  const UpdateMirrorsPage({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final v = await editTextDialog(context, title: context.tr('update_custom_mirrors'), initial: '', hint: 'https://gh-proxy.com');
    if (v == null || v.trim().isEmpty || !context.mounted) return;
    final url = normalizeMirrorUrl(v);
    if (url == null) {
      showToast(context, context.tr('update_mirror_invalid'), level: BannerLevel.warning);
      return;
    }
    if (ref.read(settingsProvider).updateMirrors.contains(url)) {
      showToast(context, context.tr('update_mirror_exists'), level: BannerLevel.warning);
      return;
    }
    ref.read(settingsProvider.notifier).update((s) => s.updateMirrors.add(url));
  }

  void _move(WidgetRef ref, int i, int d) => ref.read(settingsProvider.notifier).update((s) {
        final j = i + d;
        if (j < 0 || j >= s.updateMirrors.length) return;
        final x = s.updateMirrors.removeAt(i);
        s.updateMirrors.insert(j, x);
      });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final mode = MirrorMode.parse(s.updateMirrorMode);
    final muted = context.colorScheme.onSurfaceVariant;
    Widget modeTile(MirrorMode m, String title, String desc) => SettingsTile(
          title: title,
          subtitle: desc,
          trailing: mode == m ? GlyphIcon(AppGlyphs.check, size: 20, color: context.colorScheme.primary) : null,
          onTap: () => n.update((x) => x.updateMirrorMode = m.name),
        );
    final list = s.updateMirrors;
    return PageList(children: [
      SettingsGroup(title: context.tr('update_mirror_mode'), children: [
        modeTile(MirrorMode.auto, context.tr('update_mirror_mode_auto'), context.tr('update_mirror_mode_auto_desc')),
        modeTile(MirrorMode.direct, context.tr('update_mirror_mode_direct'), context.tr('update_mirror_mode_direct_desc')),
      ]),
      SettingsGroup(
        title: context.tr('update_custom_mirrors'),
        footer: context.tr('update_custom_mirrors_hint'),
        children: [
          for (final (i, m) in list.indexed)
            SettingsTile(
              title: m,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: context.tr('move_up'),
                  onPressed: i == 0 ? null : () => _move(ref, i, -1),
                  icon: GlyphIcon(AppGlyphs.arrowUp, size: 18, color: muted),
                ),
                IconButton(
                  tooltip: context.tr('move_down'),
                  onPressed: i == list.length - 1 ? null : () => _move(ref, i, 1),
                  icon: GlyphIcon(AppGlyphs.arrowDown, size: 18, color: muted),
                ),
                IconButton(
                  tooltip: context.tr('delete'),
                  onPressed: () => n.update((x) => x.updateMirrors.removeAt(i)),
                  icon: GlyphIcon(AppGlyphs.delete, size: 18, color: context.colorScheme.error),
                ),
              ]),
            ),
          SettingsTile(glyph: AppGlyphs.add, title: context.tr('add'), onTap: () => _add(context, ref)),
        ],
      ),
    ]);
  }
}
