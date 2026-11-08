import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:zju_connect/core/protocol.dart';
import 'package:zju_connect/l10n/ui_localizations.dart';
import 'package:zju_connect/state/providers.dart';
import 'package:zju_connect/ui/kit/dashboard_kit.dart';
import 'package:zju_connect/ui/pages/dashboard_page.dart';

class _FakeCore extends CoreController {
  @override
  CoreStatus build() => const CoreStatus(state: CoreState.connected);
}

class _FakeTraffic extends TrafficNotifier {
  @override
  TrafficStats build() => const TrafficStats(tx: 1536000, rx: 48234567, txRate: 2048, rxRate: 734003);
}

void main() {
  testWidgets('status button opens traffic popup', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          coreProvider.overrideWith(_FakeCore.new),
          trafficProvider.overrideWith(_FakeTraffic.new),
        ],
        child: PrismApp(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: const [AppUiLocalizations.delegate, GlobalWidgetsLocalizations.delegate],
          builder: (context, child) {
            final size = MediaQuery.sizeOf(context);
            return ViewScope(size: size, isMobile: size.width < mobileBreakpoint, child: child!);
          },
          home: Builder(builder: (c) => Align(alignment: Alignment.topRight, child: Builder(builder: (b) => GestureDetector(
            onTap: () => showTrafficPopup(b),
            child: const SizedBox(width: 48, height: 48, child: ColoredBox(color: Color(0xFF888888))),
          )))),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byType(GestureDetector).first);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('46.0 MB'), findsOneWidget);
    expect(find.text('46.0 MB'), findsOneWidget);
    await tester.runAsync(() async {
      final ro = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 1);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File('/tmp/traffic.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
