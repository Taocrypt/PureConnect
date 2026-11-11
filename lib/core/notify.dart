import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_window.dart';

/// Best-effort system notifications (unexpected disconnect, reconnecting,
/// window hidden to the tray). Never throws; a missing notifier just means
/// no notification.
///
/// Android: a notification on its own "Alerts" channel (MainActivity).
/// Windows: a tray balloon from the runner, shown as a toast by Windows 10/11
/// (in-process; no PowerShell).
/// macOS: `osascript … display notification`.
/// Linux: `notify-send` (libnotify), present on most desktops.
class SystemNotify {
  static const _android = MethodChannel('zju_connect/core');

  static Future<void> show(String title, String body) async {
    try {
      if (Platform.isAndroid) {
        await _android.invokeMethod('notify', {'title': title, 'body': body});
      } else if (Platform.isMacOS) {
        await Process.run('osascript', [
          '-e', 'on run argv',
          '-e', 'display notification (item 2 of argv) with title (item 1 of argv)',
          '-e', 'end run',
          title,
          body,
        ]);
      } else if (Platform.isLinux) {
        await Process.run('notify-send', ['-a', 'PureConnect', title, body]);
      } else if (Platform.isWindows) {
        await DesktopWindow.notify(title, body);
      }
    } catch (_) {}
  }
}
