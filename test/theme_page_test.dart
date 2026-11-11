import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zju_connect/l10n/ui_localizations.dart';
import 'package:zju_connect/state/providers.dart';
import 'package:zju_connect/ui/kit/common.dart';
import 'package:zju_connect/ui/kit/dashboard_kit.dart';
import 'package:zju_connect/ui/pages/about_page.dart';
import 'package:zju_connect/ui/pages/disclaimer_page.dart';
import 'package:zju_connect/ui/pages/theme_page.dart';

class _IdleCore extends CoreController {
  @override
  CoreStatus build() => const CoreStatus(version: 'v-test');
}

Future<void> _pump(WidgetTester tester, Widget home, {Size size = const Size(1080, 2340), double dpr = 2.75}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(
    key: _shot,
    child: ProviderScope(
      overrides: [coreProvider.overrideWith(_IdleCore.new), prefsProvider.overrideWithValue(prefs)],
      child: PrismApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [AppUiLocalizations.delegate, GlobalWidgetsLocalizations.delegate],
        builder: (context, child) {
          final s = MediaQuery.sizeOf(context);
          return ViewScope(size: s, isMobile: s.width < mobileBreakpoint, child: child!);
        },
        home: home,
      ),
    ),
  ));
  // The tab-animation previews loop forever: pump, never settle.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final _shot = GlobalKey();

Future<void> _save(WidgetTester tester, String name) => tester.runAsync(() async {
      final ro = _shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 1);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File('/tmp/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });

void main() {
  testWidgets('theme page renders every section (phone)', (tester) async {
    await _pump(tester, const AppPage(title: '主题', body: ThemePage()));
    expect(tester.takeException(), isNull);
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('纯黑模式'), findsOneWidget);
    expect(find.text('主题色'), findsWidgets);
    await _save(tester, 'theme_top');
    await tester.scrollUntilVisible(find.text('文本缩放'), 400, scrollable: find.byType(Scrollable).first);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('选项卡动画'), findsOneWidget);
    expect(find.text('字体'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _save(tester, 'theme_bottom');
  });

  testWidgets('theme page renders on a wide window', (tester) async {
    await _pump(tester, const AppPage(title: '主题', body: ThemePage()), size: const Size(1400, 1000), dpr: 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('about page: header, QQ group, disclaimer and licences', (tester) async {
    await _pump(tester, const AboutPage());
    expect(tester.takeException(), isNull);
    expect(find.text('PureConnect'), findsOneWidget);
    expect(find.text('AGPL-3.0'), findsOneWidget);
    expect(find.text('QQ 用户反馈群'), findsOneWidget);
    expect(find.text('PureConnect用户反馈群'), findsOneWidget);
    expect(find.text('免责声明'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    expect(find.textContaining('Telegram'), findsNothing);
    await _save(tester, 'about');
  });

  testWidgets('disclaimer: 同意 only with the phrase, 一键填入 fills it', (tester) async {
    bool? result;
    await _pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: GestureDetector(
            onTap: () async => result = await requestDisclaimerConsent(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('免责声明'), findsOneWidget);
    // Agree is off until the phrase is in the field.
    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.scrollUntilVisible(find.text('一键填入'), 400, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await _save(tester, 'disclaimer');
    await tester.tap(find.text('一键填入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
