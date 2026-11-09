import 'dart:io';

import 'package:flutter/services.dart';

/// Best-effort system notifications (unexpected disconnect, reconnecting,
/// window hidden to the tray). Never throws; a missing notifier just means
/// no notification.
///
/// Android: a notification on its own "Alerts" channel (MainActivity).
/// Windows: a toast through PowerShell's WinRT bridge (no extra DLLs).
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
        // Text goes through the environment so nothing needs escaping.
        await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', windowsToastScript],
          environment: {'PC_NOTIFY_TITLE': title, 'PC_NOTIFY_BODY': body},
        );
      }
    } catch (_) {}
  }

  static const windowsToastScript = r'''
$m = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $x.GetElementsByTagName('text')
$null = $t.Item(0).AppendChild($x.CreateTextNode($env:PC_NOTIFY_TITLE))
$null = $t.Item(1).AppendChild($x.CreateTextNode($env:PC_NOTIFY_BODY))
$n = [Windows.UI.Notifications.ToastNotification]::new($x)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($n)
''';
}
