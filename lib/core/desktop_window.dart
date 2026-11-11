import 'dart:io';

import 'package:flutter/services.dart';

/// The runner's `pureconnect/window` channel (windows/runner/flutter_window.cpp,
/// macos/Runner/MainFlutterWindow.swift, linux/runner/my_application.cc).
///
/// Dart → native: setIcon, show, hide, isVisible, setPreventClose, quit;
/// macOS setDockIconVisible / launchArgs; Windows proxyGet / proxySet /
/// proxyGuard, notify, isElevated, runElevated, autostartGet / autostartSet,
/// setShortcutIcon (all in-process, no helper processes).
/// Native → Dart: close (window close button while preventClose is on),
/// minimized (window minimised),
/// quitRequested (macOS Cmd+Q / logout), activate (second launch, Dock click).
class DesktopWindow {
  static const channel = MethodChannel('pureconnect/window');

  static bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<T?> _call<T>(String method, [Object? args]) async {
    if (!isDesktop) return null;
    try {
      return await channel.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  static Future<void> show() => _call('show');
  static Future<void> hide() => _call('hide');
  static Future<bool> isVisible() async => await _call<bool>('isVisible') ?? true;
  static Future<void> setPreventClose(bool v) => _call('setPreventClose', v);
  static Future<void> quit() => _call('quit');
  /// Command-line arguments of this launch. Windows and Linux hand them to
  /// main(); macOS' runner does not, so they are asked for over the channel.
  static List<String> mainArgs = const [];
  static Future<List<String>> launchArgs() async {
    if (Platform.isMacOS) {
      final l = await _call<List<Object?>>('launchArgs');
      return l?.map((e) => '$e').toList() ?? const [];
    }
    return mainArgs;
  }

  static Future<void> setDockIconVisible(bool v) async {
    if (Platform.isMacOS) await _call('setDockIconVisible', v);
  }

  /// Windows: current WinINet proxy ({enable, server, bypass, autoConfigUrl}).
  static Future<Map<String, dynamic>?> proxyGet() async {
    if (!Platform.isWindows) return null;
    final m = await _call<Map<Object?, Object?>>('proxyGet');
    return m?.map((k, v) => MapEntry(k.toString(), v));
  }

  /// Windows: writes the WinINet proxy and notifies running apps.
  static Future<bool> proxySet(Map<String, dynamic> settings) async {
    if (!Platform.isWindows) return false;
    return await _call<bool>('proxySet', settings) ?? false;
  }

  /// Windows: a notification shown in-process by the runner (tray balloon,
  /// a toast on Windows 10/11). No helper process.
  static Future<bool> notify(String title, String body) async {
    if (!Platform.isWindows) return false;
    return await _call<bool>('notify', {'title': title, 'body': body}) ?? false;
  }

  /// Windows: whether the app itself runs elevated.
  static Future<bool> isElevated() async {
    if (!Platform.isWindows) return false;
    return await _call<bool>('isElevated') ?? false;
  }

  /// Windows: starts [file] elevated through the UAC prompt (ShellExecuteEx
  /// "runas", no window). Null when the runner could not be asked.
  static Future<({bool ok, bool cancelled, int error})?> runElevated(String file, String args, String dir) async {
    if (!Platform.isWindows) return null;
    final m = await _call<Map<Object?, Object?>>('runElevated', {'file': file, 'args': args, 'dir': dir});
    if (m == null) return null;
    return (ok: m['ok'] == true, cancelled: m['cancelled'] == true, error: (m['error'] as num?)?.toInt() ?? 0);
  }

  /// Windows: the HKCU Run value [name] (null: absent).
  static Future<String?> autostartGet(String name) async {
    if (!Platform.isWindows) return null;
    return _call<String>('autostartGet', name);
  }

  /// Windows: sets the HKCU Run value [name]; an empty [value] removes it.
  static Future<bool> autostartSet(String name, String value) async {
    if (!Platform.isWindows) return false;
    return await _call<bool>('autostartSet', {'name': name, 'value': value}) ?? false;
  }

  /// Windows: settings the runner restores by itself at logoff/shutdown
  /// (null: nothing to restore).
  static Future<void> proxyGuard(Map<String, dynamic>? settings) async {
    if (Platform.isWindows) await _call('proxyGuard', settings);
  }
}
