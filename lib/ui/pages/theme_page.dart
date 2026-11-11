import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../app.dart' show appColorScheme, appSeed, systemAccentProvider;
import '../../core/app_icon.dart';
import '../../core/system_fonts.dart';
import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';
import '../widgets/palette.dart';

/// Theme (secondary page), with everything FlClash's theme page has: a live
/// preview, theme mode, pure black, theme colour (follow system, presets,
/// own colours with a colour picker) and colour style, navigation bar style,
/// tab animation, liquid glass, sidebar blur (Windows / macOS), font and text
/// scaling; plus PureConnect's app icon.
class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final accent = ref.watch(systemAccentProvider).value;
    final seed = appSeed(s, accent);
    ColorScheme scheme(Brightness b, {bool? pureBlack, Color? color}) =>
        appColorScheme(color ?? seed, b, style: s.colorStyle, pureBlack: pureBlack ?? s.pureBlack);
    final current = scheme(context.colorScheme.brightness);
    Widget screen(ColorScheme cs, {int selected = 0, bool? floating, bool? glass}) => MiniScreen(
          colorScheme: cs,
          floatingBar: floating ?? s.floatingNavBar,
          liquidGlass: glass ?? s.liquidGlass != 'none',
          selected: selected,
        );
    return PageList(children: [
      _LivePreview(builder: (cs, selected) => screen(cs, selected: selected), scheme: current),
      const SizedBox(height: 24),
      _ChoiceGroup<AppThemeMode>(
        glyph: AppGlyphs.sun,
        label: context.tr('theme_mode'),
        value: s.themeMode,
        onChanged: (v) => n.update((x) => x.themeMode = v),
        choices: [
          (
            AppThemeMode.system,
            context.tr('theme_system'),
            // Light on the left half, dark on the right.
            Stack(fit: StackFit.expand, children: [
              screen(scheme(Brightness.light)),
              ClipRect(clipper: const _RightHalf(), child: screen(scheme(Brightness.dark))),
            ]),
          ),
          (AppThemeMode.light, context.tr('theme_light'), screen(scheme(Brightness.light))),
          (AppThemeMode.dark, context.tr('theme_dark'), screen(scheme(Brightness.dark))),
        ],
      ),
      _ChoiceGroup<bool>(
        glyph: AppGlyphs.pureBlack,
        label: context.tr('pure_black_mode'),
        footer: context.tr('pure_black_desc'),
        value: s.pureBlack,
        onChanged: (v) => n.update((x) => x.pureBlack = v),
        choices: [
          (false, context.tr('style_standard'), screen(scheme(Brightness.dark, pureBlack: false))),
          (true, context.tr('pure_black'), screen(scheme(Brightness.dark, pureBlack: true))),
        ],
      ),
      _PrimaryColorSection(accent: accent),
      _ChoiceGroup<bool>(
        glyph: AppGlyphs.layers,
        label: context.tr('nav_bar_style'),
        footer: context.tr('nav_bar_style_desc'),
        value: s.floatingNavBar,
        onChanged: (v) => n.update((x) => x.floatingNavBar = v),
        choices: [
          (true, context.tr('nav_floating'), screen(current, floating: true)),
          (false, context.tr('nav_docked'), screen(current, floating: false, glass: false)),
        ],
      ),
      _ChoiceGroup<String>(
        glyph: AppGlyphs.motion,
        label: context.tr('tab_animation'),
        value: s.tabAnimation,
        onChanged: (v) => n.update((x) => x.tabAnimation = v),
        choices: [
          ('slide', context.tr('tab_slide'), _SwitchingScreen(fade: false, builder: (i) => screen(current, selected: i))),
          ('fade', context.tr('tab_fade'), _SwitchingScreen(fade: true, builder: (i) => screen(current, selected: i))),
        ],
      ),
      _ChoiceGroup<String>(
        glyph: AppGlyphs.liquidGlass,
        label: context.tr('liquid_glass'),
        footer: context.tr('liquid_glass_desc'),
        value: s.liquidGlass,
        onChanged: (v) => n.update((x) => x.liquidGlass = v),
        choices: [
          ('none', context.tr('glass_none'), screen(current, floating: true, glass: false, selected: 1)),
          ('standard', context.tr('style_standard'), screen(current, floating: true, glass: true, selected: 1)),
          ('ultra', context.tr('glass_ultra'), screen(current, floating: true, glass: true, selected: 1)),
        ],
      ),
      if (Platform.isWindows || Platform.isMacOS) ...[
        _Header(glyph: AppGlyphs.blur, label: context.tr('sidebar')),
        SettingsGroup(footer: context.tr('sidebar_blur_desc'), children: [
          SwitchTile(
            title: context.tr('sidebar_blur'),
            value: s.sidebarBlur,
            onChanged: (v) => n.update((x) => x.sidebarBlur = v),
          ),
        ]),
      ],
      const _FontFamilySection(),
      const _TextScaleSection(),
      if (appIconSupported) ...[
        _Header(glyph: AppGlyphs.iconTile, label: context.tr('app_icon')),
        const _AppIconPicker(),
      ],
    ]);
  }
}

