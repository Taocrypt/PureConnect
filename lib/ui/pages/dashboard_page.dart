import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:prism_ui/shapes/shapes.dart';

import '../../core/protocol.dart';
import '../../l10n/strings.dart';
import '../../models/profile.dart';
import '../../models/settings.dart';
import '../../core/errors.dart';
import '../../core/memory_info.dart';
import '../../state/providers.dart';
import '../home_shell.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';
import '../kit/topology.dart';
import '../tour/guide_tour.dart';

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// Ticks once a second while connected.
final _clockProvider = StreamProvider<DateTime>(
    (ref) => Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()));

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(coreProvider);
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);
    final (statusGlyph, statusFill, statusInk) = switch (st.state) {
      CoreState.connected => (AppGlyphs.check, colors.okContainer, colors.onOkContainer),
      CoreState.error => (AppGlyphs.error, colorScheme.errorContainer, colorScheme.onErrorContainer),
      CoreState.starting || CoreState.connecting || CoreState.stopping =>
        (AppGlyphs.sync, colors.warnContainer, colors.onWarnContainer),
      _ => (AppGlyphs.status, colors.tone, colorScheme.onSurfaceVariant),
    };
    return AppPage(
      title: context.tr('dashboard'),
      actions: [
        Builder(
          builder: (btnContext) => HeaderAction(
            glyph: statusGlyph,
            tooltip: context.tr('status'),
            filled: true,
            color: statusFill,
            foreground: statusInk,
            onPressed: () => showTrafficPopup(btnContext),
          ),
        ),
      ],
      body: LayoutBuilder(builder: (context, c) {
        final mobile = isMobileLayout(context);
        final hPad = mobile ? math.max(16.0, (c.maxWidth - 560) / 2) : 24.0;
        final bottom = (mobile ? NavigationDock.heightOf(context) + 28 : 24) + MediaQuery.paddingOf(context).bottom;
        const gap = 16.0;
        if (mobile) {
          return ListView(
            padding: EdgeInsets.fromLTRB(hPad, 4, hPad, bottom),
            children: [
              for (final w in [
                const _StatusCard(),
                const _ModeCard(),
                const _TopologyCard(),
                const _RecentLogsCard(height: 260),
              ]) ...[w, const SizedBox(height: gap)],
            ],
          );
        }
        final cols = c.maxWidth - hPad * 2 >= 860 ? 4 : 2;
        final unit = (c.maxWidth - hPad * 2 - gap * (cols - 1)) / cols;
        double w(int n) => unit * n + gap * (n - 1);
        Widget box(int n, Widget child, {double? h}) => SizedBox(width: w(math.min(n, cols)), height: h, child: child);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(hPad, 4, hPad, bottom),
          child: Wrap(spacing: gap, runSpacing: gap, children: [
            box(2, const _StatusCard(), h: 206),
            box(2, const _MemoryCard(), h: 206),
            box(4, const _ModeCard()),
            box(4, const _TopologyCard()),
            box(4, const _RecentLogsCard(height: 290)),
          ]),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Status: virtual IP, run time, server, and the morphing start button.
// ---------------------------------------------------------------------------

class _StatusCard extends ConsumerWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(coreProvider);
    if (st.isConnected) ref.watch(_clockProvider);
    final profile = ref.watch(selectedProfileProvider);
    final mobile = isMobileLayout(context);
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);
    final running = st.isConnected;
    final (chip, tone) = switch (st.state) {
      CoreState.connected => (context.tr('running'), DashboardChipTone.ok),
      CoreState.starting || CoreState.connecting => (context.tr('connecting'), DashboardChipTone.warn),
      CoreState.stopping => (context.tr('stopping'), DashboardChipTone.warn),
      CoreState.error => (context.tr('error'), DashboardChipTone.error),
      _ => (context.tr('not_running'), DashboardChipTone.idle),
    };
    final ip = st.session?.ip;
    final uptime = running && st.startedAt != null ? formatDuration(DateTime.now().difference(st.startedAt!)) : '—';
    final server = st.session?.server ?? '${profile?.effectiveServer ?? '-'}:${profile?.serverPort ?? 443}';
    final protocol = profile?.protocol == VpnProtocol.atrust ? 'aTrust' : 'EasyConnect';
    final buttonSize = mobile ? 88.0 : 104.0;
    final radius = dashboardCardRadius(context);

    return DashboardCard(
      padding: EdgeInsets.zero,
      child: Stack(children: [
        // Soft cookie blob behind the start button, as in FlClash.
        Positioned.fill(
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: AppShape.all(radius), textDirection: Directionality.of(context)),
            child: Stack(clipBehavior: Clip.none, children: [
              PositionedDirectional(
                end: mobile ? -60 : -64,
                top: mobile ? -66 : -87,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: running ? 1 : 0),
                  duration: context.motionDuration(const Duration(milliseconds: 450)),
                  curve: Curves.easeOutBack,
                  builder: (_, p, _) => Transform.rotate(
                    angle: 2 * math.pi / 12 * p,
                    child: Transform.scale(
                      scale: 1 + 0.12 * p,
                      child: ShapeBadge(
                        shape: MaterialShapes.cookie12Sided,
                        color: Color.lerp(
                          colors.tone,
                          Color.alphaBlend(colorScheme.primary.withValues(alpha: 0.1), colors.card),
                          p.clamp(0, 1),
                        )!,
                        size: mobile ? 240 : 290,
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
        Padding(
          padding: mobile ? const EdgeInsetsDirectional.fromSTEB(20, 18, 16, 18) : dashboardCardPadding(context),
          child: Row(spacing: mobile ? 10 : 16, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DashboardCardHeader(
                  glyph: AppGlyphs.status,
                  title: context.tr('status'),
                  leading: [DashboardChip(label: chip, tone: tone, dot: running)],
                ),
                SizedBox(height: mobile ? 12 : 10),
                Row(spacing: 10, children: [
                  _Monogram(text: protocol == 'aTrust' ? 'AT' : 'EC'),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          ip != null && ip.isNotEmpty ? ip : (st.isBusy ? '···' : '—'),
                          maxLines: 1,
                          style: DashboardText.figure(context, mobile ? AppTextStyle.title2 : AppTextStyle.title1),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        DashboardChip(label: protocol),
                        if (st.session?.stack case final s? when s.isNotEmpty)
                          DashboardChip(label: s.toUpperCase().replaceAll('_', ' ')),
                      ]),
                      if (st.state == CoreState.error && st.error != null) ...[
                        const SizedBox(height: 6),
                        Text(humanizeError(context, st.error!),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: DashboardText.label(context).copyWith(color: colorScheme.error)),
                      ],
                    ]),
                  ),
                ]),
                if (mobile) const SizedBox(height: 16) else const Spacer(),
                Row(spacing: 28, children: [
                  DashboardCell(label: context.tr('uptime'), value: uptime),
                  Flexible(child: DashboardCell(label: context.tr('server'), value: server)),
                ]),
              ]),
            ),
            SizedBox(
              width: mobile ? buttonSize : 120,
              child: Center(child: GuideTarget(id: 'connect', child: _StartToggle(size: buttonSize))),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: 48,
        height: 48,
        decoration: ShapeDecoration(color: DashboardColors.of(context).tone, shape: AppShape.circle),
        alignment: Alignment.center,
        child: Text(text, style: AppTextStyle.subheadline.of(context, emphasized: true)),
      );
}

final _startMorph = Morph(MaterialShapes.circle, MaterialShapes.cookie9Sided);

/// A circle with a play glyph while stopped that grows into the cookie-9 of
/// a running tunnel (M3 Expressive shape morph), like FlClash's start button.
class _StartToggle extends ConsumerStatefulWidget {
  const _StartToggle({required this.size});
  final double size;

  @override
  ConsumerState<_StartToggle> createState() => _StartToggleState();
}

class _StartToggleState extends ConsumerState<_StartToggle> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
    value: ref.read(coreProvider).isActive ? 1 : 0,
  );
  late final CurvedAnimation _progress =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
  bool _hovered = false;

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(coreProvider);
    final active = st.isActive;
    if (active && _controller.status != AnimationStatus.forward && _controller.value < 1) {
      _controller.forward();
    } else if (!active && _controller.status != AnimationStatus.reverse && _controller.value > 0) {
      _controller.reverse();
    }
    final colorScheme = context.colorScheme;
    final enabled = st.state != CoreState.stopping;
    final fill = Color.alphaBlend(colorScheme.onPrimary.withValues(alpha: _hovered ? 0.08 : 0), colorScheme.primary);
    final size = widget.size;
    return Tooltip(
      message: active ? context.tr('disconnect') : context.tr('connect'),
      child: PressRegion(
        onTap: enabled
            ? () {
                GuideTour.instance.targetUsed(GuideStep.connect);
                toggleConnection(context, ref);
              }
            : null,
        onHover: (v) => setState(() => _hovered = v),
        child: ElasticPress(
          enabled: enabled,
          child: AnimatedBuilder(
            animation: _progress,
            builder: (_, _) {
              final p = _progress.value;
              return CustomPaint(
                painter: _MorphPainter(progress: p, color: fill, shadow: colorScheme.primary.withValues(alpha: 0.3)),
                child: SizedBox.square(
                  dimension: size,
                  child: Center(
                    child: st.isBusy
                        ? ActivityIndicator(size: size * 0.3, color: colorScheme.onPrimary)
                        : GlyphIcon(AppGlyphs.playPause(p.clamp(0, 1)), size: size * 0.34, color: colorScheme.onPrimary, fill: 1),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MorphPainter extends CustomPainter {
  const _MorphPainter({required this.progress, required this.color, required this.shadow});

  final double progress;
  final Color color;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _startMorph.toPath(progress: progress);
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(progress * 2 * math.pi / 9)
      ..scale(size.width, size.height)
      ..translate(-0.5, -0.5);
    canvas
      ..save()
      ..translate(0, 6 / size.height)
      ..drawPath(path, Paint()
        ..color = shadow
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7 / size.width))
      ..restore()
      ..drawPath(path, Paint()..color = color)
      ..restore();
  }

  @override
  bool shouldRepaint(_MorphPainter old) => old.progress != progress || old.color != color || old.shadow != shadow;
}

// ---------------------------------------------------------------------------
// Traffic mode: connected buttons + system proxy / TUN switch tiles.
// ---------------------------------------------------------------------------

class _ModeCard extends ConsumerWidget {
  const _ModeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.trafficMode));
    final android = Platform.isAndroid;
    final mobile = isMobileLayout(context);
    final items = <(TrafficMode, Glyph, String)>[
      (TrafficMode.proxy, AppGlyphs.proxies, context.tr('mode_proxy')),
      if (!android) (TrafficMode.systemProxy, AppGlyphs.shuffle, context.tr('mode_system_proxy')),
      (TrafficMode.tun, AppGlyphs.vpn, android ? context.tr('mode_vpn') : context.tr('mode_tun')),
    ];
    final effective = android && mode == TrafficMode.systemProxy ? TrafficMode.proxy : mode;
    final buttons = DashboardConnectedButtons<TrafficMode>(
      items: items,
      value: effective,
      vertical: mobile,
      height: mobile ? 64 : 44,
      onChanged: (v) => switchTrafficMode(context, ref, v),
    );
    if (mobile) {
      return DashboardCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DashboardCardHeader(glyph: AppGlyphs.split, title: context.tr('traffic_mode')),
          const SizedBox(height: 14),
          buttons,
        ]),
      );
    }
    return DashboardCard(
      padding: const EdgeInsetsDirectional.fromSTEB(22, 10, 10, 10),
      child: Row(spacing: 12, children: [
        GlyphIcon(AppGlyphs.split, size: 18, color: context.colorScheme.onSurfaceVariant),
        Text(context.tr('traffic_mode'), style: DashboardText.cardTitle(context)),
        Expanded(child: buttons),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Small cards
// ---------------------------------------------------------------------------

/// Memory of the app and the core, after FlClash's memory card: total,
/// a stacked bar and a legend; refreshed every 2 s.
class _MemoryCard extends ConsumerStatefulWidget {
  const _MemoryCard();

  @override
  ConsumerState<_MemoryCard> createState() => _MemoryCardState();
}

class _MemoryCardState extends ConsumerState<_MemoryCard> {
  Timer? _timer;
  MemorySnapshot _m = MemorySnapshot.empty;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  void _poll() {
    if (!mounted) return;
    final st = ref.read(coreProvider);
    final core = st.isActive ? ref.read(trafficProvider).mem : 0;
    final next = MemorySnapshot.read(core: core);
    if (next.app != _m.app || next.core != _m.core) setState(() => _m = next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final colors = DashboardColors.of(context);
    final parts = [
      (label: context.tr('memory_app'), bytes: _m.app, color: cs.primary),
      (label: context.tr('memory_core'), bytes: _m.core, color: cs.tertiary),
    ];
    final shares = MemorySnapshot.shares([for (final p in parts) p.bytes]);
    final total = formatBytes(_m.total).split(' ');
    return DashboardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DashboardCardHeader(glyph: AppGlyphs.memory, title: context.tr('memory_info')),
        const SizedBox(height: 6),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: total.first, style: DashboardText.figure(context, AppTextStyle.title2)),
            if (total.length > 1) TextSpan(text: ' ${total.last}', style: DashboardText.unit(context)),
          ]),
          maxLines: 1,
        ),
        const Spacer(),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: _m.total == 0
                ? ColoredBox(color: colors.tone2)
                : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final (i, p) in parts.indexed)
                      if (shares[i] > 0) ...[
                        if (i > 0 && shares.take(i).any((v) => v > 0)) const SizedBox(width: 2),
                        Expanded(flex: shares[i], child: ColoredBox(color: p.color)),
                      ],
                  ]),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 16, runSpacing: 4, children: [
          for (final p in parts)
            Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
              DecoratedBox(
                decoration: BoxDecoration(color: p.color, shape: BoxShape.circle),
                child: const SizedBox.square(dimension: 8),
              ),
              Text(p.label, style: DashboardText.label(context)),
              Text(p.bytes == 0 ? '-' : formatBytes(p.bytes),
                  style: AppTextStyle.footnote.of(context, emphasized: true).toTabular),
            ]),
        ]),
      ]),
    );
  }
}

