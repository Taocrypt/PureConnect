import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:pointycastle/export.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Backup & restore, after FlClash's: one JSON document holding the
/// profiles (with their saved passwords) and the app settings, saved to a
/// file or to a WebDAV server.

const backupFormat = 'pureconnect-backup';
const _legacyFormats = {'zju-connect-backup'};
const encryptedFormat = 'pureconnect-backup-encrypted';
const backupVersion = 1;

enum RestoreOption { all, onlyProfiles }

/// FlClash's 恢复策略: compatible merges the backup into what is here
/// (same profile id is updated, others kept); override replaces everything.
enum RestoreStrategy { compatible, override }

enum AutoBackup { off, onChange, daily }

/// Options of the backup page (FlClash: 选项), stored apart from settings.
class BackupPrefs {
  const BackupPrefs({
    this.strategy = RestoreStrategy.compatible,
    this.includeSecrets = true,
    this.auto = AutoBackup.off,
    this.keep = 10,
    this.lastAuto,
    this.lastAutoError,
    this.password = '',
  });
  /// Backup password; empty = backups are not encrypted.
  final String password;
  final RestoreStrategy strategy;
  final bool includeSecrets;
  final AutoBackup auto;
  final int keep; // remote backups kept per device
  final DateTime? lastAuto;
  final String? lastAutoError;

  BackupPrefs copyWith({
    RestoreStrategy? strategy,
    bool? includeSecrets,
    AutoBackup? auto,
    int? keep,
    DateTime? lastAuto,
    Object? lastAutoError = _keep,
    String? password,
  }) =>
      BackupPrefs(
        strategy: strategy ?? this.strategy,
        includeSecrets: includeSecrets ?? this.includeSecrets,
        auto: auto ?? this.auto,
        keep: keep ?? this.keep,
        lastAuto: lastAuto ?? this.lastAuto,
        lastAutoError: identical(lastAutoError, _keep) ? this.lastAutoError : lastAutoError as String?,
        password: password ?? this.password,
      );
  static const _keep = Object();

  Map<String, dynamic> toJson() => {
        'strategy': strategy.name,
        'includeSecrets': includeSecrets,
        'auto': auto.name,
        'keep': keep,
        if (lastAuto != null) 'lastAuto': lastAuto!.toUtc().toIso8601String(),
        if (lastAutoError != null) 'lastAutoError': lastAutoError,
        'password': password,
      };
  factory BackupPrefs.fromJson(Map<String, dynamic> j) => BackupPrefs(
        strategy: RestoreStrategy.values.asNameMap()[j['strategy']] ?? RestoreStrategy.compatible,
        includeSecrets: j['includeSecrets'] as bool? ?? true,
        auto: AutoBackup.values.asNameMap()[j['auto']] ?? AutoBackup.off,
        keep: (j['keep'] as num?)?.toInt() ?? 10,
        lastAuto: DateTime.tryParse(j['lastAuto'] as String? ?? ''),
        lastAutoError: j['lastAutoError'] as String?,
        password: j['password'] as String? ?? '',
      );
}

/// Merges a backup's profiles into the current ones.
List<Map<String, dynamic>> mergeProfiles(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> backup,
  RestoreStrategy strategy,
) {
  Map<String, dynamic> withSecrets(Map<String, dynamic> b, Map<String, dynamic>? old) {
    // A backup made without passwords keeps the ones saved here.
    if (old == null) return b;
    final out = {...b};
    for (final k in secretProfileKeys) {
      if ((out[k] as String? ?? '').isEmpty && (old[k] as String? ?? '').isNotEmpty) out[k] = old[k];
    }
    return out;
  }

  final byId = {for (final p in current) p['id']: p};
  if (strategy == RestoreStrategy.override) {
    return [for (final b in backup) withSecrets(b, byId[b['id']])];
  }
  final backupById = {for (final b in backup) b['id']: b};
  return [
    for (final p in current) backupById.containsKey(p['id']) ? withSecrets(backupById[p['id']]!, p) : p,
    for (final b in backup)
      if (!byId.containsKey(b['id'])) b,
  ];
}

class BackupException implements Exception {
  const BackupException(this.key);

  /// l10n key: backup_invalid / backup_newer
  final String key;
  @override
  String toString() => key;
}

/// Profile fields that hold credentials or session tokens.
const secretProfileKeys = ['password', 'totpSecret', 'certPassword', 'twfId', 'casTicket', 'oauth2Code'];

