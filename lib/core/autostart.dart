import 'dart:io';

import 'package:path/path.dart' as p;

/// Launch at login on desktop. The OS entry itself is the source of truth
/// (it is per machine, so it is not part of settings or backups).
///
/// Windows: HKCU\…\Run value "PureConnect".
/// macOS: ~/Library/LaunchAgents/com.taocrypt.pureconnect.plist (open -a).
/// Linux: ~/.config/autostart/com.taocrypt.pureconnect.desktop (XDG).
///
/// With [hidden] the entry passes `--hidden`, which keeps the window in the
/// tray until opened.
class Autostart {
  static const _id = 'com.taocrypt.pureconnect';
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValue = 'PureConnect';

  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static String? get _home => Platform.environment['HOME'];

  static File? get _macPlist =>
      _home == null ? null : File(p.join(_home!, 'Library', 'LaunchAgents', '$_id.plist'));

  static File? get _linuxDesktop {
    final config = Platform.environment['XDG_CONFIG_HOME'] ??
        (_home == null ? null : p.join(_home!, '.config'));
    return config == null ? null : File(p.join(config, 'autostart', '$_id.desktop'));
  }

  static Future<bool> isEnabled() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('reg', ['query', _runKey, '/v', _runValue]);
        return r.exitCode == 0;
      }
      if (Platform.isMacOS) return _macPlist?.existsSync() ?? false;
      if (Platform.isLinux) return _linuxDesktop?.existsSync() ?? false;
    } catch (_) {}
    return false;
  }

  /// Creates, updates or removes the entry. Returns false on failure.
  static Future<bool> set(bool enabled, {bool hidden = false}) async {
    try {
      if (Platform.isWindows) {
        if (!enabled) {
          final r = await Process.run('reg', ['delete', _runKey, '/v', _runValue, '/f']);
          return r.exitCode == 0 || !await isEnabled();
        }
        final cmd = '"${Platform.resolvedExecutable}"${hidden ? ' --hidden' : ''}';
        final r = await Process.run('reg', ['add', _runKey, '/v', _runValue, '/t', 'REG_SZ', '/d', cmd, '/f']);
        return r.exitCode == 0;
      }
      if (Platform.isMacOS) {
        final f = _macPlist;
        if (f == null) return false;
        if (!enabled) {
          if (f.existsSync()) await f.delete();
          return true;
        }
        await f.parent.create(recursive: true);
        await f.writeAsString(macPlist(_macAppPath(), hidden: hidden));
        return true;
      }
      if (Platform.isLinux) {
        final f = _linuxDesktop;
        if (f == null) return false;
        if (!enabled) {
          if (f.existsSync()) await f.delete();
          return true;
        }
        await f.parent.create(recursive: true);
        final exe = Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable;
        await f.writeAsString(linuxDesktopEntry(exe, hidden: hidden));
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// …/PureConnect.app/Contents/MacOS/PureConnect → …/PureConnect.app
  static String _macAppPath() {
    final exe = Platform.resolvedExecutable;
    final i = exe.indexOf('.app/Contents/MacOS/');
    return i > 0 ? exe.substring(0, i + 4) : exe;
  }

  static String _xml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String macPlist(String appPath, {required bool hidden}) {
    final args = ['/usr/bin/open', '-a', appPath, if (hidden) ...['--args', '--hidden']];
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$_id</string>
  <key>ProgramArguments</key>
  <array>
${args.map((a) => '    <string>${_xml(a)}</string>').join('\n')}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
''';
  }

  static String linuxDesktopEntry(String exe, {required bool hidden}) {
    final quoted = '"${exe.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$').replaceAll('`', r'\`')}"';
    return '''[Desktop Entry]
Type=Application
Name=PureConnect
Exec=$quoted${hidden ? ' --hidden' : ''}
Icon=$_id
Terminal=false
X-GNOME-Autostart-enabled=true
''';
  }
}
