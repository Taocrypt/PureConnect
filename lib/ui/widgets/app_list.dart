import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/apps.dart';
import '../../l10n/strings.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

/// Searchable list of installed apps, like FlClash's per-app proxy list.
///
/// Multi-select: pass [selected] + [onToggle] (checkboxes). Single-select:
/// pass [selectedOne] + [onPick]; [noneLabel] adds a first row meaning "none"
/// (picked as '').
class AppListView extends StatefulWidget {
  const AppListView({
    super.key,
    this.browsers = false,
    this.selected,
    this.onToggle,
    this.selectedOne,
    this.onPick,
    this.noneLabel,
    this.footer,
  });

  final bool browsers;
  final Set<String>? selected;
  final void Function(String package, bool value)? onToggle;
  final String? selectedOne;
  final ValueChanged<String>? onPick;
  final String? noneLabel;
  final String? footer;

  @override
  State<AppListView> createState() => _AppListViewState();
}

class _AppListViewState extends State<AppListView> {
  List<AppInfo>? _apps;
  String _query = '';
  bool _showSystem = false;

  bool get _multi => widget.onToggle != null;

  @override
  void initState() {
    super.initState();
    listApps(browsers: widget.browsers).then((a) {
      if (mounted) setState(() => _apps = a);
    });
  }

  List<AppInfo> _visible() {
    final q = _query.trim().toLowerCase();
    final sel = widget.selected ?? const <String>{};
    var list = (_apps ?? const <AppInfo>[]).where((a) {
      if (q.isNotEmpty) return a.label.toLowerCase().contains(q) || a.package.toLowerCase().contains(q);
      return widget.browsers || _showSystem || !a.system || sel.contains(a.package) || a.package == widget.selectedOne;
    }).toList();
    // Chosen apps first.
    if (_multi) {
      list = [...list.where((a) => sel.contains(a.package)), ...list.where((a) => !sel.contains(a.package))];
    }
    // Selected packages that are not installed (or not visible to us).
    if (_multi && q.isEmpty && _apps != null) {
      final known = _apps!.map((a) => a.package).toSet();
      list = [for (final p in sel) if (!known.contains(p)) AppInfo(p, p), ...list];
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final mobile = isMobileLayout(context);
    final bottom = (mobile ? NavigationDock.heightOf(context) + 24 : 24) + MediaQuery.paddingOf(context).bottom;
    final hPad = mobile ? 16.0 : 24.0;
    final apps = _visible();
    final hasNone = widget.noneLabel != null && _query.isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 8),
        child: Row(spacing: 8, children: [
          Expanded(
            child: SearchField(
              hintText: context.tr('search_apps'),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (!widget.browsers)
            PressRegion(
              onTap: () => setState(() => _showSystem = !_showSystem),
              child: DashboardChip(
                label: context.tr('system_apps'),
                tone: _showSystem ? DashboardChipTone.ok : DashboardChipTone.idle,
                dot: _showSystem,
              ),
            ),
        ]),
      ),
      if (widget.footer != null)
        Padding(
          padding: EdgeInsets.fromLTRB(hPad + 4, 0, hPad, 8),
          child: Text(widget.footer!, style: DashboardText.label(context)),
        ),
      Expanded(
        child: _apps == null
            ? const Center(child: ActivityIndicator())
            : apps.isEmpty && !hasNone
                ? EmptyHint(glyph: AppGlyphs.appsList, text: context.tr('empty'))
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(hPad, 0, hPad, bottom),
                    itemExtent: 64,
                    itemCount: apps.length + (hasNone ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (hasNone && i == 0) {
                        return _row(context,
                            leading: const _IconBox(child: GlyphIcon(AppGlyphs.language, size: 24)),
                            title: widget.noneLabel!,
                            subtitle: null,
                            checked: widget.selectedOne?.isEmpty ?? true,
                            onTap: () => widget.onPick?.call(''));
                      }
                      final a = apps[i - (hasNone ? 1 : 0)];
                      final checked =
                          _multi ? widget.selected!.contains(a.package) : widget.selectedOne == a.package;
                      return _row(context,
                          leading: _AppIcon(a.package),
                          title: a.label,
                          subtitle: a.package,
                          checked: checked,
                          onTap: () => _multi ? widget.onToggle!(a.package, !checked) : widget.onPick?.call(a.package));
                    },
                  ),
      ),
    ]);
  }

  Widget _row(BuildContext context,
      {required Widget leading,
      required String title,
      required String? subtitle,
      required bool checked,
      required VoidCallback onTap}) {
    return PressRegion(
      onTap: onTap,
      overlay: PressRegion.hoverOverlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(spacing: 12, children: [
          leading,
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyle.body.of(context)),
              if (subtitle != null)
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: DashboardText.label(context)),
            ]),
          ),
          if (_multi)
            Checkbox(value: checked, onChanged: (_) => onTap())
          else if (checked)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GlyphIcon(AppGlyphs.check, size: 20, color: context.colorScheme.primary),
            ),
        ]),
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SizedBox(width: 40, height: 40, child: Center(child: child));
}

class _AppIcon extends StatelessWidget {
  const _AppIcon(this.package);
  final String package;

  @override
  Widget build(BuildContext context) => _IconBox(
        child: FutureBuilder<Uint8List?>(
          future: appIcon(package),
          builder: (context, snap) => snap.data == null
              ? GlyphIcon(AppGlyphs.appsList, size: 24, color: context.colorScheme.onSurfaceVariant)
              : Image.memory(snap.data!, width: 40, height: 40, gaplessPlayback: true),
        ),
      );
}
