import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/app_icon.dart';
import 'core/desktop_window.dart';
import 'core/system_proxy.dart';
import 'state/providers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  DesktopWindow.mainArgs = args;
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final prefs = await SharedPreferences.getInstance();
  final dataDir = await resolveDataDir();
  _installErrorReporting(dataDir);
  if (SystemProxy.supported) {
    // A previous run died with the system proxy on (crash, kill, power
    // loss): put the user's own settings back before anything else.
    try {
      await SystemProxy.recoverStale(dataDir);
    } catch (_) {}
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    // Window/taskbar/Dock icon chosen in settings. Linux windows have no icon
    // by default, so a1 is applied there too.
    try {
      final raw = prefs.getString('settings.v1');
      final id = raw == null ? null : (jsonDecode(raw) as Map<String, dynamic>)['appIcon'] as String?;
      final icon = id ?? defaultAppIcon;
      if (Platform.isLinux || icon != defaultAppIcon) {
        // After the first frame: the native window channel exists by then.
        WidgetsBinding.instance.addPostFrameCallback((_) => applyAppIcon(icon));
      }
    } catch (_) {}
  }
  runApp(ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      dataDirProvider.overrideWithValue(dataDir),
    ],
    child: const ZjuConnectApp(),
  ));
}

/// Release builds render a widget exception as a plain grey box, which looks
/// like a stuck full-screen overlay. Show the error instead and keep a log
/// (`crash.log` in the data dir, last ~64 KB) so it can be reported.
void _installErrorReporting(String dataDir) {
  final file = File('$dataDir${Platform.pathSeparator}crash.log');
  void record(Object error, StackTrace? stack) {
    try {
      if (file.existsSync() && file.lengthSync() > 64 * 1024) {
        final keep = file.readAsStringSync();
        file.writeAsStringSync(keep.substring(keep.length - 32 * 1024));
      }
      // The top frames say where it broke; the rest is framework recursion.
      final top = (stack?.toString() ?? '').split('\n').take(25).join('\n');
      file.writeAsStringSync('--- ${DateTime.now().toIso8601String()}\n$error\n$top\n', mode: FileMode.append);
    } catch (_) {}
  }

  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    record(details.exception, details.stack);
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    record(error, stack);
    return true;
  };
  ErrorWidget.builder = (details) => Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xFFFFF4F4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'PureConnect UI error (saved to crash.log):\n${details.exceptionAsString()}',
              style: const TextStyle(color: Color(0xFF9A1C1C), fontSize: 13),
            ),
          ),
        ),
      );
}
