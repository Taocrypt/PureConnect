import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/app.dart' show appColorScheme;
import 'package:zju_connect/core/desktop_window.dart';
import 'package:zju_connect/l10n/strings.dart';
import 'package:zju_connect/models/settings.dart';
import 'package:zju_connect/state/providers.dart' show connectionSettingsKey;
import 'package:zju_connect/ui/home_shell.dart' show TabStack;
import 'package:zju_connect/ui/pages/disclaimer_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('theme settings', () {
    test('defaults match FlClash', () {
      final s = AppSettings.fromJson(const {});
      expect(s.primaryColors, defaultPrimaryColors);
      expect(s.colorStyle, 'vivid');
      expect(s.pureBlack, isFalse);
      expect(s.sidebarBlur, isFalse);
      expect(s.liquidGlass, 'none');
      expect(s.floatingNavBar, isTrue);
      expect(s.tabAnimation, 'slide');
      expect(s.customTextScale, isFalse);
      expect(s.textScale, 1.0);
      expect(s.fontFamily, '');
    });

    test('round trip keeps every theme field', () {
      final s = AppSettings()
        ..primaryColors = [0xFF123456, 0xFF007AFF]
        ..seedColor = 0xFF123456
        ..colorStyle = 'monochrome'
        ..pureBlack = true
        ..sidebarBlur = true
        ..liquidGlass = 'ultra'
        ..floatingNavBar = false
        ..tabAnimation = 'fade'
        ..customTextScale = true
        ..textScale = 1.25
        ..fontFamily = 'Noto Sans';
      final r = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(r.primaryColors, [0xFF123456, 0xFF007AFF]);
      expect(r.seedColor, 0xFF123456);
      expect(r.colorStyle, 'monochrome');
      expect(r.pureBlack, isTrue);
      expect(r.sidebarBlur, isTrue);
      expect(r.liquidGlass, 'ultra');
      expect(r.floatingNavBar, isFalse);
      expect(r.tabAnimation, 'fade');
      expect(r.customTextScale, isTrue);
      expect(r.textScale, 1.25);
      expect(r.fontFamily, 'Noto Sans');
    });

    test('settings from before 1.0.3 keep their colour among the swatches', () {
      final r = AppSettings.fromJson(const {'seedColor': 0xFF5AC8FA});
      expect(r.primaryColors.first, defaultPrimaryColor);
      expect(r.primaryColors.last, 0xFF5AC8FA);
      final preset = AppSettings.fromJson(const {'seedColor': 0xFF34C759});
      expect(preset.primaryColors, defaultPrimaryColors);
    });

    test('bad values fall back', () {
      final r = AppSettings.fromJson(const {
        'colorStyle': 'neon',
        'liquidGlass': true,
        'tabAnimation': 'spin',
        'textScale': 9,
        'primaryColors': [1, 1, 'x', 2],
      });
      expect(r.colorStyle, 'vivid');
      expect(r.liquidGlass, 'none');
      expect(r.tabAnimation, 'slide');
      expect(r.textScale, maxTextScale);
      expect(r.primaryColors, [1, 2]);
    });

    test('theme changes never ask to reconnect', () {
      final a = AppSettings();
      final b = AppSettings()
        ..pureBlack = true
        ..colorStyle = 'soft'
        ..fontFamily = 'X'
        ..textScale = 1.2
        ..disclaimerAccepted = 1
        ..primaryColors = [1];
      expect(connectionSettingsKey(a), connectionSettingsKey(b));
    });

    test('pure black only darkens the dark scheme', () {
      const seed = Color(0xFF007AFF);
      final dark = appColorScheme(seed, Brightness.dark, pureBlack: true);
      expect(dark.surface, const Color(0xFF000000));
      final light = appColorScheme(seed, Brightness.light, pureBlack: true);
      expect(light.surface, appColorScheme(seed, Brightness.light).surface);
    });
  });

  group('disclaimer', () {
    test('shown until the current version is accepted, also after updating', () {
      // Settings written by 1.0.2 have no disclaimer flag at all.
      expect(needsDisclaimer(AppSettings.fromJson(const {'seedColor': 1}).disclaimerAccepted), isTrue);
      expect(needsDisclaimer(0), isTrue);
      expect(needsDisclaimer(disclaimerVersion), isFalse);
      expect(needsDisclaimer(disclaimerVersion - 1), isTrue);
      final s = AppSettings()..disclaimerAccepted = disclaimerVersion;
      final r = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(needsDisclaimer(r.disclaimerAccepted), isFalse);
    });

    test('agree only with the exact phrase', () {
      final phrase = S('zh').t('disclaimer_phrase');
      expect(phrase, '我已阅读并同意以上声明');
      expect(disclaimerPhraseMatches(phrase, phrase), isTrue);
      expect(disclaimerPhraseMatches('  $phrase ', phrase), isTrue);
      expect(disclaimerPhraseMatches('我已阅读', phrase), isFalse);
      expect(disclaimerPhraseMatches('$phrase。', phrase), isFalse);
      expect(disclaimerPhraseMatches('', phrase), isFalse);
    });

    test('every term has text in both languages and names Sangfor', () {
      for (final lang in ['zh', 'en']) {
        final s = S(lang);
        for (var i = 1; i <= disclaimerTermCount; i++) {
          expect(s.t('disclaimer_t${i}_title'), isNot('disclaimer_t${i}_title'));
          expect(s.t('disclaimer_t${i}_body'), isNot('disclaimer_t${i}_body'));
        }
      }
      expect(S('zh').t('disclaimer_t2_body'), contains('深信服科技股份有限公司'));
      expect(S('zh').t('disclaimer_t1_body'), contains('AGPL-3.0'));
    });
  });

  test('custom frame: Windows, Linux, macOS 11+', () {
    expect(DesktopWindow.customFrameFor('windows', '10.0.22631'), isTrue);
    expect(DesktopWindow.customFrameFor('linux', 'Linux 6.8'), isTrue);
    expect(DesktopWindow.customFrameFor('macos', 'Version 14.5 (Build 23F79)'), isTrue);
    expect(DesktopWindow.customFrameFor('macos', 'Version 10.15.7 (Build 19H2)'), isFalse);
    expect(DesktopWindow.customFrameFor('android', '14'), isFalse);
  });

  test('licence file is the unmodified AGPL-3.0', () {
    final text = File('LICENSE').readAsStringSync();
    expect(text, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
    expect(text, contains('Version 3, 19 November 2007'));
    expect(text.length, greaterThan(30000));
  });

  test('no Telegram anywhere in the strings', () {
    final src = File('lib/l10n/strings.dart').readAsStringSync().toLowerCase();
    expect(src.contains('telegram'), isFalse);
    expect(src.contains('t.me/'), isFalse);
  });

  testWidgets('tab stack keeps pages alive and animates on the phone', (tester) async {
    Widget stack(int i, {bool fade = false}) => Directionality(
          textDirection: TextDirection.ltr,
          child: TabStack(
            index: i,
            fade: fade,
            children: [for (var p = 0; p < 3; p++) _Counter(key: ValueKey(p), label: 'p$p')],
          ),
        );
    await tester.pumpWidget(stack(0));
    await tester.tap(find.text('p0:0'));
    await tester.pump();
    expect(find.text('p0:1'), findsOneWidget);
    await tester.pumpWidget(stack(2));
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-slide both pages are on screen.
    expect(find.text('p0:1'), findsOneWidget);
    expect(find.text('p2:0'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('p0:1', skipOffstage: true), findsNothing);
    await tester.pumpWidget(stack(0, fade: true));
    await tester.pumpAndSettle();
    // State survived the round trip.
    expect(find.text('p0:1'), findsOneWidget);
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key, required this.label});
  final String label;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => setState(() => n++),
        child: Center(child: Text('${widget.label}:$n')),
      );
}
