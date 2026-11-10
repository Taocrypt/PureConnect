import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../l10n/strings.dart';
import '../kit/app_glyphs.dart';
import '../kit/dashboard_kit.dart';

/// One stop of the setup tour, in order. Each stop points at a real control
/// of the app (profiles page, profile editor, dashboard).
enum GuideStep { add, protocol, server, auth, credentials, save, connect }

/// Tabs the tour asks the home shell to show.
enum GuideTab { profiles, dashboard }

/// Target ids of each step. A step's spotlight covers the union of the
/// targets that are currently built (e.g. user name + password, or phone).
const guideTargets = <GuideStep, List<String>>{
  GuideStep.add: ['add'],
  GuideStep.protocol: ['protocol'],
  GuideStep.server: ['field:server', 'field:port'],
  GuideStep.auth: ['auth'],
  GuideStep.credentials: ['field:user', 'field:pass', 'field:phone', 'field:cas', 'field:oauth'],
  GuideStep.save: ['save'],
  GuideStep.connect: ['connect'],
};

/// One sign-in method the aTrust server offers (`-auth-info`).
class GuideAuthOption {
  const GuideAuthOption(this.authType, this.loginDomain, this.name);
  final String authType;
  final String loginDomain;
  final String name;

  /// Parses the core's auth_info list; unknown shapes give an empty list.
  static List<GuideAuthOption> parse(Object? info) {
    final out = <GuideAuthOption>[];
    if (info is! List) return out;
    for (final e in info) {
      if (e is! Map) continue;
      final type = '${e['authType'] ?? ''}';
      if (type.isEmpty) continue;
      out.add(GuideAuthOption(type, '${e['loginDomain'] ?? ''}', '${e['authName'] ?? ''}'));
    }
    return out;
  }
}

/// The guided coach-mark tour over the app's own pages.
///
/// Pages tag their controls with [key] and may [bind] what "Next" does on a
/// step (validate, save, open the editor). [GuideTourLayer], placed above the
/// navigator, dims the app and puts a magnifier lens on the current target.
class GuideTour extends ChangeNotifier {
  GuideTour();

  static final GuideTour instance = GuideTour();

  GuideStep? _step;
  GuideStep? get step => _step;
  bool get active => _step != null;

  GuideStep _first = GuideStep.add;

  /// Lets the home shell switch tabs for the tour.
  void Function(GuideTab tab)? showTab;

  /// Steps to leave out (set by the editor: aTrust-only steps for EC).
  bool Function(GuideStep step)? skipIf;

  /// A short status line under the tip (e.g. sign-in methods read).
  String? get note => _note;
  String? _note;

  /// Which credentials tip fits the chosen sign-in method: null (user name
  /// and password), 'sms' or 'browser'. Set by the editor.
  String? credentialsVariant;

  final Map<String, GlobalKey> _keys = {};
  final Map<GuideStep, VoidCallback> _actions = {};

