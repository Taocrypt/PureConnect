import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/protocol.dart';
import 'dashboard_kit.dart';

/// Sankey-style connection topology (this device -> destination -> route),
/// modelled on FlowZ's home page.
///
/// Hovering (mouse) or pressing (touch) a route bar temporarily shows only the
/// hosts on that route; hovering/pressing the "others" row temporarily lists
/// the hosts merged into it. Releasing / leaving restores the overview.
class TopologyView extends StatefulWidget {
  const TopologyView({
    super.key,
    required this.flows,
    required this.deviceLabel,
    required this.routeLabel,
    required this.othersLabel,
    this.maxHosts = 12,
    this.onHostLongPress,
  });

  final List<FlowInfo> flows;
  final String deviceLabel;
  final String Function(FlowRoute) routeLabel;
  final String othersLabel;
  final int maxHosts;
  final ValueChanged<String>? onHostLongPress;

  static Color routeColor(BuildContext context, FlowRoute r) {
    final c = context.colorScheme;
    return switch (r) {
      FlowRoute.vpn => c.primary,
      FlowRoute.direct => c.success,
      FlowRoute.proxy => c.warning,
      FlowRoute.blocked => c.error,
    };
  }

  /// Number of rows the view will draw, for sizing.
  static int rowsFor(List<FlowInfo> flows, int maxHosts) {
    final hosts = flows.map((e) => e.host).toSet().length;
    return hosts > maxHosts ? maxHosts + 1 : math.max(hosts, 1);
  }

  @override
  State<TopologyView> createState() => _TopologyViewState();
}

/// What is temporarily expanded: a route, or the "others" bucket (route null).
class _Focus {
  const _Focus.route(FlowRoute this.route) : others = false;
  const _Focus.others()
      : route = null,
        others = true;
  final FlowRoute? route;
  final bool others;
  @override
  bool operator ==(Object o) => o is _Focus && o.route == route && o.others == others;
  @override
  int get hashCode => Object.hash(route, others);
}

class _TopologyViewState extends State<TopologyView> {
  _Focus? _focus;
  _TopologyPainter? _painter;
  Size _size = Size.zero;

  void _set(_Focus? f) {
    if (f != _focus) setState(() => _focus = f);
  }

  /// Decide focus for a pointer at [p]. While focused, keep it as long as the
  /// pointer stays in the column that triggered it.
  void _probe(Offset p) {
    final painter = _painter;
    if (painter == null || !painter.laidOut) return;
    final f = _focus;
    if (f != null) {
      final keep = f.others ? painter.inHostColumn(p) : painter.inRouteColumn(p);
      if (keep) return;
    }
    _set(painter.focusAt(p));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final full = _TopologyModel.build(w.flows, w.maxHosts, w.othersLabel);
    final f = _focus;
    _TopologyModel model = full;
    if (f != null && f.others && full.hidden.isNotEmpty) {
      model = _TopologyModel.build(
          [for (final x in w.flows) if (full.hidden.contains(x.host)) x], w.maxHosts, w.othersLabel);
    } else if (f != null && f.route != null && full.routes.containsKey(f.route)) {
      model = _TopologyModel.build([for (final x in w.flows) if (x.route == f.route) x], w.maxHosts, w.othersLabel);
    }
    final c = context.colorScheme;
    final colors = <FlowRoute, Color>{for (final r in FlowRoute.values) r: TopologyView.routeColor(context, r)};
    return LayoutBuilder(builder: (context, box) {
      _size = Size(box.maxWidth, box.maxHeight);
      final painter = _painter = _TopologyPainter(
        model: model,
        deviceLabel: w.deviceLabel,
        routeLabel: w.routeLabel,
        routeColors: colors,
        deviceColor: c.primary,
        hostColor: c.tertiary,
        othersColor: c.outline,
        textColor: c.onSurface,
        mutedColor: c.onSurfaceVariant,
        labelStyle: AppTextStyle.caption1.of(context),
        countStyle: DashboardText.label(context),
        compact: box.maxWidth < 520,
        // Columns stay where the overview put them so the hover target
        // doesn't jump while expanded.
        anchor: f == null ? null : _TopologyPainter.columnsFor(full, w.deviceLabel, w.routeLabel,
            AppTextStyle.caption1.of(context), _size, box.maxWidth < 520),
      );
      return MouseRegion(
        onHover: (e) => _probe(e.localPosition),
        onExit: (_) => _set(null),
        child: Listener(
          onPointerDown: (e) {
            if (e.kind != PointerDeviceKind.mouse) _probe(e.localPosition);
          },
          onPointerMove: (e) {
            if (e.kind != PointerDeviceKind.mouse) _probe(e.localPosition);
          },
          onPointerUp: (e) {
            if (e.kind != PointerDeviceKind.mouse) _set(null);
          },
          onPointerCancel: (e) {
            if (e.kind != PointerDeviceKind.mouse) _set(null);
          },
          child: GestureDetector(
            onLongPressStart: w.onHostLongPress == null
                ? null
                : (d) {
                    final h = painter.hostAt(d.localPosition, _size);
                    if (h != null && h != w.othersLabel) w.onHostLongPress!(h);
                  },
            child: CustomPaint(size: _size, painter: painter),
          ),
        ),
      );
    });
  }
}

