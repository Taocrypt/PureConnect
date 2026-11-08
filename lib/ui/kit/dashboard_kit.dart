// Dashboard building blocks in the style of the current FlClash dashboard
// (https://github.com/chen08209/FlClash, GPL-3.0): tonal cards with the
// design's CSS shadows, header row with glyph + title + status chip, inner
// blocks one tone off the card, M3 Expressive shape badges and switch rows.
import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:prism_ui/shapes/shapes.dart';

import 'app_glyphs.dart';

/// Below this width the app uses the phone layout (bottom dock, one column).
const mobileBreakpoint = 640.0;

class DashboardColors {
  const DashboardColors._({
    required this.page,
    required this.card,
    required this.tone,
    required this.tone2,
    required this.ok,
    required this.okContainer,
    required this.onOkContainer,
    required this.warn,
    required this.warnContainer,
    required this.onWarnContainer,
  });

  factory DashboardColors.of(BuildContext context) {
    final c = context.colorScheme;
    return DashboardColors._(
      page: SurfaceLevel.page.colorOf(c),
      card: SurfaceLevel.card.colorOf(c),
      tone: SurfaceLevel.block.colorOf(c),
      tone2: SurfaceLevel.inset.colorOf(c),
      ok: c.success,
      okContainer: c.successContainer,
      onOkContainer: c.onSuccessContainer,
      warn: c.warning,
      warnContainer: c.warningContainer,
      onWarnContainer: c.onWarningContainer,
    );
  }

  final Color page, card, tone, tone2;
  final Color ok, okContainer, onOkContainer;
  final Color warn, warnContainer, onWarnContainer;
}

abstract final class DashboardShadows {
  static List<BoxShadow> e1(BuildContext context) =>
      context.colorScheme.brightness == Brightness.dark ? _e1Dark : _e1Light;

  static BoxShadow _shadow(int alpha, double y, double cssBlur, [double spread = 0]) => BoxShadow(
        color: Color.fromARGB(alpha, 0, 0, 0),
        offset: Offset(0, y),
        blurRadius: cssBlur <= 1 ? 0 : (cssBlur / 2 - 0.5) / 0.57735,
        spreadRadius: spread,
      );

  static final _e1Light = [_shadow(0x0D, 0.5, 1), _shadow(0x0A, 2, 6), _shadow(0x17, 12, 32, -6)];
  static final _e1Dark = [_shadow(0x80, 1, 2), _shadow(0x8C, 10, 28, -6)];
}

abstract final class DashboardCorner {
  static const desktopCard = 32.0;
  static const mobileCard = 34.0;
  static const block = 20.0;
}

abstract final class DashboardText {
  static TextStyle cardTitle(BuildContext context) => AppTextStyle.footnote
      .of(context, emphasized: true)
      .copyWith(color: context.colorScheme.onSurfaceVariant);

  static TextStyle mobileCardTitle(BuildContext context) =>
      AppTextStyle.subheadline.of(context, emphasized: true);

  static TextStyle label(BuildContext context, {Color? color}) => AppTextStyle.caption1
      .of(context)
      .toTabular
      .copyWith(color: color ?? context.colorScheme.onSurfaceVariant);

  static TextStyle figure(BuildContext context, AppTextStyle style, {Color? color}) => style
      .of(context, emphasized: true)
      .toTabular
      .copyWith(color: color, letterSpacing: -0.02 * style.size);

  static TextStyle unit(BuildContext context) => AppTextStyle.subheadline
      .of(context, emphasized: true)
      .copyWith(color: context.colorScheme.onSurfaceVariant);

  static TextStyle rowTitle(BuildContext context) =>
      AppTextStyle.subheadline.of(context, emphasized: true);
}

bool isMobileLayout(BuildContext context) => ViewScope.isMobileOf(context);

double dashboardCardRadius(BuildContext context) =>
    isMobileLayout(context) ? DashboardCorner.mobileCard : DashboardCorner.desktopCard;

EdgeInsets dashboardCardPadding(BuildContext context) => isMobileLayout(context)
    ? const EdgeInsets.symmetric(horizontal: 20, vertical: 18)
    : const EdgeInsets.symmetric(horizontal: 22, vertical: 20);

class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    this.padding,
    this.onTap,
    this.clipBehavior = Clip.none,
    required this.child,
  });

  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Clip clipBehavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = AppShape.all(dashboardCardRadius(context));
    final content = Padding(padding: padding ?? dashboardCardPadding(context), child: child);
    return Container(
      clipBehavior: clipBehavior,
      decoration: ShapeDecoration(
        color: DashboardColors.of(context).card,
        shape: shape,
        shadows: DashboardShadows.e1(context),
      ),
      child: onTap == null
          ? content
          : PressSurface(
              fill: Colors.transparent,
              shape: shape,
              onPressed: onTap,
              childFills: true,
              child: content,
            ),
    );
  }
}

