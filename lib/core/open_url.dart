import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const _channel = MethodChannel('zju_connect/core');

/// URLs without a scheme (bare IP / host) get http://.
String normalizeUrl(String url) {
  final u = url.trim();
  return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(u) ? u : 'http://$u';
}

/// Opens [url] in [package] (Android) or the default handler.
Future<void> openUrl(String url, {String? package}) async {
  final u = normalizeUrl(url);
  if (Platform.isAndroid) {
    final ok = await _channel.invokeMethod<bool>('openUrl', {'url': u, 'package': package});
    if (ok == true) return;
  }
  await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
}
