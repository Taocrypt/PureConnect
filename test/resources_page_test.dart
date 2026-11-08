import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zju_connect/core/protocol.dart';
import 'package:zju_connect/l10n/ui_localizations.dart';
import 'package:zju_connect/state/providers.dart';
import 'package:zju_connect/ui/kit/dashboard_kit.dart';
import 'package:zju_connect/ui/pages/resources_page.dart';

class _FakeCore extends CoreController {
  _FakeCore(this.s);
  final SessionInfo s;
  @override
  CoreStatus build() => CoreStatus(state: CoreState.connected, session: s);
}

class _FakeProbes extends ProbeNotifier {
  @override
  Map<String, ProbeState> build() => const {
        'portal.example.edu.cn#443': ProbeState(ProbeStatus.ok, ms: 42),
        'mail.example.edu.cn#443': ProbeState(ProbeStatus.slow, ms: 612),
        'lib.example.edu.cn#80': ProbeState(ProbeStatus.fail, error: 'timeout'),
      };
}

void main() {
  testWidgets('resources page renders portal list', (tester) async {
    final f = File('/tmp/web.json');
    final web = f.existsSync()
        ? jsonDecode(f.readAsStringSync())
        : [
            {'name': '信息门户', 'group': 'Default group', 'url': 'https://portal.example.edu.cn', 'host': 'portal.example.edu.cn'},
            {'name': '邮箱', 'group': 'Default group', 'url': 'https://mail.example.edu.cn', 'host': 'mail.example.edu.cn'},
            {'name': '图书馆', 'group': 'Default group', 'url': 'http://lib.example.edu.cn', 'host': 'lib.example.edu.cn'},
            {'name': 'OA', 'group': 'Default group', 'url': 'http://10.1.2.3:8080', 'host': '10.1.2.3'}
          ];
    final session = SessionInfo.fromJson({
      'routes': ['10.0.0.0/8', '203.0.113.0/24'],
      'domain_resources': ['portal.example.edu.cn'],
      'ip_resources': [
        {'ip_min': '10.0.0.1', 'ip_max': '10.0.0.9', 'port_min': 1, 'port_max': 65535, 'protocol': 'tcp'}
      ],
      'web_resources': web,
      'raw_resources': '<Resource/>',
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    final shot = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: shot, child: ProviderScope(
      overrides: [coreProvider.overrideWith(() => _FakeCore(session)), prefsProvider.overrideWithValue(prefs), probeProvider.overrideWith(_FakeProbes.new)],
      child: PrismApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [AppUiLocalizations.delegate, GlobalWidgetsLocalizations.delegate],
        builder: (context, child) {
          final size = MediaQuery.sizeOf(context);
          return ViewScope(size: size, isMobile: size.width < mobileBreakpoint, child: child!);
        },
        home: const ResourcesPage(),
      ),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('信息门户'), findsOneWidget);
    await tester.runAsync(() async {
      final ro = shot.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 1);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File('/tmp/res.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