class _HostNode {
  _HostNode(this.label, {this.others = false});
  final String label;
  final bool others;
  final Map<FlowRoute, int> byRoute = {};
  int get total => byRoute.values.fold(0, (a, b) => a + b);
}

class _TopologyModel {
  _TopologyModel(this.hosts, this.routes, this.hidden);
  final List<_HostNode> hosts;
  final Map<FlowRoute, int> routes; // ordered by weight
  final Set<String> hidden; // hosts merged into "others"
  int get total => routes.values.fold(0, (a, b) => a + b);

  static _TopologyModel build(List<FlowInfo> flows, int maxHosts, String othersLabel) {
    final byHost = <String, _HostNode>{};
    for (final f in flows) {
      final n = byHost.putIfAbsent(f.host, () => _HostNode(f.host));
      n.byRoute[f.route] = (n.byRoute[f.route] ?? 0) + math.max(1, f.conns);
    }
    final sorted = byHost.values.toList()..sort((a, b) => b.total.compareTo(a.total));
    final hosts = <_HostNode>[];
    final hidden = <String>{};
    if (sorted.length > maxHosts) {
      // Reserve a few rows for every route so a small route (e.g. the campus
      // tunnel next to a busy external proxy) isn't swallowed by "others".
      final routeSet = {for (final h in sorted) ...h.byRoute.keys};
      final perRoute = routeSet.length > 1 ? math.min(3, maxHosts ~/ routeSet.length) : 0;
      final picked = <_HostNode>{};
      for (final r in routeSet) {
        final cand = sorted.where((h) => h.byRoute.containsKey(r)).toList()
          ..sort((a, b) => b.byRoute[r]!.compareTo(a.byRoute[r]!));
        picked.addAll(cand.take(perRoute));
      }
      for (final h in sorted) {
        if (picked.length >= maxHosts) break;
        picked.add(h);
      }
      hosts.addAll(sorted.where(picked.contains));
      final others = _HostNode(othersLabel, others: true);
      for (final h in sorted.where((h) => !picked.contains(h))) {
        hidden.add(h.label);
        h.byRoute.forEach((r, v) => others.byRoute[r] = (others.byRoute[r] ?? 0) + v);
      }
      hosts.add(others);
    } else {
      hosts.addAll(sorted);
    }
    final routes = <FlowRoute, int>{};
    for (final h in hosts) {
      h.byRoute.forEach((r, v) => routes[r] = (routes[r] ?? 0) + v);
    }
    final ordered = Map.fromEntries(routes.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
    return _TopologyModel(hosts, ordered, hidden);
  }
}

class _TopologyPainter extends CustomPainter {
  _TopologyPainter({
    required this.model,
    required this.deviceLabel,
    required this.routeLabel,
    required this.routeColors,
    required this.deviceColor,
    required this.hostColor,
    required this.othersColor,
    required this.textColor,
    required this.mutedColor,
    required this.labelStyle,
    required this.countStyle,
    required this.compact,
    this.anchor,
  });