class _RightHalf extends CustomClipper<Rect> {
  const _RightHalf();
  @override
  Rect getClip(Size size) => Rect.fromLTRB(size.width / 2, 0, size.width, size.height);
  @override
  bool shouldReclip(_RightHalf oldClipper) => false;
}

class _Header extends StatelessWidget {
  const _Header({required this.glyph, required this.label, this.action});
  final Glyph glyph;
  final String label;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
        child: SizedBox(
          height: 28,
          child: Row(spacing: 8, children: [
            GlyphIcon(glyph, size: 20, color: context.colorScheme.onSurfaceVariant),
            Expanded(child: Text(label, style: DashboardText.cardTitle(context))),
            ?action,
          ]),
        ),
      );
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: context.tr('reset'),
        onPressed: onPressed,
        icon: const GlyphIcon(AppGlyphs.reset, size: 20),
      );
}

/// A section of picture cards, one per choice (FlClash's PreviewChoiceGroup).
class _ChoiceGroup<T> extends StatelessWidget {
  const _ChoiceGroup({
    required this.glyph,
    required this.label,
    required this.choices,
    required this.value,
    required this.onChanged,
    this.footer,
  });
  final Glyph glyph;
  final String label;
  final List<(T, String, Widget)> choices;
  final T value;
  final ValueChanged<T> onChanged;
  final String? footer;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Header(glyph: glyph, label: label),
          Row(spacing: 12, children: [
            for (final (v, l, picture) in choices)
              Expanded(
                child: _Choice(
                  selected: v == value,
                  label: l,
                  onTap: () => onChanged(v),
                  child: ExcludeSemantics(child: picture),
                ),
              ),
            // Two choices take the width of two of three.
            if (choices.length == 2) const Expanded(child: SizedBox()),
          ]),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
              child: Text(footer!, style: DashboardText.label(context)),
            ),
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
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: PressRegion(
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: 96, height: 120, child: child)),
              ),
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
      ),
    );
  }
}

/// The app's home page as the theme will draw it, its tabs tappable.
class _LivePreview extends StatefulWidget {
  const _LivePreview({required this.builder, required this.scheme});
  final Widget Function(ColorScheme scheme, int selected) builder;
  final ColorScheme scheme;

