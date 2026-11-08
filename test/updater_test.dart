import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/updater.dart';

void main() {
  test('compareVersions', () {
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('v1.0.1', '1.0.0'), greaterThan(0));
    expect(compareVersions('1.2.0', '1.10.0'), lessThan(0));
    expect(compareVersions('2.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('1.0.0+5', '1.0.0+1'), 0);
    expect(compareVersions('1.1.0-beta.1', '1.1.0'), lessThan(0));
    expect(compareVersions('1.1.0-beta.1', '1.0.9'), greaterThan(0));
  });

  final release = ReleaseInfo.fromJson({
    'tag_name': 'v1.2.0',
    'name': 'v1.2.0',
    'body': '## 新功能\n- a',
    'html_url': 'https://github.com/Taocrypt/PureConnect/releases/tag/v1.2.0',
    'assets': [
      for (final n in [
        'PureConnect-1.2.0-android-arm64-v8a.apk',
        'PureConnect-1.2.0-android-armeabi-v7a.apk',
        'PureConnect-1.2.0-android-x86_64.apk',
        'PureConnect-1.2.0-android-universal.apk',
        'PureConnect-1.2.0-windows-x64.zip',
        'PureConnect-1.2.0-windows-x64-setup.exe',
        'PureConnect-1.2.0-macos-universal.dmg',
        'PureConnect-1.2.0-linux-x64.tar.gz',
        'PureConnect-1.2.0-linux-amd64.deb',
      ])
        {'name': n, 'browser_download_url': 'https://example.com/$n', 'size': 1024},
    ],
  });

  test('release parsing', () {
    expect(release.version, '1.2.0');
    expect(release.assets, hasLength(9));
    expect(release.assets.first.size, 1024);
  });

  test('pickAsset per platform', () {
    expect(pickAsset(release, os: 'android', abis: ['arm64-v8a', 'armeabi-v7a'])!.name, contains('arm64-v8a'));
    expect(pickAsset(release, os: 'android', abis: ['armeabi-v7a', 'armeabi'])!.name, contains('armeabi-v7a'));
    expect(pickAsset(release, os: 'android', abis: ['x86_64', 'arm64-v8a'])!.name, contains('x86_64'));
    expect(pickAsset(release, os: 'android', abis: ['mips'])!.name, contains('universal'));
    expect(pickAsset(release, os: 'windows')!.name, endsWith('setup.exe'));
    expect(pickAsset(release, os: 'macos')!.name, endsWith('.dmg'));
    expect(pickAsset(release, os: 'linux', debInstall: true)!.name, endsWith('.deb'));
    expect(pickAsset(release, os: 'linux', debInstall: false)!.name, endsWith('.tar.gz'));
    expect(pickAsset(ReleaseInfo.fromJson({'tag_name': 'v1', 'assets': []}), os: 'macos'), isNull);
  });
}
