import 'dart:convert';

import '../models/profile.dart';
/// Clipboard format for sharing one profile. Includes the password and
/// certificate password (the UI warns first); the TOTP secret, session tokens
/// and the local certificate path are never exported.
const profileShareTag = 'pureconnect-profile';

const _unsharedKeys = ['totpSecret', 'twfId', 'casTicket', 'oauth2Code'];

String encodeProfileShare(Profile p) {
  final j = p.toJson()
    ..remove('id')
    ..remove('certFile');
  for (final k in _unsharedKeys) {
    j.remove(k);
  }
  return jsonEncode({'type': profileShareTag, 'version': 1, 'profile': j});
}

/// Parses clipboard text into a new profile (fresh id), or null when the
/// text isn't a shared profile. Accepts a bare profile JSON object too.
Profile? decodeProfileShare(String text) {
  try {
    final v = jsonDecode(text.trim());
    if (v is! Map) return null;
    final m = v['type'] == profileShareTag ? v['profile'] : v;
    if (m is! Map) return null;
    final j = m.cast<String, dynamic>()..remove('id');
    if ((j['serverAddress'] as String? ?? '').isEmpty && j['name'] == null) return null;
    for (final k in _unsharedKeys) {
      j.remove(k);
    }
    j['name'] = (j['name'] as String?)?.trim().isNotEmpty == true ? j['name'] : j['serverAddress'];
    return Profile.fromJson(j);
  } catch (_) {
    return null;
  }
}