  @override
  State<_LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends State<_LivePreview> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return DashboardBlock(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: SizedBox(
          width: 168,
          child: AspectRatio(
            aspectRatio: 9 / 17,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: TweenAnimationBuilder<ColorScheme>(
                tween: _SchemeTween(end: widget.scheme),
                duration: const Duration(milliseconds: 300),
                builder: (_, cs, _) => GestureDetector(
                  onTap: () => setState(() => _selected = (_selected + 1) % MiniScreen.destinationCount),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: KeyedSubtree(key: ValueKey(_selected), child: widget.builder(cs, _selected)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SchemeTween extends Tween<ColorScheme> {
  _SchemeTween({super.end});
  @override
  ColorScheme lerp(double t) => ColorScheme.lerp(begin!, end!, t);
}

/// A preview repeatedly switching tabs with the slide or fade animation.
class _SwitchingScreen extends StatefulWidget {
  const _SwitchingScreen({required this.fade, required this.builder});
  final bool fade;
  final Widget Function(int selected) builder;

  @override
  State<_SwitchingScreen> createState() => _SwitchingScreenState();
}

class _SwitchingScreenState extends State<_SwitchingScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // Rest on page 0, switch to 1, rest, switch back.
        final v = _c.value;
        double p(double from, double to) => ((v - from) / (to - from)).clamp(0.0, 1.0);
        final t = v < 0.5 ? Curves.easeInOut.transform(p(0.3, 0.45)) : 1 - Curves.easeInOut.transform(p(0.8, 0.95));
        final a = widget.builder(0);
        final b = widget.builder(1);
        if (widget.fade) {
          return Stack(fit: StackFit.expand, children: [
            Opacity(opacity: 1 - t, child: a),
            Opacity(opacity: t, child: b),
          ]);
        }
        return ClipRect(
          child: Stack(fit: StackFit.expand, children: [
            FractionalTranslation(translation: Offset(-t, 0), child: a),
            FractionalTranslation(translation: Offset(1 - t, 0), child: b),
          ]),
        );
      },
    );
  }
}

/// A phone-sized sketch of the dashboard in [colorScheme]: title, cards, the
/// start button, and the navigation (floating dock, glassy or not, or a
/// docked bar).
class MiniScreen extends StatelessWidget {
  const MiniScreen({
    super.key,
    required this.colorScheme,
    this.floatingBar = true,
    this.liquidGlass = false,
    this.selected = 0,
  });

  static const destinationCount = 4;

  final ColorScheme colorScheme;
  final bool floatingBar;
  final bool liquidGlass;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final card = dark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest;
    final page = dark ? cs.surface : cs.surfaceContainer;
    Widget bar(double w, Color c, {double h = 5}) => FractionallySizedBox(
          widthFactor: w,
          alignment: AlignmentDirectional.centerStart,
          child: Container(height: h, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        );
    // A card whose lines are cut off when the sketch is short.
    Widget block(int seed) => Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(8)),
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
                  bar(0.4 + seed * 0.1, cs.onSurfaceVariant.withValues(alpha: 0.5)),
                  bar(0.8 - seed * 0.15, cs.primary.withValues(alpha: 0.8)),
                ]),
              ),
            ),
          ),
        );
    final dots = Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      for (var i = 0; i < destinationCount; i++)
        Container(
          width: i == selected ? 14 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: i == selected ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
    ]);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 6, children: [
        bar(0.45 - selected * 0.05, cs.onSurface.withValues(alpha: 0.7), h: 6),
        block(selected % 3),
        block((selected + 1) % 3),
        if (selected.isEven) block((selected + 2) % 3),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(6)),
          ),
        ),
        SizedBox(height: floatingBar ? 26 : 4),
      ]),
    );
    return ColoredBox(
      color: page,
      child: Column(children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: content),
            if (floatingBar)
              Positioned(
                left: 10,
                right: 10,
                bottom: 6,
                child: Container(
                  height: 18,
                  decoration: BoxDecoration(
                    color: liquidGlass
                        ? cs.surfaceContainerHighest.withValues(alpha: 0.45)
                        : (dark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest),
                    borderRadius: BorderRadius.circular(9),
                    border: liquidGlass
                        ? Border.all(color: cs.onSurface.withValues(alpha: 0.18), width: 0.8)
                        : null,
                  ),
                  child: dots,
                ),
              ),
          ]),
        ),
        if (!floatingBar)
          Container(
            height: 18,
            color: dark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest,
            child: dots,
          ),
      ]),
    );
  }
}

