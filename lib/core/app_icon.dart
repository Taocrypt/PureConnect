import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Selectable app icons. `a1` is the default. Android switches launcher
/// activity-aliases. Windows embeds all four in pureconnect.exe (icon index
/// = position in this list, see windows/runner/Runner.rc): the window icon
/// changes at once, and the app's shortcuts (Start Menu, desktop, pinned
/// taskbar) are pointed at the chosen index, since Explorer draws the
/// taskbar / Start icon from the shortcut the app was started from.
const appIcons = ['a1', 'a2', 'b1', 'b2'];
const defaultAppIcon = 'a1';

String appIconPreview(String id) => 'assets/icon/$id.png';

bool get appIconSupported => Platform.isAndroid || Platform.isWindows || Platform.isMacOS || Platform.isLinux;

const _android = MethodChannel('zju_connect/core');
const _windows = MethodChannel('pureconnect/window');

/// Applies [id]. Returns false when the platform refused.
Future<bool> applyAppIcon(String id) async {
  if (!appIcons.contains(id)) id = defaultAppIcon;
  try {
    if (Platform.isAndroid) {
      return await _android.invokeMethod<bool>('setLauncherIcon', id) ?? false;
    }
    if (Platform.isWindows) {
      return await _windows.invokeMethod<bool>('setIcon', windowsIconIndex(id)) ?? false;
    }
    if (Platform.isMacOS) {
      // Dock icon while running; empty path restores the bundle icon (a1).
      final png = id == defaultAppIcon ? '' : p.join(_macAssets(), '$id.png');
      return await _windows.invokeMethod<bool>('setIcon', png) ?? false;
    }
    if (Platform.isLinux) {
      final png = p.join(File(Platform.resolvedExecutable).parent.path, 'data', 'flutter_assets', 'assets', 'icon', '$id.png');
      final ok = await _windows.invokeMethod<bool>('setIcon', png) ?? false;
      await _updateLinuxDesktopEntry(png);
      return ok;
    }
  } catch (_) {}
  return false;
}

/// Index of [id] among the icons embedded in pureconnect.exe (0 = default).
int windowsIconIndex(String id) => math.max(0, appIcons.indexOf(id));

/// Result of pointing the Windows shortcuts at an icon.
class ShortcutIconResult {
  const ShortcutIconResult({required this.found, required this.updated, required this.failed});
  final int found, updated, failed;

  /// Some shortcut could not be changed (all-users shortcuts need admin), or
  /// none was found: the user should change it by hand.
  bool get needsManual => failed != 0 || found == 0;

  static ShortcutIconResult? fromMap(Object? m) {
    if (m is! Map) return null;
    int v(String k) => (m[k] as num?)?.toInt() ?? 0;
    return ShortcutIconResult(found: v('found'), updated: v('updated'), failed: v('failed'));
  }
}

/// Windows: points PureConnect's shortcuts at [id]'s embedded icon.
Future<ShortcutIconResult?> applyWindowsShortcutIcon(String id) async {
  if (!Platform.isWindows) return null;
  try {
    return ShortcutIconResult.fromMap(
        await _windows.invokeMethod<Object?>('setShortcutIcon', windowsIconIndex(id)));
  } catch (_) {
    return null;
  }
}

/// Android: the launcher icon that is actually enabled.
Future<String?> currentLauncherIcon() async {
  if (!Platform.isAndroid) return null;
  try {
    return await _android.invokeMethod<String>('launcherIcon');
  } catch (_) {
    return null;
  }
}

String _macAssets() => p.join(File(Platform.resolvedExecutable).parent.parent.path,
    'Frameworks', 'App.framework', 'Resources', 'flutter_assets', 'assets', 'icon');

/// Linux: points Icon= of the user's own PureConnect .desktop entry (if any)
/// at [png] so menus/docks follow the chosen icon.
Future<void> _updateLinuxDesktopEntry(String png) async {
  final home = Platform.environment['HOME'];
  if (home == null) return;
  final dir = Directory(p.join(home, '.local', 'share', 'applications'));
  if (!await dir.exists()) return;
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.desktop')) continue;
    if (!p.basename(f.path).toLowerCase().contains('pureconnect')) continue;
    try {
      final lines = await f.readAsLines();
      final out = [for (final l in lines) l.startsWith('Icon=') ? 'Icon=$png' : l];
      await f.writeAsString('${out.join('\n')}\n');
    } catch (_) {}
  }
}
