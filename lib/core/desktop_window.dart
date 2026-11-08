import 'dart:io';

import 'package:flutter/services.dart';

/// The runner's `pureconnect/window` channel (windows/runner/flutter_window.cpp,
/// macos/Runner/MainFlutterWindow.swift, linux/runner/my_application.cc).
///
/// Dart → native: setIcon, show, hide, isVisible, setPreventClose, quit;
/// macOS setDockIconVisible; Windows proxyGet / proxySet / proxyGuard.
/// Native → Dart: close (window close button while preventClose is on),
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

  /// Windows: settings the runner restores by itself at logoff/shutdown
  /// (null: nothing to restore).
  static Future<void> proxyGuard(Map<String, dynamic>? settings) async {
    if (Platform.isWindows) await _call('proxyGuard', settings);
  }
}
