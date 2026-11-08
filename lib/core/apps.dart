import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('zju_connect/core');

/// An installed Android app.
class AppInfo {
  const AppInfo(this.package, this.label, {this.system = false});
  final String package;
  final String label;
  final bool system;
}

/// Installed apps (Android only). [browsers] limits the list to apps that open
/// http(s) links.
Future<List<AppInfo>> listApps({bool browsers = false}) async {
  if (!Platform.isAndroid) return const [];
  try {
    final l = await _channel.invokeMethod<List>('listApps', {'browsers': browsers}) ?? const [];
    final apps = [
      for (final m in l.whereType<Map>())
        AppInfo(m['package'] as String, (m['label'] as String?) ?? m['package'] as String,
            system: m['system'] == true),
    ];
    apps.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return apps;
  } catch (_) {
    return const [];
  }
}

final _icons = <String, Future<Uint8List?>>{};

/// PNG of an app's launcher icon, cached.
Future<Uint8List?> appIcon(String package) => _icons.putIfAbsent(package, () async {
      try {
        return await _channel.invokeMethod<Uint8List>('appIcon', {'package': package});
      } catch (_) {
        return null;
      }
    });

/// Label of an installed package, or null.
Future<String?> appLabel(String package) async {
  if (package.isEmpty || !Platform.isAndroid) return null;
  try {
    return await _channel.invokeMethod<String>('appLabel', {'package': package});
  } catch (_) {
    return null;
  }
}
