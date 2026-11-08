import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/providers.dart';
import '../../core/open_url.dart';
import '../../l10n/strings.dart';
import 'app_glyphs.dart';
import 'dashboard_kit.dart';

/// A page: large title on the page surface, optional back button and
/// trailing actions, like FlClash's pages.
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.canPop = false,
    this.floating,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool canPop;

  /// Pinned to the bottom end (e.g. an add button).
  final Widget? floating;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final mobile = isMobileLayout(context);
    return Surface(
      color: SurfaceLevel.page.colorOf(colorScheme),
      child: SafeArea(
        bottom: false,
        child: Stack(children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: mobile ? 60 : 68,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(start: canPop ? 8 : (mobile ? 20 : 24), end: mobile ? 12 : 20),
                  child: Row(spacing: 4, children: [
                    if (canPop)
                      IconButton(
                        tooltip: UiLocalizations.of(context).back,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const GlyphIcon(AppGlyphs.arrowBack),
                      ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (canPop ? AppTextStyle.headline : AppTextStyle.pageTitle)
                            .of(context, emphasized: true),
                      ),
                    ),
                    ...actions,
                  ]),
                ),
              ),
              Expanded(child: body),
            ],
          ),
          if (floating != null)
            PositionedDirectional(
              end: mobile ? 20 : 28,
              bottom: (mobile ? NavigationDock.heightOf(context) + 28 : 28) +
                  MediaQuery.paddingOf(context).bottom,
              child: floating!,
            ),
        ]),
      ),
    );
  }
}

/// Round action in a page header.
class HeaderAction extends StatelessWidget {
  const HeaderAction({super.key, required this.glyph, required this.tooltip, required this.onPressed, this.filled = false, this.color, this.foreground});

  final Glyph glyph;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled;
  final Color? color;
  final Color? foreground;

  @override
  Widget build(BuildContext context) => filled
      ? IconButton.filled(
          tooltip: tooltip,
          onPressed: onPressed,
          style: ButtonStyle.from(backgroundColor: color, foregroundColor: foreground),
          icon: GlyphIcon(glyph, fill: 1),
        )
      : IconButton(tooltip: tooltip, onPressed: onPressed, icon: GlyphIcon(glyph));
}

/// Scrollable column of page content, padded the way the dashboard is and
/// leaving room for the phone's floating dock.
class PageList extends StatelessWidget {
  const PageList({super.key, required this.children, this.maxWidth = 760});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final mobile = isMobileLayout(context);
    final bottom = (mobile ? NavigationDock.heightOf(context) + 24 : 24) + MediaQuery.paddingOf(context).bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(mobile ? 16 : 24, 4, mobile ? 16 : 24, bottom),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ],
    );
  }
}

/// A titled group of rows in one rounded card (FlClash settings style).
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children, this.footer});

  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final rows = <Widget>[];
    for (final (i, c) in children.indexed) {
      if (i > 0) {
        rows.add(Padding(
          padding: const EdgeInsetsDirectional.only(start: 20),
          child: Container(height: 0.5, color: colorScheme.outlineVariant),
        ));
      }
      rows.add(c);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title!, style: DashboardText.cardTitle(context)),
            ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: ShapeDecoration(
              color: DashboardColors.of(context).card,
              shape: AppShape.all(24),
              shadows: DashboardShadows.e1(context),
            ),
            child: Column(children: rows),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(footer!, style: DashboardText.label(context)),
            ),
        ],
      ),
    );
  }
}

/// One row of a [SettingsGroup].
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.glyph,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.chevron = false,
    this.destructive = false,
  });

  final Glyph? glyph;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final row = ListRow(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      minHeight: 56,
      leading: glyph == null
          ? null
          : GlyphIcon(glyph!, size: 22, color: destructive ? colorScheme.error : colorScheme.onSurfaceVariant),
      title: Text(title,
          style: AppTextStyle.body.of(context).copyWith(color: destructive ? colorScheme.error : null)),
      subtitle: subtitle == null || subtitle!.isEmpty
          ? null
          : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: DashboardText.label(context)),
      trailing: trailing == null && !chevron
          ? null
          : Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
              ?trailing,
              if (chevron) GlyphIcon(AppGlyphs.chevronForward, size: 18, color: colorScheme.onSurfaceVariant),
            ]),
    );
    if (onTap == null) return row;
    return PressRegion(onTap: onTap, overlay: PressRegion.hoverOverlay, child: row);
  }
}

