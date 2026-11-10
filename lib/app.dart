import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import 'l10n/ui_localizations.dart';
import 'models/settings.dart' as m;
import 'state/providers.dart';
import 'ui/home_shell.dart';
import 'ui/tour/guide_tour.dart';
import 'ui/kit/dashboard_kit.dart';

/// FlClash's default primary (iOS blue) and colour style.
const defaultSeed = 0xFF007AFF;

const _cjkFallback = [
  'PingFang SC',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'WenQuanYi Micro Hei',
];

ThemeData _theme(Color seed, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness, style: ColorStyle.vivid);
  return ThemeData(
    colorScheme: scheme,
    fontFamilyFallback: _cjkFallback,
    elevatedColorScheme: brightness == Brightness.dark ? scheme.elevated : null,
  );
}

class ZjuConnectApp extends ConsumerWidget {
  const ZjuConnectApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final accent = ref.watch(systemAccentProvider).value;
    final seed = s.useDynamicColor && accent != null ? accent : Color(s.seedColor);
    return PrismApp(
      title: 'PureConnect',
      debugShowCheckedModeBanner: false,
      theme: _theme(seed, Brightness.light),
      darkTheme: _theme(seed, Brightness.dark),
      themeMode: switch (s.themeMode) {
        m.AppThemeMode.light => ThemeMode.light,
        m.AppThemeMode.dark => ThemeMode.dark,
        m.AppThemeMode.system => ThemeMode.system,
      },
      locale: s.locale.isEmpty ? null : Locale(s.locale),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        AppUiLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      builder: (context, child) {
        final size = MediaQuery.sizeOf(context);
        final dark = context.colorScheme.brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: const Color(0x00000000),
            systemNavigationBarColor: const Color(0x00000000),
            systemNavigationBarDividerColor: const Color(0x00000000),
            systemStatusBarContrastEnforced: false,
            systemNavigationBarContrastEnforced: false,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            statusBarBrightness: dark ? Brightness.dark : Brightness.light,
            systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          ),
          child: ViewScope(
            size: size,
            isMobile: size.width < mobileBreakpoint,
            // The setup tour sits above the navigator so it follows across
            // pages; its own overlay hosts the bubble's buttons.
            child: Stack(fit: StackFit.expand, children: [
              child!,
              Positioned.fill(child: Overlay.wrap(child: const GuideTourLayer())),
            ]),
          ),
        );
      },
      home: const HomeShell(),
    );
  }
}

/// System accent colour (Android 12+ Material You wallpaper colour) used as
/// the seed when "dynamic color" is on. Desktop falls back to the chosen seed.
final systemAccentProvider = FutureProvider<Color?>((ref) async {
  if (!Platform.isAndroid) return null;
  try {
    final v = await const MethodChannel('zju_connect/core').invokeMethod<int>('systemAccent');
    return v == null ? null : Color(v);
  } catch (_) {
    return null;
  }
});