class DashboardCardHeader extends StatelessWidget {
  const DashboardCardHeader({
    super.key,
    this.glyph,
    required this.title,
    this.leading = const [],
    this.trailing = const [],
    this.chevron = false,
  });

  final Glyph? glyph;
  final String title;
  final List<Widget> leading;
  final List<Widget> trailing;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final mobile = isMobileLayout(context);
    final colorScheme = context.colorScheme;
    final style = mobile ? DashboardText.mobileCardTitle(context) : DashboardText.cardTitle(context);
    return SizedBox(
      height: mobile ? 26 : 24,
      child: Row(
        spacing: 8,
        children: [
          if (glyph case final glyph?)
            GlyphIcon(glyph, size: 18, color: mobile ? colorScheme.onSurface : colorScheme.onSurfaceVariant),
          Expanded(
            child: Row(spacing: 8, children: [
              Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
              ...leading,
            ]),
          ),
          ...trailing,
          if (chevron) GlyphIcon(Glyphs.chevronForward, size: 18, color: colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

enum DashboardChipTone { idle, ok, warn, error }

class DashboardChip extends StatelessWidget {
  const DashboardChip({super.key, required this.label, this.tone = DashboardChipTone.idle, this.dot = false});

  final String label;
  final DashboardChipTone tone;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);
    final (background, foreground) = switch (tone) {
      DashboardChipTone.idle => (colors.tone, colorScheme.onSurfaceVariant),
      DashboardChipTone.ok => (colors.okContainer, colors.onOkContainer),
      DashboardChipTone.warn => (colors.warnContainer, colors.onWarnContainer),
      DashboardChipTone.error => (colorScheme.errorContainer, colorScheme.onErrorContainer),
    };
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: ShapeDecoration(color: background, shape: AppShape.full),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (dot)
            DecoratedBox(
              decoration: ShapeDecoration(color: foreground, shape: AppShape.circle),
              child: const SizedBox.square(dimension: 6),
            ),
          Text(
            label,
            maxLines: 1,
            style: AppTextStyle.caption1.of(context, emphasized: true).toTabular.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

/// A block inside a card, one tone off the card itself.
class DashboardBlock extends StatelessWidget {
  const DashboardBlock({
    super.key,
    this.radius = DashboardCorner.block,
    this.color,
    this.padding = EdgeInsets.zero,
    this.onTap,
    required this.child,
  });

  final double radius;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = AppShape.all(radius);
    final content = Padding(padding: padding, child: child);
    final fill = color ?? DashboardColors.of(context).tone;
    if (onTap == null) {
      return DecoratedBox(decoration: ShapeDecoration(color: fill, shape: shape), child: content);
    }
    return PressSurface(fill: fill, shape: shape, onPressed: onTap, childFills: true, child: content);
  }
}

/// An M3 Expressive shape, filled, with [child] centered on it.
class ShapeBadge extends StatelessWidget {
  const ShapeBadge({
    super.key,
    required this.shape,
    required this.color,
    required this.size,
    this.rotation = 0,
    this.child,
  });

  final RoundedPolygon shape;
  final Color color;
  final double size;
  final double rotation;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: ShapePainter(path: shapePathOf(shape), color: color, rotation: rotation),
        child: SizedBox.square(dimension: size, child: child == null ? null : Center(child: child)),
      );
}

final _shapePaths = Expando<Path>();

Path shapePathOf(RoundedPolygon shape) => _shapePaths[shape] ??= shape.toPath();

/// Paints a path laid out in the unit square, the space [MaterialShapes]
/// are normalized to.
class ShapePainter extends CustomPainter {
  const ShapePainter({required this.path, required this.color, this.rotation = 0});

  final Path path;
  final Color color;
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(rotation)
      ..scale(size.width, size.height)
      ..translate(-0.5, -0.5)
      ..drawPath(path, Paint()..color = color)
      ..restore();
  }

  @override
  bool shouldRepaint(ShapePainter old) => old.path != path || old.color != color || old.rotation != rotation;
}

class DashboardSwitch extends StatelessWidget {
  const DashboardSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: Switch.trackWidth,
        height: Switch.trackHeight,
        child: OverflowBox(
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Switch(value: value, onChanged: onChanged),
        ),
      );
}

/// A row holding one setting behind a switch: a cookie-6 icon container while
/// it is on, a plain circle while it is off.
class DashboardSwitchRow extends StatelessWidget {
  const DashboardSwitchRow({
    super.key,
    required this.glyph,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.iconSize = 40,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 16, 10),
    this.radius = DashboardCorner.block,
    this.color,
    this.showIcon = true,
  });

  final Glyph glyph;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double iconSize;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);
    final glyphSize = iconSize * 0.5;
    final enabled = onChanged != null;
    return DashboardBlock(
      radius: radius,
      color: color,
      padding: padding,
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Row(
        spacing: 12,
        children: [
          if (showIcon)
            AnimatedSwitcher(
              duration: context.motionDuration(commonDuration),
              child: value
                  ? ShapeBadge(
                      key: const ValueKey(true),
                      shape: MaterialShapes.cookie6Sided,
                      color: colorScheme.primary,
                      size: iconSize,
                      child: GlyphIcon(glyph, size: glyphSize, color: colorScheme.onPrimary),
                    )
                  : ShapeBadge(
                      key: const ValueKey(false),
                      shape: MaterialShapes.circle,
                      color: colors.card,
                      size: iconSize,
                      child: GlyphIcon(glyph, size: glyphSize, color: colorScheme.onSurfaceVariant),
                    ),
            ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashboardText.rowTitle(context)),
                if (subtitle case final subtitle?)
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashboardText.label(context)),
              ],
            ),
          ),
          DashboardSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// M3 Expressive connected buttons: the ends round off the group, the inner