class SwitchTile extends StatelessWidget {
  const SwitchTile({super.key, this.glyph, required this.title, this.subtitle, required this.value, required this.onChanged});

  final Glyph? glyph;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SettingsTile(
        glyph: glyph,
        title: title,
        subtitle: subtitle,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: DashboardSwitch(value: value, onChanged: onChanged),
      );
}

/// A big empty state with a glyph, used by resources/logs.
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.glyph, required this.text});

  final Glyph glyph;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, spacing: 14, children: [
          ShapeBadgeIcon(glyph: glyph),
          Text(text,
              textAlign: TextAlign.center,
              style: AppTextStyle.subheadline.of(context).copyWith(color: colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class ShapeBadgeIcon extends StatelessWidget {
  const ShapeBadgeIcon({super.key, required this.glyph});
  final Glyph glyph;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return SizedBox.square(
      dimension: 72,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: DashboardColors.of(context).tone, shape: AppShape.all(26)),
        child: Center(child: GlyphIcon(glyph, size: 32, color: colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Feedback
// ---------------------------------------------------------------------------

void showToast(BuildContext context, String text, {BannerLevel level = BannerLevel.info}) =>
    BannerHost.maybeOf(context)?.show(text, level: level);

Future<bool> confirm(BuildContext context, {required String title, String? message, bool destructive = false}) async {
  final r = await showFloatingDialog<bool>(
    context: context,
    child: Builder(
      builder: (ctx) => AlertDialog(
        title: title,
        destructive: destructive,
        child: message == null ? null : Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.tr('ok'))),
        ],
      ),
    ),
  );
  return r == true;
}

Future<void> notice(BuildContext context, {required String title, String? message}) => showFloatingDialog<void>(
      context: context,
      child: Builder(
        builder: (ctx) => AlertDialog(
          title: title,
          child: message == null ? null : Text(message),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('ok')))],
        ),
      ),
    );

Future<String?> editTextDialog(
  BuildContext context, {
  required String title,
  required String initial,
  String? hint,
  String? message,
  bool obscure = false,
  TextInputType? type,
}) {
  final c = TextEditingController(text: initial);
  return showFloatingDialog<String>(
    context: context,
    child: Builder(
      builder: (ctx) => AlertDialog(
        title: title,
        hasFields: true,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
          if (message != null) Text(message, style: DashboardText.label(ctx)),
          TextField(
            controller: c,
            autofocus: true,
            obscureText: obscure,
            keyboardType: type,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(ctx.tr('ok'))),
        ],
      ),
    ),
  );
}

Future<String?> askPassword(BuildContext context, String title, String hint) =>
    editTextDialog(context, title: title, initial: '', message: hint, obscure: true);

/// Lets the user pick one of [options] in a dialog.
Future<T?> pickOne<T>(BuildContext context, {required String title, required List<(T, String)> options, required T current}) {
  return showFloatingDialog<T>(
    context: context,
    child: Builder(
      builder: (ctx) => AlertDialog(
        title: title,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (v, label) in options)
            PressRegion(
              onTap: () => Navigator.pop(ctx, v),
              overlay: PressRegion.hoverOverlay,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                child: Row(children: [
                  Expanded(child: Text(label, style: AppTextStyle.body.of(ctx))),
                  if (v == current) GlyphIcon(AppGlyphs.check, size: 20, color: ctx.colorScheme.primary),
                ]),
              ),
            ),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel')))],
      ),
    ),
  );
}

Future<T?> pushPage<T>(BuildContext context, WidgetBuilder builder) =>
    Navigator.of(context).push<T>(CardPageRoute<T>(builder: builder));

/// Opens [url] in the browser chosen in settings (Android), else the system
/// default.
Future<void> openInBrowser(BuildContext context, String url) async {
  final pkg = ProviderScope.containerOf(context, listen: false).read(settingsProvider).browserPackage;
  await openUrl(url, package: pkg.isEmpty ? null : pkg);
}
