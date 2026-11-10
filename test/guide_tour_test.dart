import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:zju_connect/l10n/ui_localizations.dart';
import 'package:zju_connect/ui/kit/dashboard_kit.dart';
import 'package:zju_connect/ui/tour/guide_tour.dart';

/// A page with the profiles "+" button tagged for the tour, and the tour
/// layer above the navigator as in the app.
Widget _app({bool reduced = false}) => PrismApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [AppUiLocalizations.delegate, GlobalWidgetsLocalizations.delegate],
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        final size = mq.size;
        return MediaQuery(
          data: mq.copyWith(disableAnimations: reduced),
          child: ViewScope(
            size: size,
            isMobile: size.width < mobileBreakpoint,
            child: Stack(fit: StackFit.expand, children: [
              child!,
              Positioned.fill(child: Overlay.wrap(child: const GuideTourLayer())),
            ]),
          ),
        );
      },
      home: const Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: EdgeInsets.all(24),
          child: GuideTarget(id: 'add', child: SizedBox(width: 48, height: 48, child: ColoredBox(color: Color(0xFF888888)))),
        ),
      ),
    );

Future<void> _frames(WidgetTester tester, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final tour = GuideTour.instance;
  tearDown(tour.reset);

  group('GuideTour engine', () {
    test('start, next and skip-if walk the steps', () {
      final t = GuideTour();
      final tabs = <GuideTab>[];
      t.showTab = tabs.add;
      t.start();
      expect(t.step, GuideStep.add);
      expect(tabs, [GuideTab.profiles]);
      t.skipIf = (s) => s == GuideStep.auth;
      expect(t.steps, isNot(contains(GuideStep.auth)));
      t.next(); // add -> protocol
      t.next(); // protocol -> server
      t.next(); // server -> credentials (auth skipped)
      expect(t.step, GuideStep.credentials);
      t.next();
      t.next(); // save -> connect switches to the dashboard
      expect(t.step, GuideStep.connect);
      expect(tabs.last, GuideTab.dashboard);
      t.targetUsed(GuideStep.connect);
      expect(t.active, isFalse);
    });

    test('bound action replaces plain advance; editor close stops mid-editor', () {
      final t = GuideTour();
      t.start(inEditor: true);
      expect(t.step, GuideStep.protocol);
      var ran = 0;
      t.bind(GuideStep.protocol, () => ran++);
      t.next();
      expect(ran, 1);
      expect(t.step, GuideStep.protocol);
      t.advance(from: GuideStep.server); // stale step: ignored
      expect(t.step, GuideStep.protocol);
      t.advance(from: GuideStep.protocol);
      expect(t.step, GuideStep.server);
      t.editorClosed();
      expect(t.active, isFalse);
    });
  });

  group('GuideTourLayer', () {
    testWidgets('shows the bubble over a target; 下一步 advances, 跳过 stops', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app());
      expect(find.text('新建配置'), findsNothing);

      tour.start();
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('新建配置'), findsOneWidget);
      expect(tour.keysOf(GuideStep.add), isNotEmpty);

      await tester.tap(find.text('下一步'));
      await _frames(tester);
      expect(tour.step, GuideStep.protocol);
      expect(find.text('选择协议'), findsOneWidget);

      await tester.tap(find.text('跳过'));
      await _frames(tester);
      expect(tour.active, isFalse);
      expect(find.text('选择协议'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('works with animations disabled', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(reduced: true));
      tour.start();
      await _frames(tester, 6);
      expect(find.text('新建配置'), findsOneWidget);
      await tester.tap(find.text('下一步'));
      await _frames(tester, 6);
      expect(find.text('选择协议'), findsOneWidget);
      tour.stop();
      await _frames(tester, 6);
      expect(find.text('选择协议'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