  final _TopologyModel model;
  final String deviceLabel;
  final String Function(FlowRoute) routeLabel;
  final Map<FlowRoute, Color> routeColors;
  final Color deviceColor, hostColor, othersColor, textColor, mutedColor;
  final TextStyle labelStyle, countStyle;
  final bool compact;
  final (double, double, double)? anchor;

  static const barW = 5.0;
  static const vPad = 8.0;

  // Geometry shared by paint() and hit testing.
  late double _leftX, _hostX, _routeX;
  bool laidOut = false;
  final _hostRects = <(Rect, String)>[];
  final _routeRects = <(Rect, FlowRoute)>[];
  Rect? _othersRect;

  static (double, double, double) columnsFor(_TopologyModel model, String deviceLabel,
      String Function(FlowRoute) routeLabel, TextStyle labelStyle, Size size, bool compact) {
    final leftX = _measure(deviceLabel, labelStyle).width + 10;
    final routeLabelW = model.routes.keys.map((r) => _measure(routeLabel(r), labelStyle).width).fold(0.0, math.max);
    final routeX = size.width - routeLabelW - 12 - barW;
    final hostX = leftX + (routeX - leftX) * (compact ? 0.56 : 0.5);
    return (leftX, hostX, routeX);
  }

  void _layoutColumns(Size size) {
    final (l, h, r) = anchor ?? columnsFor(model, deviceLabel, routeLabel, labelStyle, size, compact);
    _leftX = l;
    _hostX = h;
    _routeX = r;
    laidOut = true;
  }

  static Size _measure(String s, TextStyle st) {
    final tp = TextPainter(text: TextSpan(text: s, style: st), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    return tp.size;
  }

  void _text(Canvas canvas, String s, TextStyle st, Offset at, {TextAlign align = TextAlign.left, double? maxW}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: st),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxW ?? double.infinity);
    final dx = switch (align) {
      TextAlign.right => at.dx - tp.width,
      TextAlign.center => at.dx - tp.width / 2,
      _ => at.dx,
    };
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  /// Stacks [weights] into [height] with [gap] between, returns (top, h) pairs.
  List<(double, double)> _stack(List<int> weights, double top, double height, double gap, {double minH = 3}) {
    final total = weights.fold(0, (a, b) => a + b);
    final avail = math.max(0.0, height - gap * (weights.length - 1));
    final out = <(double, double)>[];
    var y = top;
    for (final w in weights) {
      final h = total == 0 ? 0.0 : math.max(minH, avail * w / total);
      out.add((y, h));
      y += h + gap;
    }
    // Re-center if minimum heights overflowed.
    final used = y - gap - top;
    if (used > height && out.isNotEmpty) {
      final k = height / used;
      return [for (final (t, h) in out) (top + (t - top) * k, h * k)];
    }
    return out;
  }