  /// The key a page puts on its control [id] (see [guideTargets]).
  GlobalKey key(String id) => _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'guide:$id'));

  /// Keys of [id]s present in the tree right now.
  Iterable<GlobalKey> keysOf(GuideStep s) => [
    for (final id in guideTargets[s]!)
      if (_keys[id]?.currentContext != null) _keys[id]!,
  ];

  /// What "Next" does on [s]; the action advances the tour itself.
  void bind(GuideStep s, VoidCallback action) => _actions[s] = action;

  void unbind(Iterable<GuideStep> steps) {
    for (final s in steps) {
      _actions.remove(s);
    }
  }

  /// The steps shown as dots, in order.
  List<GuideStep> get steps => [
    for (final s in GuideStep.values)
      if (s.index >= _first.index && !(skipIf?.call(s) ?? false)) s,
  ];

  /// Starts on the profiles page, or right in the editor ([inEditor]) when
  /// the caller has already opened it.
  void start({bool inEditor = false}) {
    _first = inEditor ? GuideStep.protocol : GuideStep.add;
    _note = null;
    _step = _first;
    if (!inEditor) showTab?.call(GuideTab.profiles);
    notifyListeners();
  }

  /// "Next": runs the step's bound action, else moves on.
  void next() {
    final s = _step;
    if (s == null) return;
    final a = _actions[s];
    if (a != null) {
      a();
    } else {
      advance();
    }
  }

  /// Moves past the current step (from a page, after its action succeeded).
  void advance({GuideStep? from}) {
    final s = _step;
    if (s == null || (from != null && from != s)) return;
    GuideStep? n;
    for (final c in GuideStep.values.skip(s.index + 1)) {
      if (!(skipIf?.call(c) ?? false)) {
        n = c;
        break;
      }
    }
    if (n == null) {
      stop();
      return;
    }
    _step = n;
    _note = null;
    if (n == GuideStep.connect) showTab?.call(GuideTab.dashboard);
    notifyListeners();
  }

  /// A real control of [s] was used (e.g. the connect button).
  void targetUsed(GuideStep s) {
    if (_step == s) advance();
  }

  void setNote(String? text) {
    if (_note == text) return;
    _note = text;
    notifyListeners();
  }

  /// The editor closed: the tour cannot go on unless it reached the end.
  void editorClosed() {
    final s = _step;
    if (s != null && s.index >= GuideStep.protocol.index && s.index <= GuideStep.save.index) stop();
  }

  void stop() {
    if (_step == null) return;
    _step = null;
    _note = null;
    skipIf = null;
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _step = null;
    _note = null;
    skipIf = null;
    showTab = null;
    _actions.clear();
    _keys.clear();
  }
}

/// Puts [child] under the tour key [id] while [enabled].
class GuideTarget extends StatelessWidget {
  const GuideTarget({super.key, required this.id, required this.child, this.enabled = true});
  final String id;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => enabled ? KeyedSubtree(key: GuideTour.instance.key(id), child: child) : child;
}

/// The lens shape for a target: a circle around compact controls, a rounded
/// capsule around rows and fields.
RRect guideLensFor(Rect r) {
  final compact = r.longestSide <= 140 && r.width / r.height < 1.8 && r.height / r.width < 1.8;
  if (compact) {
    final d = r.longestSide + 18;
    return RRect.fromRectAndRadius(Rect.fromCenter(center: r.center, width: d, height: d), Radius.circular(d / 2));
  }
  final o = r.inflate(6);
  return RRect.fromRectAndRadius(o, Radius.circular(math.min(o.height / 2, 26)));
}

/// Dims the app, cuts a lens over the current step's control (which stays
/// usable), briefly magnifies it, and shows the tip bubble. Sits above the
/// navigator so it follows the tour across pages.
class GuideTourLayer extends StatefulWidget {
  const GuideTourLayer({super.key, this.tour});

  /// The tour to show; defaults to [GuideTour.instance].
  final GuideTour? tour;

  @override
  State<GuideTourLayer> createState() => _GuideTourLayerState();
}

