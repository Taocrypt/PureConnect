import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/clash_rules.dart';
import '../../core/protocol.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

class ResourcesPage extends ConsumerStatefulWidget {
  const ResourcesPage({super.key});
  @override
  ConsumerState<ResourcesPage> createState() => _ResourcesPageState();
}

class _ResourcesPageState extends ConsumerState<ResourcesPage> {
  int _tab = 3; // 3 portal, 0 routes, 1 ip, 2 domains
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(coreProvider.select((s) => s.session));
    final mobile = isMobileLayout(context);
    if (session == null) {
      return AppPage(
        title: context.tr('resources'),
        body: EmptyHint(glyph: AppGlyphs.resources, text: context.tr('not_connected_hint')),
      );
    }
    final q = _q.toLowerCase();
    if (_tab == 3 && session.webResources.isEmpty && session.rawResources.isEmpty) _tab = 0;
    final favs = ref.watch(settingsProvider.select((s) => s.favoriteResources)).toSet();
    final matching = session.webResources
        .where((w) => q.isEmpty || '${w.name} ${w.url} ${w.group}'.toLowerCase().contains(q))
        .toList();
    // 我的收藏 pinned on top; favorites also stay in their own group.
    final favLabel = context.tr('favorites');
    final web = [
      for (final w in matching)
        if (favs.contains(w.favKey)) (w, favLabel),
      for (final w in matching) (w, _groupLabel(context, w.group)),
    ];
    // (title, subtitle, connectivity test target)
    final List<(String, String, ProbeTarget?)> rows = switch (_tab) {
      3 => [
          for (final (w, _) in web)
            (w.name, w.url.isNotEmpty ? w.url : w.host, ProbeTarget.fromUrl(w.url.isNotEmpty ? w.url : w.host))
        ],
      0 => [for (final r in session.routes) (r, '', null)],
      1 => [for (final r in session.ipResources) (r.range, '${r.protocol} · ${r.ports}', ProbeTarget.fromIp(r))],
      _ => [for (final d in session.domainResources) (d, '', ProbeTarget.fromDomain(d))],
    }
        .where((r) => _tab == 3 || q.isEmpty || r.$1.toLowerCase().contains(q))
        .toList();
    final probes = ref.watch(probeProvider);
    final probeTargets = {for (final r in rows) if (r.$3 != null) r.$3!.key: r.$3!}.values.toList();
    final bottom = (mobile ? dockInset(context) + 24 : 24) + MediaQuery.paddingOf(context).bottom;
    final side = mobile ? 16.0 : 24.0;

