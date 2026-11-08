import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../app.dart' show systemAccentProvider;
import '../../core/app_icon.dart';
import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

/// Theme (secondary page, FlClash style): theme mode with live previews,
/// primary colour / dynamic colour, and the app icon.
class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  static const seeds = [0xFF007AFF, 0xFF34C759, 0xFFAF52DE, 0xFFFF2D55, 0xFFFF9500, 0xFF5AC8FA];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final accent = Platform.isAndroid ? ref.watch(systemAccentProvider).value : null;
    final seed = s.useDynamicColor && accent != null ? accent : Color(s.seedColor);
    return PageList(children: [
      _Header(glyph: AppGlyphs.sun, label: context.tr('theme_mode')),
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Row(spacing: 12, children: [
          for (final (mode, label) in [
            (AppThemeMode.system, context.tr('theme_system')),
            (AppThemeMode.light, context.tr('theme_light')),
            (AppThemeMode.dark, context.tr('theme_dark')),
          ])
            Expanded(
              child: _Choice(
                selected: s.themeMode == mode,
                label: label,
                onTap: () => n.update((x) => x.themeMode = mode),
                child: switch (mode) {
                  AppThemeMode.system => Row(children: [
                      Expanded(child: _MiniScreen(seed: seed, brightness: Brightness.light, clipRight: true)),
                      Expanded(child: _MiniScreen(seed: seed, brightness: Brightness.dark, clipLeft: true)),
                    ]),
                  AppThemeMode.light => _MiniScreen(seed: seed, brightness: Brightness.light),
                  AppThemeMode.dark => _MiniScreen(seed: seed, brightness: Brightness.dark),
                },
              ),
            ),
        ]),
      ),
      _Header(glyph: AppGlyphs.palette, label: context.tr('primary_color')),
      SettingsGroup(children: [
        if (Platform.isAndroid)
          SwitchTile(
            title: context.tr('dynamic_color'),
            subtitle: context.tr('dynamic_color_desc'),
            value: s.useDynamicColor,
            onChanged: (v) => n.update((x) => x.useDynamicColor = v),
          ),
        Opacity(
          opacity: Platform.isAndroid && s.useDynamicColor ? 0.4 : 1,
          child: IgnorePointer(
            ignoring: Platform.isAndroid && s.useDynamicColor,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Wrap(spacing: 10, runSpacing: 10, children: [
                for (final c in seeds)
                  _Swatch(
                    color: Color(c),
                    selected: s.seedColor == c,
                    onTap: () => n.update((x) => x.seedColor = c),
                  ),
              ]),
            ),
          ),
        ),
      ]),
      if (appIconSupported) ...[
        _Header(glyph: AppGlyphs.iconTile, label: context.tr('app_icon')),
        const _AppIconPicker(),
      ],
    ]);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.glyph, required this.label});
  final Glyph glyph;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
        child: Row(spacing: 8, children: [
          GlyphIcon(glyph, size: 20, color: context.colorScheme.onSurfaceVariant),
          Text(label, style: DashboardText.cardTitle(context)),
        ]),
      );
}

/// A selectable card with a picture and a label under it.
class _Choice extends StatelessWidget {
  const _Choice({required this.selected, required this.label, required this.onTap, required this.child});
  final bool selected;
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    return PressRegion(
      onTap: onTap,
      overlay: PressRegion.hoverOverlay,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(spacing: 8, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(width: 2.5, color: selected ? cs.primary : const Color(0x00000000)),
          ),
          child: AspectRatio(
            aspectRatio: 0.8,
            child: ClipRRect(borderRadius: BorderRadius.circular(15), child: child),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, spacing: 4, children: [
          if (selected) GlyphIcon(AppGlyphs.checkCircle, size: 16, color: cs.primary),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.subheadline.of(context).copyWith(color: selected ? cs.primary : null)),
          ),
        ]),
      ]),
    );
  }
}

/// A tiny drawing of the app (top bar, cards, start button) in one brightness.
class _MiniScreen extends StatelessWidget {
  const _MiniScreen({required this.seed, required this.brightness, this.clipLeft = false, this.clipRight = false});
  final Color seed;
  final Brightness brightness;
  final bool clipLeft, clipRight;

  @override
  Widget build(BuildContext context) {
    final cs = ColorScheme.fromSeed(seedColor: seed, brightness: brightness, style: ColorStyle.vivid);
    final card = brightness == Brightness.dark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest;
    final page = brightness == Brightness.dark ? cs.surface : cs.surfaceContainer;
    Widget bar(double w, Color c) => FractionallySizedBox(
          widthFactor: w,
          alignment: AlignmentDirectional.centerStart,
          child: Container(height: 5, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        );
    Widget block() => Expanded(
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
              bar(0.5, cs.onSurfaceVariant.withValues(alpha: 0.5)),
              bar(0.8, cs.primary.withValues(alpha: 0.8)),
            ]),
          ),
        );
    return Container(
      color: page,
      padding: EdgeInsets.fromLTRB(clipLeft ? 4 : 8, 10, clipRight ? 4 : 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 6, children: [
        bar(0.45, cs.onSurface.withValues(alpha: 0.7)),
        block(),
        block(),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ]),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    return PressRegion(
      onTap: onTap,
      shape: AppShape.circle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 44,
        height: 44,
        padding: const EdgeInsets.all(3),
        decoration: ShapeDecoration(
          shape: CircleBorder(side: BorderSide(color: selected ? cs.onSurface : const Color(0x00000000), width: 2)),
        ),
        child: DecoratedBox(
          decoration: ShapeDecoration(color: color, shape: const CircleBorder()),
          child: selected ? const Center(child: GlyphIcon(AppGlyphs.check, size: 20, color: Color(0xFFFFFFFF))) : null,
        ),
      ),
    );
  }
}

/// Launcher / window icon, picked in place (was a dialog in Tools).
class _AppIconPicker extends ConsumerStatefulWidget {
  const _AppIconPicker();

  @override
  ConsumerState<_AppIconPicker> createState() => _AppIconPickerState();
}

class _AppIconPickerState extends ConsumerState<_AppIconPicker> {
  String? _launcher;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Android: the alias actually enabled wins over the saved setting.
    currentLauncherIcon().then((v) {
      if (mounted && v != null) setState(() => _launcher = v);
    });
  }

  Future<void> _pick(String id) async {
    final current = _launcher ?? ref.read(settingsProvider).appIcon;
    if (_busy || id == current) return;
    setState(() => _busy = true);
    final ok = await applyAppIcon(id);
    ref.read(settingsProvider.notifier).update((x) => x.appIcon = id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (Platform.isAndroid && ok) _launcher = id;
    });
    showToast(context, context.tr(ok ? 'app_icon_changed' : 'app_icon_failed'),
        level: ok ? BannerLevel.info : BannerLevel.warning);
  }

  @override
  Widget build(BuildContext context) {
    final current = _launcher ?? ref.watch(settingsProvider.select((s) => s.appIcon));
    final cs = context.colorScheme;
    return SettingsGroup(footer: context.tr('app_icon_hint'), children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 14, runSpacing: 14, alignment: WrapAlignment.spaceEvenly, children: [
          for (final id in appIcons)
            PressRegion(
              onTap: () => _pick(id),
              overlay: PressRegion.hoverOverlay,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(width: 2.5, color: id == current ? cs.primary : const Color(0x00000000)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Image.asset(appIconPreview(id), width: 60, height: 60),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}