class _GuideTourLayerState extends State<GuideTourLayer> with TickerProviderStateMixin {
  GuideTour get tour => widget.tour ?? GuideTour.instance;

  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _shown = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  GuideStep? _step;
  RRect? _target; // where the lens should be
  RRect? _lens; // where it is (smoothed)
  Duration _last = Duration.zero;
  bool _arrived = false;
  bool _scrolled = false;
  int _lostFrames = 0;

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    tour.addListener(_onTour);
    _shown.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && mounted) setState(() {});
    });
    if (tour.active) _onTour();
  }

  @override
  void dispose() {
    tour.removeListener(_onTour);
    _ticker.dispose();
    _shown.dispose();
    _arrive.dispose();
    _ripple.dispose();
    super.dispose();
  }

  void _onTour() {
    if (!mounted) return;
    final s = tour.step;
    if (s != _step) {
      _step = s;
      _arrived = false;
      _scrolled = false;
      _lostFrames = 0;
      _arrive.value = 0;
    }
    if (s != null) {
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
      _shown.duration = _reduced ? const Duration(milliseconds: 1) : const Duration(milliseconds: 320);
      _shown.forward();
      if (_reduced) {
        _ripple.stop();
      } else if (!_ripple.isAnimating) {
        _ripple.repeat();
      }
    } else {
      _shown.reverse().whenComplete(() {
        if (!tour.active) {
          _ticker.stop();
          _ripple.stop();
          _lens = null;
          _target = null;
        }
      });
    }
    setState(() {});
  }

  /// The union of the step's targets in this layer's coordinates.
  Rect? _measure(GuideStep s) {
    final me = context.findRenderObject();
    if (me is! RenderBox || !me.hasSize) return null;
    Rect? out;
    for (final k in tour.keysOf(s)) {
      final ro = k.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize || ro.size.isEmpty) continue;
      final r = MatrixUtils.transformRect(ro.getTransformTo(me), Offset.zero & ro.size);
      out = out == null ? r : out.expandToInclude(r);
    }
    return out;
  }

  void _scrollIntoView(GuideStep s) {
    final ctx = tour.keysOf(s).firstOrNull?.currentContext;
    if (ctx == null) return;
    _scrolled = true;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.35,
      duration: _reduced ? Duration.zero : const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    ).catchError((_) {});
  }

  void _tick(Duration now) {
    final s = _step;
    if (s == null || !mounted) return;
    final dt = _last == Duration.zero ? 1 / 60 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    final r = _measure(s);
    if (r != null && !_scrolled) _scrollIntoView(s);
    final view = Offset.zero & (context.size ?? Size.zero);
    if (r == null || !view.inflate(40).overlaps(r)) {
      // Target not built yet (page still opening) or gone: keep the last
      // lens briefly, then fold it away.
      if (++_lostFrames > 20 && _target != null) setState(() => _target = null);
      return;
    }
    _lostFrames = 0;
    final t = guideLensFor(r);
    final prev = _lens;
    RRect next;
    if (prev == null || _reduced) {
      next = t;
    } else {
      final k = 1 - math.exp(-dt * 11);
      next = RRect.lerp(prev, t, k)!;
    }
    final settled = (next.center - t.center).distance < 1.5 && (next.width - t.width).abs() < 1.5;
    if (settled && !_arrived) {
      _arrived = true;
      if (!_reduced) _arrive.forward(from: 0);
    }
    if (prev != next || _target != t) {
      setState(() {
        _lens = next;
        _target = t;
      });
    }
  }

  /// Arrival zoom: rises quickly, then settles back to 1:1 so taps and the
  /// text cursor line up with what is drawn.
  double _zoom(RRect lens) {
    final t = _arrive.value;
    if (t <= 0 || t >= 1 || _reduced) return 1;
    final f = t < 0.32
        ? Curves.easeOutCubic.transform(t / 0.32)
        : 1 - Curves.easeInOutCubic.transform((t - 0.32) / 0.68);
    final compact = lens.width - lens.height < 2;
    return 1 + (compact ? 0.16 : 0.05) * f;
  }

  @override
  Widget build(BuildContext context) {
    if (!tour.active && _shown.isDismissed) return const SizedBox.shrink();
    final dark = context.colorScheme.brightness == Brightness.dark;
    final colorScheme = context.colorScheme;
    final lens = _target == null ? null : _lens;
    return AnimatedBuilder(
      animation: Listenable.merge([_shown, _arrive, _ripple]),
      builder: (context, _) {
        final shown = Curves.easeOutCubic.transform(_shown.value);
        final zoom = lens == null ? 1.0 : _zoom(lens);
        return Stack(
          children: [
            if (lens != null && zoom > 1.001)
              Positioned.fromRect(
                rect: lens.outerRect,
                child: IgnorePointer(
                  child: RawMagnifier(
                    size: lens.outerRect.size,
                    magnificationScale: zoom,
                    decoration: MagnifierDecoration(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(lens.tlRadius)),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _LensPainter(
                    lens: lens,
                    shown: shown,
                    arrive: _reduced ? 1 : _arrive.value,
                    ripple: _reduced ? -1 : _ripple.value,
                    scrim: (dark ? const Color(0xFF000000) : const Color(0xFF0B1020)).withValues(
                      alpha: dark ? 0.64 : 0.5,
                    ),
                    ring: colorScheme.primary,
                    rim: dark ? const Color(0xFFFFFFFF) : const Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
            if (tour.active) Positioned.fill(child: _ScrimBlocker(hole: lens)),
            if (tour.active || !_shown.isDismissed)
              Positioned.fill(
                child: Opacity(
                  opacity: shown,
                  child: CustomSingleChildLayout(
                    delegate: _BubbleLayout(
                      lens: lens?.outerRect,
                      insets:
                          MediaQuery.paddingOf(context) +
                          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
                    ),
                    child: _Bubble(tour: tour, step: _step, reduced: _reduced, hasTarget: lens != null),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Swallows taps on the dimmed area; taps inside the lens reach the app.
class _ScrimBlocker extends LeafRenderObjectWidget {
  const _ScrimBlocker({required this.hole});
  final RRect? hole;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderScrimBlocker(hole);

  @override
  void updateRenderObject(BuildContext context, _RenderScrimBlocker renderObject) => renderObject.hole = hole;
}

class _RenderScrimBlocker extends RenderBox {
  _RenderScrimBlocker(this.hole);
  RRect? hole;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    if (hole?.contains(position) ?? false) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

class _LensPainter extends CustomPainter {
  _LensPainter({
    required this.lens,
    required this.shown,
    required this.arrive,
    required this.ripple,
    required this.scrim,
    required this.ring,
    required this.rim,
  });

  final RRect? lens;
  final double shown, arrive, ripple;
  final Color scrim, ring, rim;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final paint = Paint()..color = scrim.withValues(alpha: scrim.a * shown);
    final l = lens;
    if (l == null) {
      canvas.drawRect(full, paint);
      return;
    }
    // Lens opens from a point as the tour fades in.
    final g = Curves.easeOutBack.transform(shown.clamp(0, 1));
    final hole = _scale(l, 0.6 + 0.4 * g);
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(full)
        ..addRRect(hole),
      paint,
    );
    final a = shown;
    // Soft glow and the coloured rim.
    canvas.drawRRect(
      hole.inflate(2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = ring.withValues(alpha: 0.28 * a)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = ring.withValues(alpha: a),
    );
    canvas.drawRRect(
      hole.deflate(2.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rim.withValues(alpha: 0.55 * a),
    );
    // Glass sheen along the top-left of the rim.
    final circle = (hole.width - hole.height).abs() < 2;
    if (circle) {
      canvas.drawArc(
        hole.outerRect.deflate(6),
        math.pi * 1.08,
        math.pi * 0.36,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.5
          ..color = rim.withValues(alpha: 0.7 * a),
      );
    }
    // Ripple inviting a tap.
    if (ripple >= 0) {
      final e = Curves.easeOut.transform(ripple);
      canvas.drawRRect(
        hole.inflate(2 + 14 * e),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring.withValues(alpha: 0.45 * (1 - e) * a),
      );
    }
    _handle(canvas, size, hole, a * Curves.easeOut.transform(arrive.clamp(0, 1)));
  }

  /// The magnifier's handle, off whichever corner has room.
  void _handle(Canvas canvas, Size size, RRect hole, double a) {
    if (a <= 0.01) return;
    final rad = hole.tlRadius.x;
    const len = 26.0;
    for (final (sx, sy) in const [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)]) {
      final corner = Offset(sx > 0 ? hole.right - rad : hole.left + rad, sy > 0 ? hole.bottom - rad : hole.top + rad);
      final dir = Offset(sx, sy) / math.sqrt2;
      final start = corner + dir * (rad + 1.5);
      final end = start + dir * (len * a);
      if (!(Offset.zero & size).deflate(4).contains(start + dir * len)) continue;
      canvas.drawLine(
        start + dir * 2,
        end + dir * 2,
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 9
          ..color = const Color(0xFF000000).withValues(alpha: 0.18 * a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawLine(
        start,
        end,
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 8
          ..color = ring.withValues(alpha: a),
      );
      canvas.drawLine(
        start + dir * 3,
        start + dir * math.max(3, len * a - 6),
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2
          ..color = rim.withValues(alpha: 0.35 * a),
      );
      return;
    }
  }

  static RRect _scale(RRect r, double s) {
    final c = r.center;
    final w = r.width * s, h = r.height * s;
    return RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: w, height: h), Radius.circular(r.tlRadius.x * s));
  }

  @override
  bool shouldRepaint(_LensPainter old) =>
      old.lens != lens ||
      old.shown != shown ||
      old.arrive != arrive ||
      old.ripple != ripple ||
      old.scrim != scrim ||
      old.ring != ring;
}

/// Places the tip below the lens when it fits, else above, else centred;
/// keeps clear of system bars and the keyboard.
class _BubbleLayout extends SingleChildLayoutDelegate {
  _BubbleLayout({required this.lens, required this.insets});
  final Rect? lens;
  final EdgeInsets insets;

  static const _gap = 18.0;
  static const _margin = 16.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final w = math.min(340.0, constraints.maxWidth - 2 * _margin);
    return BoxConstraints(
      minWidth: w,
      maxWidth: w,
      maxHeight: math.max(0, constraints.maxHeight - insets.vertical - 2 * _margin),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final top = insets.top + _margin;
    final bottom = size.height - insets.bottom - _margin;
    final l = lens;
    if (l == null) {
      return Offset((size.width - child.width) / 2, math.max(top, (top + bottom - child.height) / 2));
    }
    final x = (l.center.dx - child.width / 2).clamp(_margin, math.max(_margin, size.width - child.width - _margin));
    double y;
    if (l.bottom + _gap + child.height <= bottom) {
      y = l.bottom + _gap;
    } else if (l.top - _gap - child.height >= top) {
      y = l.top - _gap - child.height;
    } else {
      // Not enough room either side (tall target or keyboard up): the side
      // with more room, overlapping the lens as little as possible.
      final below = bottom - l.bottom;
      final above = l.top - top;
      y = below >= above ? bottom - child.height : top;
    }
    return Offset(x.toDouble(), y.clamp(top, math.max(top, bottom - child.height)));
  }

  @override
  bool shouldRelayout(_BubbleLayout old) => old.lens != lens || old.insets != insets;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.tour, required this.step, required this.reduced, required this.hasTarget});
  final GuideTour tour;
  final GuideStep? step;
  final bool reduced;
  final bool hasTarget;

  @override
  Widget build(BuildContext context) {
    final s = step;
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);
    final steps = tour.steps;
    final last = s != null && steps.isNotEmpty && steps.last == s;
    final content = s == null
        ? const SizedBox.shrink()
        : Column(
            key: ValueKey(s),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                spacing: 10,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: ShapeDecoration(color: colorScheme.primaryContainer, shape: AppShape.circle),
                    alignment: Alignment.center,
                    child: GlyphIcon(AppGlyphs.search, size: 18, color: colorScheme.onPrimaryContainer),
                  ),
                  Expanded(
                    child: Text(
                      context.tr('tour_${s.name}_title'),
                      style: AppTextStyle.headline.of(context, emphasized: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _body(context, s),
                style: AppTextStyle.subheadline.of(context).copyWith(color: colorScheme.onSurfaceVariant),
              ),
              if (tour.note != null) ...[
                const SizedBox(height: 8),
                Text(tour.note!, style: DashboardText.label(context, color: colorScheme.primary)),
              ],
            ],
          );
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 12),
        decoration: ShapeDecoration(color: colors.card, shape: AppShape.all(24), shadows: DashboardShadows.e1(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Reduced motion: no size/cross-fade animation (a zero-length
            // AnimatedSize re-dirties itself during layout).
            if (reduced)
              content
            else
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (cur, prev) => Stack(alignment: Alignment.topCenter, children: [...prev, ?cur]),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(anim), child: child),
                  ),
                  child: content,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 2),
                for (final d in steps) ...[
                  AnimatedContainer(
                    duration: reduced ? Duration.zero : const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    width: d == s ? 18 : 6,
                    height: 6,
                    decoration: ShapeDecoration(
                      color: d == s
                          ? colorScheme.primary
                          : (s != null && d.index < s.index
                                ? colorScheme.primary.withValues(alpha: 0.45)
                                : colorScheme.outlineVariant),
                      shape: AppShape.full,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                const Spacer(),
                if (!last) TextButton(onPressed: tour.stop, child: Text(context.tr('tour_skip'))),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: s == null ? null : tour.next,
                  child: Text(context.tr(last ? 'tour_done' : (s == GuideStep.save ? 'save' : 'guide_next'))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _body(BuildContext context, GuideStep s) {
    final key = 'tour_${s.name}_body';
    final variant = tour.credentialsVariant;
    if (variant != null && s == GuideStep.credentials) return context.tr('${key}_$variant');
    return context.tr(key);
  }
}