    return AppPage(
      title: context.tr('resources'),
      actions: [
        if (_tab != 0)
          HeaderAction(
            glyph: AppGlyphs.speed,
            tooltip: context.tr('test_connectivity'),
            onPressed: probeTargets.isEmpty
                ? null
                : () => ref.read(probeProvider.notifier).run(probeTargets),
          ),
        HeaderAction(
          glyph: AppGlyphs.export,
          tooltip: context.tr('export_clash_rules'),
          onPressed: () => _exportClash(session),
        ),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 12),
          child: SegmentedControl<int>(
            segments: [
              if (session.webResources.isNotEmpty || session.rawResources.isNotEmpty)
                (3, '${context.tr('tab_portal')} ${session.webResources.length}'),
              (0, '${context.tr('routes')} ${session.routes.length}'),
              (1, 'IP ${session.ipResources.length}'),
              (2, '${context.tr('domain')} ${session.domainResources.length}'),
            ],
            value: _tab,
            onChanged: (v) => setState(() => _tab = v),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 12),
          child: SearchField(onChanged: (v) => setState(() => _q = v)),
        ),
        Expanded(
          child: rows.isEmpty
              ? EmptyHint(glyph: AppGlyphs.search, text: context.tr('empty'))
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(side, 0, side, bottom),
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final res = _tab == 3 ? web[i].$1 : null;
                    final group = _tab == 3 ? web[i].$2 : '';
                    final groupHeader = _tab == 3 && group.isNotEmpty && (i == 0 || web[i - 1].$2 != group);
                    final fav = res != null && favs.contains(res.favKey);
                    final target = rows[i].$3;
                    final probe = target == null ? null : probes[target.key];
                    final latency = switch (probe?.status) {
                      ProbeStatus.ok || ProbeStatus.slow => '${probe!.ms} ms',
                      ProbeStatus.fail => context.tr(probe!.error == 'timeout' ? 'probe_timeout' : 'probe_failed'),
                      _ => null,
                    };
                    final item = Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DashboardBlock(
                      color: DashboardColors.of(context).card,
                      padding: EdgeInsetsDirectional.fromSTEB(target != null ? 6 : 18, 12, 8, 12),
                      child: Row(children: [
                        if (target != null)
                          _ProbeDot(
                            state: probes[target.key],
                            onTap: () => ref.read(probeProvider.notifier).run([target]),
                          ),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text.rich(
                              TextSpan(children: [
                                TextSpan(text: rows[i].$1),
                                if (latency != null)
                                  TextSpan(
                                    text: '  $latency',
                                    style: DashboardText.label(context).copyWith(color: _probeColor(context, probe!.status)),
                                  ),
                              ]),
                              style: AppTextStyle.subheadline.of(context, emphasized: true).toTabular,
                            ),
                            if (rows[i].$2.isNotEmpty) Text(rows[i].$2, style: DashboardText.label(context)),
                          ]),
                        ),
                        if (res != null)
                          DashboardIconButton(
                            glyph: fav ? AppGlyphs.starFilled : AppGlyphs.star,
                            color: fav ? context.colorScheme.primary : null,
                            tooltip: context.tr(fav ? 'favorite_remove' : 'favorite_add'),
                            onPressed: () => ref.read(settingsProvider.notifier).update((x) {
                              if (!x.favoriteResources.remove(res.favKey)) x.favoriteResources.add(res.favKey);
                            }),
                          ),
                        if (res != null && (res.url.isNotEmpty || _openable(res.host)))
                          DashboardIconButton(
                            glyph: AppGlyphs.openExternal,
                            tooltip: context.tr('open_link'),
                            onPressed: () => openInBrowser(context, res.url.isNotEmpty ? res.url : res.host),
                          ),
                        DashboardIconButton(
                          glyph: AppGlyphs.copy,
                          tooltip: context.tr('copy'),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _tab == 3 && rows[i].$2.isNotEmpty ? rows[i].$2 : rows[i].$1));
                            showToast(context, context.tr('copied'), level: BannerLevel.success);
                          },
                        ),
                      ]),
                    ),
                  );
                    if (!groupHeader) return item;
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 12, bottom: 8, left: 4),
                        child: Text(group, style: DashboardText.label(context)),
                      ),
                      item,
                    ]);
                  },
                ),
        ),
      ]),
    );
  }

  /// The server names its catch-all group "Default group"; show it localized.
  static String _groupLabel(BuildContext context, String g) {
    final t = g.trim().toLowerCase();
    if (t == 'default group' || t == 'default' || t == '默认资源组' || t == '默认组') return context.tr('default_group');
    return g;
  }

  Future<void> _exportClash(SessionInfo session) async {
    final text = buildClashRules(session);
    final how = await pickOne<int>(
      context,
      title: context.tr('export_clash_rules'),
      options: [
        (0, context.tr('copy_to_clipboard')),
        (1, context.tr('save_as_file')),
        if (session.rawResources.isNotEmpty) (2, context.tr('export_rclist')),
      ],
      current: -1,
    );
    if (!mounted || how == null) return;
    if (how == 2) {
      try {
        await FilePicker.saveFile(
          fileName: 'rclist.xml',
          bytes: Uint8List.fromList(utf8.encode(session.rawResources)),
          mimeType: 'application/xml',
        );
      } catch (e) {
        if (mounted) showToast(context, '$e', level: BannerLevel.error);
      }
      return;
    }
    if (how == 0) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) showToast(context, context.tr('clash_rules_copied'), level: BannerLevel.success);
      return;
    }
    try {
      final uri = await FilePicker.saveFile(
        fileName: 'pureconnect-clash.yaml',
        bytes: Uint8List.fromList(utf8.encode(text)),
        mimeType: 'application/x-yaml',
      );
      if (uri != null && mounted) showToast(context, context.tr('saved'), level: BannerLevel.success);
    } catch (e) {
      if (mounted) showToast(context, '$e', level: BannerLevel.error);
    }
  }
}

Color _probeColor(BuildContext context, ProbeStatus s) {
  final c = DashboardColors.of(context);
  return switch (s) {
    ProbeStatus.ok => const Color(0xFF34C759),
    ProbeStatus.slow => const Color(0xFFFF9500),
    ProbeStatus.fail => context.colorScheme.error,
    ProbeStatus.testing => c.tone,
  };
}

/// Status dot before a tested resource; tap to test it again.
class _ProbeDot extends StatelessWidget {
  const _ProbeDot({required this.state, required this.onTap});
  final ProbeState? state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = state?.status;
    final color = s == null ? context.colorScheme.outlineVariant : _probeColor(context, s);
    return PressRegion(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 40,
        child: Center(
          child: s == ProbeStatus.testing
              ? const ActivityIndicator(size: 12)
              : Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
        ),
      ),
    );
  }
}

/// A bare IP / host (not a range, wildcard or CIDR) can still be opened.
bool _openable(String host) =>
    host.isNotEmpty && !RegExp(r'[*~/\s]').hasMatch(host) &&
    !(host.contains('-') && RegExp(r'^[0-9]').hasMatch(host));