class _RecentLogsCard extends ConsumerWidget {
  const _RecentLogsCard({required this.height});
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(logsProvider);
    final recent = logs.length > 40 ? logs.sublist(logs.length - 40) : logs;
    final colorScheme = context.colorScheme;
    String ts(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return SizedBox(
      height: height,
      child: DashboardCard(
        onTap: () => ref.read(currentTabProvider.notifier).go(AppTab.logs),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DashboardCardHeader(
            glyph: AppGlyphs.logs,
            title: context.tr('recent_logs'),
            leading: [DashboardChip(label: '${logs.length}')],
            chevron: true,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: recent.isEmpty
                ? Center(child: Text(context.tr('empty'), style: DashboardText.label(context)))
                : DashboardBlock(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: ListView.builder(
                      reverse: true,
                      itemCount: recent.length,
                      itemBuilder: (_, i) {
                        final e = recent[recent.length - 1 - i];
                        final color = switch (e.level) {
                          'error' => colorScheme.error,
                          'warning' => colorScheme.warning,
                          _ => colorScheme.onSurfaceVariant,
                        };
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 10, children: [
                            Text(ts(e.time), style: DashboardText.label(context)),
                            Expanded(
                              child: Text(e.message,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyle.caption1.of(context).copyWith(color: color == colorScheme.onSurfaceVariant ? colorScheme.onSurface : color)),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Connection topology (FlowZ-style Sankey)
// ---------------------------------------------------------------------------

class _TopologyCard extends ConsumerWidget {
  const _TopologyCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flows = ref.watch(flowsProvider);
    final active = ref.watch(coreProvider.select((s) => s.state == CoreState.connected));
    final mobile = isMobileLayout(context);
    final maxHosts = mobile ? 8 : 14;
    final rows = TopologyView.rowsFor(flows, maxHosts);
    final height = flows.isEmpty ? 120.0 : (rows * (mobile ? 30.0 : 28.0) + 24).clamp(150.0, 480.0);
    final total = flows.fold<int>(0, (a, f) => a + f.conns);
    String routeLabel(FlowRoute r) => switch (r) {
          FlowRoute.vpn => context.tr('route_vpn'),
          FlowRoute.direct => context.tr('route_direct'),
          FlowRoute.proxy => context.tr('route_proxy'),
          FlowRoute.blocked => context.tr('route_blocked'),
        };
    return DashboardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DashboardCardHeader(
          glyph: AppGlyphs.connections,
          title: context.tr('topology'),
          leading: [if (total > 0) DashboardChip(label: '$total')],
          trailing: [Text(context.tr('topology_hint'), style: DashboardText.label(context))],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: height,
          child: flows.isEmpty
              ? Center(
                  child: Text(active ? context.tr('empty') : context.tr('disconnected'),
                      style: DashboardText.label(context)))
              : TopologyView(
                  flows: flows,
                  maxHosts: maxHosts,
                  deviceLabel: context.tr('this_device'),
                  othersLabel: context.tr('others'),
                  routeLabel: routeLabel,
                  onHostLongPress: (h) {
                    Clipboard.setData(ClipboardData(text: h));
                    showToast(context, '${context.tr('copied')}: $h');
                  },
                ),
        ),
      ]),
    );
  }
}

/// Opens the traffic popup out of the control at [anchorContext].
void showTrafficPopup(BuildContext anchorContext) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return;
  final anchor = box.localToGlobal(Offset.zero) & box.size;
  Navigator.of(anchorContext).push(_TrafficPopupRoute(anchor, anchorContext.tr('close')));
}

/// A small solid card under the status button. Plain route (no glass
/// platter): the morphing popup rendered transparent on some Android GPUs.
class _TrafficPopupRoute extends PopupRoute<void> {
  _TrafficPopupRoute(this.anchor, this.barrierLabel);
  final Rect anchor;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => const Color(0x00000000);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final size = MediaQuery.sizeOf(context);
    final colors = DashboardColors.of(context);
    final right = math.max(12.0, size.width - anchor.right);
    return Stack(children: [
      Positioned(
        top: anchor.bottom + 6,
        right: right,
        child: FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: ScaleTransition(
            alignment: Alignment.topRight,
            scale: Tween(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.card.withAlpha(0xFF),
                borderRadius: BorderRadius.circular(18),
                boxShadow: DashboardShadows.e1(context),
              ),
              child: const TrafficPanel(),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Upload / download through the core for the current connection.
class TrafficPanel extends ConsumerWidget {
  const TrafficPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(trafficProvider);
    final connected = ref.watch(coreProvider.select((c) => c.state == CoreState.connected));
    final cs = context.colorScheme;
    Widget row(Glyph glyph, Color color, String label, int total, int rate) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            GlyphIcon(glyph, size: 16, color: color),
            const SizedBox(width: 6),
            SizedBox(
              width: 80,
              child: Text(formatBytes(total), maxLines: 1, softWrap: false, overflow: TextOverflow.visible, style: AppTextStyle.subheadline.of(context, emphasized: true).toTabular),
            ),
            SizedBox(
              width: 84,
              child: Text('${formatBytes(rate)}/s',
                  maxLines: 1, softWrap: false, textAlign: TextAlign.end, style: DashboardText.label(context).toTabular),
            ),
          ]),
        );
    return Semantics(
      label: '${context.tr('traffic_up')} / ${context.tr('traffic_down')}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.tr('traffic_title'), style: DashboardText.label(context)),
          const SizedBox(height: 2),
          row(AppGlyphs.arrowUp, cs.primary, context.tr('traffic_up'), t.tx, t.txRate),
          row(AppGlyphs.arrowDown, cs.tertiary, context.tr('traffic_down'), t.rx, t.rxRate),
          if (!connected) Text(context.tr('traffic_idle'), style: DashboardText.label(context)),
        ]),
      ),
    );
  }
}