/// corners stay tight, and the selected one turns into a full pill.
class DashboardConnectedButtons<T> extends StatelessWidget {
  const DashboardConnectedButtons({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.height = 44,
    this.vertical = false,
  });

  final List<(T, Glyph, String)> items;
  final T value;
  final ValueChanged<T>? onChanged;
  final double height;

  /// Icon over label, as the phone layout shows them.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final background = DashboardColors.of(context).tone;
    final outer = height / 2;
    const inner = 8.0;
    return Row(
      spacing: 3,
      children: [
        for (final (i, (v, glyph, label)) in items.indexed)
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: v == value ? 1 : 0),
              duration: context.motionDuration(const Duration(milliseconds: 240)),
              curve: Curves.easeOutCubic,
              builder: (context, t, _) {
                final start = lerpDouble(i == 0 ? outer : inner, outer, t)!;
                final end = lerpDouble(i == items.length - 1 ? outer : inner, outer, t)!;
                final shape = AppShape.of(BorderRadius.horizontal(
                  left: Radius.circular(start),
                  right: Radius.circular(end),
                ));
                final fg = Color.lerp(colorScheme.onSurfaceVariant, colorScheme.onPrimary, t)!;
                final textStyle = AppTextStyle.subheadline.of(context, emphasized: true).copyWith(color: fg);
                final content = vertical
                    ? Column(mainAxisSize: MainAxisSize.min, spacing: 2, children: [
                        GlyphIcon(glyph, size: 18, color: fg),
                        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle),
                      ])
                    : Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
                        GlyphIcon(glyph, size: 18, color: fg),
                        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle)),
                      ]);
                return Container(
                  height: height,
                  clipBehavior: Clip.antiAlias,
                  decoration: ShapeDecoration(color: Color.lerp(background, colorScheme.primary, t), shape: shape),
                  child: PressRegion(
                    shape: shape,
                    overlay: PressRegion.hoverOverlay,
                    onTap: onChanged == null ? null : () => onChanged!(v),
                    child: Center(
                      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: content),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// A label over a value, the run time / organization cells of the status card.
class DashboardCell extends StatelessWidget {
  const DashboardCell({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashboardText.label(context)),
          const SizedBox(height: 2),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.subheadline.of(context, emphasized: true).toTabular),
        ],
      );
}

/// Small round icon button used in card headers (copy, refresh…).
class DashboardIconButton extends StatelessWidget {
  const DashboardIconButton({super.key, required this.glyph, required this.tooltip, required this.onPressed, this.color});

  final Glyph glyph;
  final Color? color;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        // Bounded even inside lists (unbounded height), still free to
        // overflow a shorter card header.
        constraints: const BoxConstraints.tightFor(width: 32).copyWith(maxHeight: 32),
        child: OverflowBox(
          minHeight: 32,
          maxHeight: 32,
          child: IconButton(
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            iconSize: 18,
            style: ButtonStyle.from(
              minimumSize: const Size.square(32),
              fixedSize: const Size.square(32),
              tapTargetSize: TapTargetSize.shrinkWrap,
              foregroundColor: color ?? context.colorScheme.onSurfaceVariant,
            ),
            onPressed: onPressed,
            icon: GlyphIcon(glyph, size: 18),
          ),
        ),
      );
}
