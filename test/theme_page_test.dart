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
  CoreStatus build() => const CoreStatus(version: 'v9.9.9 (zju-connect v0.9.0-21-g1a2b3c4)');
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
    expect(find.text('反馈渠道'), findsOneWidget);
    expect(find.text('PureConnect用户交流群'), findsOneWidget);
    expect(find.text('github.com/Taocrypt/PureConnect'), findsOneWidget);
    expect(find.text('内核与开源组件'), findsOneWidget);
    expect(find.text('免责声明'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    expect(find.textContaining('Telegram'), findsNothing);
    await _save(tester, 'about');
  });

  test('core version label keeps only the core version', () {
    expect(coreVersionLabel('v1.0.3 (zju-connect v0.9.0-21-g1a2b3c4)'), 'v1.0.3');
    expect(coreVersionLabel('dev (zju-connect unknown)'), 'dev');
    expect(coreVersionLabel(' 1.0.4 '), '1.0.4');
    expect(coreVersionLabel(''), '');
  });

  for (final width in [1080.0, 990.0]) {
    testWidgets('about page: version details show whole values (${width ~/ 3}dp wide)', (tester) async {
      await _pump(tester, const AboutPage(), size: Size(width, 2340), dpr: 3);
      await tester.ensureVisible(find.text('版本信息'));
      await tester.pump();
      await tester.tap(find.text('版本信息'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      // No app row (the header shows the app version), the core row shows
      // the core version only.
      expect(find.text('应用'), findsNothing);
      expect(find.text('v9.9.9'), findsOneWidget);
      expect(find.textContaining('zju-connect v0.9.0'), findsNothing);
      for (final value in ['v9.9.9', 'Mythologyli/zju-connect', 'FlClash / prism_ui']) {
        final text = tester.widget<Text>(find.text(value));
        expect(text.overflow, isNot(TextOverflow.ellipsis), reason: value);
        expect(text.maxLines, isNull, reason: value);
        final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: find.text(value), matching: find.byType(RichText)));
        expect(paragraph.didExceedMaxLines, isFalse, reason: value);
      }
      await _save(tester, 'about_details_${width ~/ 3}');
    });
  }

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