/// Theme colour: follow the system accent (where there is one), the presets
/// and the user's own colours (add / edit / delete), colour style, reset.
class _PrimaryColorSection extends ConsumerWidget {
  const _PrimaryColorSection({required this.accent});
  final Color? accent;

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(context, title: context.tr('reset'), message: context.tr('reset_tip'), destructive: true);
    if (!ok) return;
    ref.read(settingsProvider.notifier).update((x) {
      x.primaryColors = List.of(defaultPrimaryColors);
      x.seedColor = defaultPrimaryColor;
      x.useDynamicColor = false;
      x.colorStyle = 'vivid';
    });
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, int color) async {
    final ok = await confirm(context, title: context.tr('delete'), message: context.tr('color_delete_tip'), destructive: true);
    if (!ok) return;
    ref.read(settingsProvider.notifier).update((x) {
      x.primaryColors = List.of(x.primaryColors)..remove(color);
      if (x.seedColor == color) {
        x.seedColor = x.primaryColors.isNotEmpty ? x.primaryColors.first : defaultPrimaryColor;
      }
    });
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final s = ref.read(settingsProvider);
    final color = await _pickColor(context, Color(s.seedColor));
    if (color == null) return;
    ref.read(settingsProvider.notifier).update((x) {
      if (!x.primaryColors.contains(color)) x.primaryColors = [...x.primaryColors, color];
      x.seedColor = color;
      x.useDynamicColor = false;
    });
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, int color) async {
    final edited = await _pickColor(context, Color(color));
    if (edited == null || edited == color) return;
    ref.read(settingsProvider.notifier).update((x) {
      final l = List.of(x.primaryColors);
      final i = l.indexOf(color);
      if (i == -1) return;
      if (l.contains(edited)) {
        l.removeAt(i);
      } else {
        l[i] = edited;
      }
      x.primaryColors = l;
      if (x.seedColor == color) x.seedColor = edited;
    });
  }

  Future<int?> _pickColor(BuildContext context, Color initial) =>
      pushPage<int>(context, (_) => _CustomColorPage(initial: initial));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final following = s.useDynamicColor && accent != null;
    final isDefault = !s.useDynamicColor &&
        s.seedColor == defaultPrimaryColor &&
        s.colorStyle == 'vivid' &&
        s.primaryColors.length == defaultPrimaryColors.length &&
        [for (var i = 0; i < defaultPrimaryColors.length; i++) s.primaryColors[i] == defaultPrimaryColors[i]].every((e) => e);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(
        glyph: AppGlyphs.palette,
        label: context.tr('primary_color'),
        action: isDefault ? null : _ResetButton(onPressed: () => _reset(context, ref)),
      ),
      SettingsGroup(footer: context.tr('primary_color_hint'), children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            if (accent != null)
              _Swatch(
                color: accent!,
                system: true,
                label: context.tr('follow_system'),
                selected: following,
                onTap: () => n.update((x) => x.useDynamicColor = true),
              ),
            for (final c in s.primaryColors)
              ContextMenuRegion(
                menuItems: [
                  PopupMenuItem(glyph: AppGlyphs.edit, label: context.tr('edit'), onPressed: () => _edit(context, ref, c)),
                  PopupMenuItem(
                      danger: true, glyph: AppGlyphs.delete, label: context.tr('delete'), onPressed: () => _delete(context, ref, c)),
                ],
                child: _Swatch(
                  color: Color(c),
                  label: Color(c).hex,
                  selected: !following && s.seedColor == c,
                  onTap: () => n.update((x) {
                    x.seedColor = c;
                    x.useDynamicColor = false;
                  }),
                ),
              ),
            _AddSwatch(onTap: () => _add(context, ref)),
          ]),
        ),
        SettingsTile(
          title: context.tr('color_style'),
          trailing: Text(context.tr('color_style_${s.colorStyle}'), style: DashboardText.label(context)),
          chevron: true,
          onTap: () async {
            final v = await pickOne<String>(context,
                title: context.tr('color_style'),
                current: s.colorStyle,
                options: [for (final st in colorStyles) (st, context.tr('color_style_$st'))]);
            if (v != null) n.update((x) => x.colorStyle = v);
          },
        ),
      ]),
    ]);
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap, required this.label, this.system = false});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final String label;
  final bool system;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final check = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        selected: selected,
        button: true,
        child: PressRegion(
          onTap: onTap,
          shape: AppShape.circle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(4),
            decoration: ShapeDecoration(
              shape: CircleBorder(side: BorderSide(color: selected ? color : const Color(0x00000000), width: 2.5)),
            ),
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(child: DecoratedBox(decoration: ShapeDecoration(color: color, shape: const CircleBorder()))),
              if (selected) Center(child: GlyphIcon(AppGlyphs.check, size: 18, fill: 1, color: check)),
              if (system)
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: Container(
                    width: 18,
                    height: 18,
                    padding: const EdgeInsets.all(2),
                    decoration: ShapeDecoration(color: DashboardColors.of(context).card, shape: const CircleBorder()),
                    child: GlyphIcon(AppGlyphs.eyedropper, size: 12, color: cs.onSurface),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AddSwatch extends StatelessWidget {
  const _AddSwatch({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    return Tooltip(
      message: context.tr('add_color'),
      child: PressRegion(
        onTap: onTap,
        shape: AppShape.circle,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 36,
              height: 36,
              decoration: ShapeDecoration(color: cs.surfaceContainerHighest, shape: const CircleBorder()),
              child: GlyphIcon(AppGlyphs.add, size: 20, color: cs.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom colour: light and dark previews, a hex field and FlClash's palette
/// (grid, spectrum, sliders). Pops with the colour (ARGB) on confirm.
class _CustomColorPage extends ConsumerStatefulWidget {
  const _CustomColorPage({required this.initial});
  final Color initial;

  @override
  ConsumerState<_CustomColorPage> createState() => _CustomColorPageState();
}

class _CustomColorPageState extends ConsumerState<_CustomColorPage> {
  late final _controller = ValueNotifier<Color>(widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    return AppPage(
      canPop: true,
      title: context.tr('custom_color'),
      actions: [
        HeaderAction(
          glyph: AppGlyphs.check,
          tooltip: context.tr('ok'),
          onPressed: () => Navigator.of(context).pop(_controller.value.toARGB32() | 0xFF000000),
        ),
      ],
      body: PageList(children: [
        ValueListenableBuilder<Color>(
          valueListenable: _controller,
          builder: (context, color, _) => DashboardBlock(
            padding: const EdgeInsets.all(12),
            child: Row(spacing: 12, children: [
              for (final b in Brightness.values)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 72,
                    height: 96,
                    child: FittedBox(
                      child: SizedBox(
                        width: 96,
                        height: 128,
                        child: MiniScreen(
                          colorScheme: appColorScheme(color, b, style: s.colorStyle, pureBlack: s.pureBlack),
                          floatingBar: s.floatingNavBar,
                          liquidGlass: s.liquidGlass != 'none',
                        ),
                      ),
                    ),
                  ),
                ),
              Expanded(child: HexColorField(color: color, onChanged: (c) => _controller.value = c)),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Palette(controller: _controller),
      ]),
    );
  }
}

/// Font: the platform default or any installed family.
class _FontFamilySection extends ConsumerWidget {
  const _FontFamilySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(settingsProvider.select((s) => s.fontFamily));
    final cs = context.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(glyph: AppGlyphs.font, label: context.tr('font_family')),
      SettingsGroup(children: [
        PressRegion(
          onTap: () => pushPage(context, (_) => const FontFamilyPage()),
          overlay: PressRegion.hoverOverlay,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
            child: Row(spacing: 12, children: [
              Text('Aa', style: AppTextStyle.headline.of(context).copyWith(fontFamily: family.isEmpty ? null : family)),
              Expanded(
                child: Text(
                  family.isEmpty ? context.tr('font_default') : family,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline
                      .of(context)
                      .copyWith(fontFamily: family.isEmpty ? null : family, color: cs.onSurfaceVariant),
                ),
              ),
              GlyphIcon(AppGlyphs.chevronForward, size: 18, color: cs.onSurfaceVariant),
            ]),
          ),
        ),
      ]),
    ]);
  }
}

/// The installed font families (DirectWrite / Core Text / fontconfig /
/// Android fonts.xml), searchable.
class FontFamilyPage extends ConsumerStatefulWidget {
  const FontFamilyPage({super.key});

  @override
  ConsumerState<FontFamilyPage> createState() => _FontFamilyPageState();
}

class _FontFamilyPageState extends ConsumerState<FontFamilyPage> {
  List<String>? _families;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(loadSystemFontFamilies().then((l) {
      if (mounted) setState(() => _families = l);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(settingsProvider.select((s) => s.fontFamily));
    final n = ref.read(settingsProvider.notifier);
    final q = _query.trim().toLowerCase();
    final shown = (_families ?? const <String>[]).where((f) => q.isEmpty || f.toLowerCase().contains(q)).toList();
    final cs = context.colorScheme;
    Widget row(String family, String label) => SettingsTile(
          title: label,
          trailing: family == current ? GlyphIcon(AppGlyphs.check, size: 20, color: cs.primary) : null,
          onTap: () {
            n.update((x) => x.fontFamily = family);
            Navigator.of(context).maybePop();
          },
        );
    return AppPage(
      canPop: true,
      title: context.tr('font_family'),
      body: PageList(children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextField(
            decoration: InputDecoration(hintText: context.tr('search')),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SettingsGroup(children: [row('', context.tr('font_default'))]),
        if (_families == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(context.tr('loading'), style: DashboardText.label(context))),
          )
        else if (shown.isNotEmpty)
          SettingsGroup(title: context.tr('installed_fonts'), children: [
            for (final f in shown)
              DefaultTextStyle.merge(style: TextStyle(fontFamily: f), child: row(f, f)),
          ]),
      ]),
    );
  }
}

/// Text scaling: follow the system or a custom 80–140 % with a preview.
class _TextScaleSection extends ConsumerStatefulWidget {
  const _TextScaleSection();

  @override
  ConsumerState<_TextScaleSection> createState() => _TextScaleSectionState();
}

class _TextScaleSectionState extends ConsumerState<_TextScaleSection> {
  double? _draft;
  static const _step = 0.05;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final cs = context.colorScheme;
    final system = WidgetsBinding.instance.platformDispatcher.textScaleFactor.clamp(minTextScale, maxTextScale).toDouble();
    final scale = _draft ?? (s.customTextScale ? s.textScale : system);
    final percent = '${(scale * 100).round()}%';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Header(
        glyph: AppGlyphs.textSize,
        label: context.tr('text_scale'),
        action: s.customTextScale && s.textScale != 1
            ? _ResetButton(onPressed: () => n.update((x) => x.textScale = 1))
            : null,
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SegmentedControl<bool>(
          segments: [(false, context.tr('follow_system')), (true, context.tr('custom'))],
          value: s.customTextScale,
          onChanged: (v) {
            setState(() => _draft = null);
            n.update((x) => x.customTextScale = v);
          },
        ),
      ),
      SettingsGroup(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 12, children: [
              Expanded(
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
                    Text('Aa', style: AppTextStyle.title3.of(context)),
                    Text(context.tr('text_scale_preview'),
                        style: AppTextStyle.subheadline.of(context).copyWith(color: cs.onSurfaceVariant)),
                  ]),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: ShapeDecoration(color: cs.surfaceContainerHighest, shape: AppShape.full),
                child: Text(percent,
                    style: AppTextStyle.subheadline
                        .of(context, emphasized: true)
                        .copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            ]),
            const SizedBox(height: 8),
            MediaQuery.withNoTextScaling(
              child: Row(spacing: 12, children: [
                Text('A', style: AppTextStyle.footnote.of(context).copyWith(color: cs.onSurfaceVariant)),
                Expanded(
                  child: Slider(
                    min: minTextScale,
                    max: maxTextScale,
                    divisions: ((maxTextScale - minTextScale) / _step).round(),
                    value: scale,
                    label: percent,
                    onChanged: s.customTextScale ? (v) => setState(() => _draft = v) : null,
                    onChangeEnd: (v) {
                      setState(() => _draft = null);
                      n.update((x) => x.textScale = v);
                    },
                  ),
                ),
                Text('A', style: AppTextStyle.title2.of(context).copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
      ]),
    ]);
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
    final shortcuts = await applyWindowsShortcutIcon(id);
    ref.read(settingsProvider.notifier).update((x) => x.appIcon = id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (Platform.isAndroid && ok) _launcher = id;
    });
    if (shortcuts != null && shortcuts.needsManual) {
      // Some shortcut is out of reach (all-users Start Menu needs admin) or
      // none was found: say how to change it by hand.
      await notice(context,
          title: context.tr('app_icon'),
          message: context.tr('app_icon_manual_windows', {'n': '${windowsIconIndex(id) + 1}'}));
      return;
    }
    showToast(context, context.tr(ok ? 'app_icon_changed' : 'app_icon_failed'),
        level: ok ? BannerLevel.info : BannerLevel.warning);
  }

  @override
  Widget build(BuildContext context) {
    final current = _launcher ?? ref.watch(settingsProvider.select((s) => s.appIcon));
    final cs = context.colorScheme;
    final windows = Platform.isWindows;
    return SettingsGroup(footer: context.tr(windows ? 'app_icon_hint_windows' : 'app_icon_hint'), children: [
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
      // Windows: the icons' numbers in pureconnect.exe ("Change Icon").
      if (windows)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Wrap(spacing: 14, runSpacing: 6, alignment: WrapAlignment.spaceEvenly, children: [
            for (final id in appIcons)
              SizedBox(
                width: 72,
                child: Text(context.tr('app_icon_number', {'n': '${windowsIconIndex(id) + 1}'}),
                    textAlign: TextAlign.center, style: DashboardText.label(context)),
              ),
        ]),
      ),
    ]);
  }
}