  void _ribbon(Canvas canvas, double x0, double y0a, double y0b, double x1, double y1a, double y1b, Color color) {
    final mx = (x0 + x1) / 2;
    final path = Path()
      ..moveTo(x0, y0a)
      ..cubicTo(mx, y0a, mx, y1a, x1, y1a)
      ..lineTo(x1, y1b)
      ..cubicTo(mx, y1b, mx, y0b, x0, y0b)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.16));
  }

  RRect _bar(double x, double top, double h) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(x, top, barW, math.max(h, 2)), const Radius.circular(2));

  @override
  void paint(Canvas canvas, Size size) {
    _hostRects.clear();
    _routeRects.clear();
    _othersRect = null;
    if (model.hosts.isEmpty) return;
    _layoutColumns(size);
    final total = model.total;
    final h = size.height - vPad * 2;
    final rowGap = model.hosts.length > 1 ? math.min(10.0, h * 0.25 / (model.hosts.length - 1)) : 0.0;

    // Columns.
    final hostPos = _stack([for (final n in model.hosts) n.total], vPad, h, rowGap);
    final routes = model.routes.keys.toList();
    final routeGap = routes.length > 1 ? math.min(18.0, h * 0.3 / (routes.length - 1)) : 0.0;
    final routeH = h * 0.8;
    final routeTop = vPad + (h - routeH) / 2;
    final routePos = _stack([for (final r in routes) model.routes[r]!], routeTop, routeH, routeGap, minH: 6);
    final deviceH = h * 0.62;
    final deviceTop = vPad + (h - deviceH) / 2;

    // device -> host ribbons
    var dy = deviceTop;
    for (final (i, n) in model.hosts.indexed) {
      final share = deviceH * n.total / total;
      final (ht, hh) = hostPos[i];
      _ribbon(canvas, _leftX + barW, dy, dy + share, _hostX, ht, ht + hh, n.others ? othersColor : hostColor);
      dy += share;
    }

    // host -> route ribbons
    final routeCursor = {for (final (i, r) in routes.indexed) r: routePos[i].$1};
    final hostCursor = [for (final p in hostPos) p.$1];
    for (final r in routes) {
      final (_, rh) = routePos[routes.indexOf(r)];
      final rTotal = model.routes[r]!;
      for (final (i, n) in model.hosts.indexed) {
        final v = n.byRoute[r];
        if (v == null) continue;
        final (_, hh) = hostPos[i];
        final hs = hh * v / n.total;
        final rs = rh * v / rTotal;
        final y0 = hostCursor[i];
        final y1 = routeCursor[r]!;
        _ribbon(canvas, _hostX + barW, y0, y0 + hs, _routeX, y1, y1 + rs, routeColors[r]!);
        hostCursor[i] += hs;
        routeCursor[r] = y1 + rs;
      }
    }

    // Bars and labels.
    canvas.drawRRect(_bar(_leftX, deviceTop, deviceH), Paint()..color = deviceColor);
    _text(canvas, deviceLabel, labelStyle.copyWith(color: textColor), Offset(_leftX - 6, deviceTop + deviceH / 2),
        align: TextAlign.right);
    _text(canvas, '$total', countStyle, Offset(_leftX + barW + 6, deviceTop + deviceH / 2));

    // Host labels must not run into the device count.
    final countW = _measure('$total', countStyle).width;
    final hostLabelMax = math.max(24.0, _hostX - 6 - (_leftX + barW + 6 + countW + 6));
    for (final (i, n) in model.hosts.indexed) {
      final (t, hh) = hostPos[i];
      canvas.drawRRect(_bar(_hostX, t, hh), Paint()..color = n.others ? othersColor : hostColor);
      final cy = t + hh / 2;
      _text(canvas, n.label, labelStyle.copyWith(color: n.others ? mutedColor : textColor), Offset(_hostX - 6, cy),
          align: TextAlign.right, maxW: hostLabelMax);
      _text(canvas, '${n.total}', countStyle, Offset(_hostX + barW + 5, cy));
      final row = Rect.fromLTRB(_leftX + 10, t - rowGap / 2, _hostX + barW + 24, t + hh + rowGap / 2);
      _hostRects.add((row, n.label));
      if (n.others) _othersRect = row;
    }

    for (final (i, r) in routes.indexed) {
      final (t, rh) = routePos[i];
      canvas.drawRRect(_bar(_routeX, t, rh), Paint()..color = routeColors[r]!);
      final cy = t + rh / 2;
      _text(canvas, routeLabel(r), labelStyle.copyWith(color: textColor), Offset(_routeX + barW + 8, cy));
      _text(canvas, '${model.routes[r]}', countStyle, Offset(_routeX - 5, cy), align: TextAlign.right);
      _routeRects.add((Rect.fromLTRB(_routeX - 36, t - 10, size.width, t + math.max(rh, 2) + 10), r));
    }
  }

  bool inHostColumn(Offset p) => p.dx >= _leftX + 10 && p.dx <= _hostX + barW + 24;
  bool inRouteColumn(Offset p) => p.dx >= _routeX - 36;

  /// The expansion a pointer at [p] asks for in the overview, if any.
  _Focus? focusAt(Offset p) {
    for (final (r, route) in _routeRects) {
      if (r.contains(p)) return _routeRects.length > 1 ? _Focus.route(route) : null;
    }
    final o = _othersRect;
    if (o != null && o.contains(p)) return const _Focus.others();
    return null;
  }

  String? hostAt(Offset p, Size size) {
    for (final (r, label) in _hostRects) {
      if (r.contains(p)) return label;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant _TopologyPainter old) => true;
}