Uint8List encodeBackup({
  required List<Map<String, dynamic>> profiles,
  required Map<String, dynamic> settings,
  bool includeSecrets = true,
  String device = '',
  String password = '',
}) {
  if (!includeSecrets) {
    profiles = [
      for (final p in profiles) {...p}..removeWhere((k, _) => secretProfileKeys.contains(k)),
    ];
  }
  final doc = {
    'format': backupFormat,
    'version': backupVersion,
    'created': DateTime.now().toUtc().toIso8601String(),
    'device': device,
    'secrets': includeSecrets,
    'profiles': profiles,
    'settings': settings,
  };
  final plain = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(doc)));
  return password.isEmpty ? plain : encryptBackup(plain, password);
}

/// True when [bytes] is an encrypted backup (needs a password to read).
bool isEncryptedBackup(List<int> bytes) {
  try {
    final j = jsonDecode(utf8.decode(bytes));
    return j is Map && j['format'] == encryptedFormat;
  } catch (_) {
    return false;
  }
}

// ---- AES-256-GCM, key from PBKDF2-HMAC-SHA256 ----

const _kdfIterations = 100000;

Uint8List _deriveKey(String password, Uint8List salt, int iterations) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(salt, iterations, 32));
  return kdf.process(Uint8List.fromList(utf8.encode(password)));
}

Uint8List _random(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Wraps a plain backup in a JSON envelope encrypted with AES-256-GCM.
Uint8List encryptBackup(Uint8List plain, String password) {
  final salt = _random(16), iv = _random(12);
  final key = _deriveKey(password, salt, _kdfIterations);
  final gcm = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  final data = gcm.process(plain);
  final doc = {
    'format': encryptedFormat,
    'version': 1,
    'cipher': 'aes-256-gcm',
    'kdf': 'pbkdf2-hmac-sha256',
    'iterations': _kdfIterations,
    'salt': base64.encode(salt),
    'iv': base64.encode(iv),
    'data': base64.encode(data),
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(doc)));
}

Uint8List decryptBackup(Map<String, dynamic> j, String password) {
  try {
    final salt = base64.decode(j['salt'] as String), iv = base64.decode(j['iv'] as String);
    final key = _deriveKey(password, salt, (j['iterations'] as num).toInt());
    final gcm = GCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return gcm.process(base64.decode(j['data'] as String));
  } on InvalidCipherTextException {
    throw const BackupException('backup_wrong_password');
  } on ArgumentError {
    throw const BackupException('backup_wrong_password');
  } on FormatException {
    throw const BackupException('backup_invalid');
  } on TypeError {
    throw const BackupException('backup_invalid');
  }
}

/// Key derivation is slow on purpose; run it off the UI isolate.
Future<Uint8List> encodeBackupAsync({
  required List<Map<String, dynamic>> profiles,
  required Map<String, dynamic> settings,
  bool includeSecrets = true,
  String device = '',
  String password = '',
}) =>
    Isolate.run(() => encodeBackup(
        profiles: profiles, settings: settings, includeSecrets: includeSecrets, device: device, password: password));

Future<BackupData> decodeBackupAsync(List<int> bytes, {String? password}) =>
    Isolate.run(() => decodeBackup(bytes, password: password));

class BackupData {
  BackupData(this.profiles, this.settings, this.created, [this.device = '']);
  final List<Map<String, dynamic>> profiles;
  final Map<String, dynamic>? settings;
  final DateTime? created;
  final String device;
}

