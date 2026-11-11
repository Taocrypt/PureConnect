import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import 'core/desktop_window.dart';
import 'l10n/ui_localizations.dart';
import 'models/settings.dart' as m;
import 'state/providers.dart';
import 'ui/home_shell.dart';
import 'ui/window_frame.dart';
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

ColorStyle colorStyleOf(String name) =>
    ColorStyle.values.firstWhere((e) => e.name == name, orElse: () => ColorStyle.vivid);

final _schemes = <(Color, Brightness, ColorStyle, bool), ColorScheme>{};

/// The app's colour scheme as FlClash builds it: the seed through prism_ui's
/// [seededColorScheme] in the chosen style, then pure black when asked
/// (dark only). Cached, since the theme page draws many previews.
ColorScheme appColorScheme(Color seed, Brightness brightness, {String style = 'vivid', bool pureBlack = false}) {
  final key = (seed, brightness, colorStyleOf(style), pureBlack);
  final hit = _schemes.remove(key);
  final scheme = hit ??
      seededColorScheme(seedColor: seed, brightness: brightness, style: key.$3).toPureBlack(pureBlack);
  _schemes[key] = scheme;
  if (_schemes.length > 64) _schemes.remove(_schemes.keys.first);
  return scheme;
}

/// The seed the settings pick: the system accent while following it (when
/// the platform has one), else the chosen primary colour.
Color appSeed(m.AppSettings s, Color? accent) =>
    s.useDynamicColor && accent != null ? accent : Color(s.seedColor);

final _themes = <Brightness, (Object, ThemeData)>{};

ThemeData _theme(Color seed, Brightness brightness, m.AppSettings s) {
  final font = s.fontFamily.isEmpty ? null : s.fontFamily;
  final scheme = appColorScheme(seed, brightness, style: s.colorStyle, pureBlack: s.pureBlack);
  final inputs = (scheme, font);
  final cached = _themes[brightness];
  // A rebuilt ThemeData never equals the last one, and the theme cross-fade
  // runs on that; reuse it while nothing it is built from changed.
  if (cached != null && cached.$1 == inputs) return cached.$2;
  final theme = ThemeData(
    colorScheme: scheme,
    fontFamily: font,
    fontFamilyFallback: _cjkFallback,
    elevatedColorScheme: brightness == Brightness.dark ? scheme.elevated : null,
  );
  _themes[brightness] = (inputs, theme);
  return theme;
}

class ZjuConnectApp extends ConsumerWidget {
  const ZjuConnectApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final accent = ref.watch(systemAccentProvider).value;
    final seed = appSeed(s, accent);
    return PrismApp(
      title: 'PureConnect',
      debugShowCheckedModeBanner: false,
      theme: _theme(seed, Brightness.light, s),
      darkTheme: _theme(seed, Brightness.dark, s),
      textScale: s.customTextScale ? s.textScale : null,
      minTextScale: m.minTextScale,
      maxTextScale: m.maxTextScale,
      liquidGlass: switch (s.liquidGlass) {
        'standard' => LiquidGlassQuality.standard,
        'ultra' => LiquidGlassQuality.ultra,
        _ => null,
      },
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
        // Only for Flutter's licence page (Material), opened from 关于.
        GlobalMaterialLocalizations.delegate,
      ],
      builder: (context, child) {
        final size = MediaQuery.sizeOf(context);
        final mobile = size.width < mobileBreakpoint;
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
            isMobile: mobile,
            windowControls: windowControlsOverPage(isMobileView: mobile),
            // The window caption (desktop) sits above everything; the setup
            // tour above the navigator so it follows across pages, with its
            // own overlay hosting the bubble's buttons.
            child: WindowFrame(
              child: Stack(fit: StackFit.expand, children: [
                child!,
                Positioned.fill(child: Overlay.wrap(child: const GuideTourLayer())),
              ]),
            ),
          ),
        );
      },
      home: const HomeShell(),
    );
  }
}

/// System accent colour used as the seed while following the system: the
/// Android 12+ wallpaper colour, the Windows accent (DWM colorization) or the
/// macOS accent colour. Linux has none (null).
final systemAccentProvider = FutureProvider<Color?>((ref) async {
  try {
    final int? v;
    if (Platform.isAndroid) {
      v = await const MethodChannel('zju_connect/core').invokeMethod<int>('systemAccent');
    } else if (Platform.isWindows || Platform.isMacOS) {
      v = await DesktopWindow.channel.invokeMethod<int>('systemAccent');
    } else {
      v = null;
    }
    return v == null ? null : Color(v | 0xFF000000);
  } catch (_) {
    return null;
  }
});