BackupData decodeBackup(List<int> bytes, {String? password}) {
  Object? j;
  try {
    j = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw const BackupException('backup_invalid');
  }
  if (j is Map && j['format'] == encryptedFormat) {
    if (password == null || password.isEmpty) throw const BackupException('backup_need_password');
    return decodeBackup(decryptBackup(j.cast<String, dynamic>(), password));
  }
  if (j is! Map || !(j['format'] == backupFormat || _legacyFormats.contains(j['format'])) || j['profiles'] is! List) {
    throw const BackupException('backup_invalid');
  }
  if ((j['version'] as num? ?? 0) > backupVersion) throw const BackupException('backup_newer');
  return BackupData(
    [for (final p in j['profiles'] as List) if (p is Map) p.cast<String, dynamic>()],
    (j['settings'] as Map?)?.cast<String, dynamic>(),
    DateTime.tryParse(j['created'] as String? ?? ''),
    j['device'] as String? ?? '',
  );
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

String backupFileName() => 'pureconnect-${_stamp(DateTime.now())}.json';

/// Remote names are `<device>-<yyyyMMdd-HHmmss>.json` so every device keeps
/// its own history and retention only prunes its own files.
String remoteBackupName(String device) => '${sanitizeDevice(device)}-${_stamp(DateTime.now())}.json';

String sanitizeDevice(String d) {
  final s = d.trim().replaceAll(RegExp(r'[^A-Za-z0-9._\u4e00-\u9fa5-]+'), '_');
  return s.isEmpty ? 'device' : s;
}

String defaultDeviceName() {
  try {
    final h = Platform.localHostname;
    if (h.isNotEmpty && h != 'localhost') return '${Platform.operatingSystem}-$h';
  } catch (_) {}
  return Platform.operatingSystem;
}

// ---------------------------------------------------------------------------
// WebDAV
// ---------------------------------------------------------------------------

class DavConfig {
  const DavConfig({required this.uri, required this.user, required this.password, this.fileName = ''});
  final String uri, user, password;

  /// Device name used as the remote file prefix ('' = default).
  final String fileName;
  String get device => fileName.trim().isEmpty ? defaultDeviceName() : fileName.trim();

  Map<String, dynamic> toJson() => {'uri': uri, 'user': user, 'password': password, 'fileName': fileName};
  factory DavConfig.fromJson(Map<String, dynamic> j) => DavConfig(
        uri: j['uri'] as String? ?? '',
        user: j['user'] as String? ?? '',
        password: j['password'] as String? ?? '',
        fileName: j['fileName'] as String? ?? '',
      );
  DavConfig copyWith({String? fileName}) =>
      DavConfig(uri: uri, user: user, password: password, fileName: fileName ?? this.fileName);
}

class DavException implements Exception {
  DavException(this.method, this.path, this.status, [this.reason]);
  final String method, path;
  final int? status;
  final String? reason;
  @override
  String toString() => 'WebDAV $method $path: ${status ?? 'no response'}${reason == null || reason!.isEmpty ? '' : ' $reason'}';
}

/// Minimal WebDAV client (OPTIONS / MKCOL / PUT / GET) with Basic and Digest
/// authentication, like FlClash's DAVTransport.
class DavClient {
  DavClient(this.config, {HttpClient? http})
      : _base = Uri.parse(config.uri.trim()),
        _http = http ?? (HttpClient()..connectionTimeout = const Duration(seconds: 8));

  final DavConfig config;
  final Uri _base;
  final HttpClient _http;
  Map<String, String>? _digest;
  int _nc = 0;

  static const appDir = 'PureConnect';

  Uri _resolve(String path, {bool collection = false}) {
    final segs = [
      ..._base.pathSegments.where((s) => s.isNotEmpty),
      ...path.split('/').where((s) => s.isNotEmpty),
    ];
    return _base.replace(pathSegments: collection ? [...segs, ''] : segs, query: null, fragment: null);
  }

  Future<bool> ping() async {
    try {
      await _send('OPTIONS', '/', collection: true, ok: const {200, 204});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Uploads [bytes] as [name], then keeps only the newest [keep] backups
  /// of [device] (0 = keep all).
  Future<void> upload(String name, List<int> bytes, {String? device, int keep = 0}) async {
    // 405: the directory already exists.
    await _send('MKCOL', '/$appDir', collection: true, ok: const {200, 201, 204, 301, 405});
    await _send('PUT', '/$appDir/$name', body: bytes, ok: const {200, 201, 204});
    if (device != null && keep > 0) {
      final prefix = '${sanitizeDevice(device)}-';
      final mine = (await _listDir(appDir)).where((e) => e.name.startsWith(prefix)).toList();
      for (final e in mine.skip(keep)) {
        try {
          await _send('DELETE', '/$appDir/${e.name}', ok: const {200, 204, 404});
        } catch (_) {}
      }
    }
  }

  Future<Uint8List> download(String name) async => _send('GET', '/$appDir/$name', ok: const {200});

  /// Backups in the app folder, newest first.
  Future<List<DavEntry>> list() => _listDir(appDir);

  Future<List<DavEntry>> _listDir(String dir) async {
    final Uint8List body;
    try {
      body = await _send('PROPFIND', '/$dir',
          collection: true, depth: '1', ok: const {207, 200}, body: utf8.encode(_propfind), xml: true);
    } on DavException catch (e) {
      if (e.status == 404) return [];
      rethrow;
    }
    return [
      for (final e in parsePropfind(utf8.decode(body, allowMalformed: true))) DavEntry(e.name, e.modified, e.size, dir: dir),
    ];
  }

  static const _propfind = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>';

  Future<Uint8List> _send(String method, String path,
      {bool collection = false, List<int>? body, required Set<int> ok, String? depth, bool xml = false}) async {
    final uri = _resolve(path, collection: collection);
    for (var attempt = 0; attempt < 2; attempt++) {
      final req = await _http.openUrl(method, uri).timeout(const Duration(seconds: 15));
      req.followRedirects = method == 'GET' || method == 'OPTIONS';
      final auth = _authHeader(method, uri);
      if (auth != null) req.headers.set(HttpHeaders.authorizationHeader, auth);
      if (depth != null) req.headers.set('Depth', depth);
      if (body != null) {
        req.headers.contentType =
            xml ? ContentType('application', 'xml', charset: 'utf-8') : ContentType('application', 'json', charset: 'utf-8');
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(const Duration(seconds: 60));
      final data = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d));
      if (res.statusCode == 401 && attempt == 0) {
        final challenge = res.headers.value(HttpHeaders.wwwAuthenticateHeader) ?? '';
        if (challenge.toLowerCase().startsWith('digest')) {
          _digest = _parseDigest(challenge.substring(6));
          _nc = 0;
          continue;
        }
      }
      if (!ok.contains(res.statusCode)) throw DavException(method, path, res.statusCode, res.reasonPhrase);
      return data.takeBytes();
    }
    throw DavException(method, path, 401, 'Unauthorized');
  }

  String? _authHeader(String method, Uri uri) {
    if (config.user.isEmpty && config.password.isEmpty) return null;
    final d = _digest;
    if (d == null) return 'Basic ${base64.encode(utf8.encode('${config.user}:${config.password}'))}';
    String md5(String s) => crypto.md5.convert(utf8.encode(s)).toString();
    final realm = d['realm'] ?? '', nonce = d['nonce'] ?? '';
    final qop = (d['qop'] ?? '').split(',').map((e) => e.trim()).contains('auth') ? 'auth' : null;
    final reqUri = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final ha1 = md5('${config.user}:$realm:${config.password}');
    final ha2 = md5('$method:$reqUri');
    final nc = (++_nc).toRadixString(16).padLeft(8, '0');
    final cnonce = md5('${DateTime.now().microsecondsSinceEpoch}').substring(0, 16);
    final response = qop == null ? md5('$ha1:$nonce:$ha2') : md5('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
    return [
      'Digest username="${config.user}"',
      'realm="$realm"',
      'nonce="$nonce"',
      'uri="$reqUri"',
      if (qop != null) ...['qop=$qop', 'nc=$nc', 'cnonce="$cnonce"'],
      'response="$response"',
      if (d['opaque'] != null) 'opaque="${d['opaque']}"',
      if (d['algorithm'] != null) 'algorithm=${d['algorithm']}',
    ].join(', ');
  }

  static Map<String, String> _parseDigest(String s) {
    final out = <String, String>{};
    for (final m in RegExp(r'(\w+)=("([^"]*)"|[^,\s]+)').allMatches(s)) {
      out[m.group(1)!.toLowerCase()] = m.group(3) ?? m.group(2)!;
    }
    return out;
  }

  void close() => _http.close(force: true);
}

class DavEntry {
  DavEntry(this.name, this.modified, this.size, {this.dir = DavClient.appDir});
  final String name;
  final String dir;
  final DateTime? modified;
  final int size;
}

/// Reads file entries (*.json) out of a PROPFIND multistatus, newest first.
List<DavEntry> parsePropfind(String xml) {
  final out = <DavEntry>[];
  final resp = RegExp(r'<(?:[A-Za-z0-9]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9]+:)?response>');
  String? tag(String block, String name) =>
      RegExp('<(?:[A-Za-z0-9]+:)?$name\\b[^>]*>([\\s\\S]*?)</(?:[A-Za-z0-9]+:)?$name>').firstMatch(block)?.group(1)?.trim();
  for (final m in resp.allMatches(xml)) {
    final block = m.group(1)!;
    final href = tag(block, 'href');
    if (href == null || RegExp(r'<(?:[A-Za-z0-9]+:)?collection\b').hasMatch(block)) continue;
    final name = Uri.decodeComponent(href.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '');
    if (!name.endsWith('.json')) continue;
    final lm = tag(block, 'getlastmodified');
    DateTime? when;
    if (lm != null) {
      try {
        when = HttpDate.parse(lm);
      } catch (_) {}
    }
    out.add(DavEntry(name, when, int.tryParse(tag(block, 'getcontentlength') ?? '') ?? 0));
  }
  out.sort((a, b) {
    final c = (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0));
    return c != 0 ? c : b.name.compareTo(a.name);
  });
  return out;
}
