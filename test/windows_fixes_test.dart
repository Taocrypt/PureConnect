import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray/tray.dart';
import 'package:zju_connect/core/app_icon.dart';
import 'package:zju_connect/core/desktop_shell.dart';
import 'package:zju_connect/models/settings.dart';
import 'package:zju_connect/ui/tour/guide_tour.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tray', () {
    test('right click (menu requested) opens the tray menu', () async {
      var opened = 0;
      DesktopShell.instance.handleTrayEvent(const TrayMenuRequested(), openMenu: () async => opened++);
      await Future<void>.delayed(Duration.zero);
      expect(opened, 1);
    });

    test('a failing openMenu is swallowed', () async {
      DesktopShell.instance.handleTrayEvent(const TrayMenuRequested(), openMenu: () async => throw StateError('x'));
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('system proxy with external proxy', () {
    AppSettings s({String proxy = '', int http = 7891, int socks = 7890}) =>
        AppSettings.fromJson(const {})
          ..dialDirectProxy = proxy
          ..httpPort = http
          ..socksPort = socks;

    test('system-proxy mode always sets it on desktop', () {
      expect(s().setsSystemProxy(TrafficMode.systemProxy, android: false), isTrue);
      expect(s().setsSystemProxy(TrafficMode.systemProxy, android: true), isFalse);
    });

    test('desktop TUN sets it only with an external proxy', () {
      expect(s().setsSystemProxy(TrafficMode.tun, android: false), isFalse);
      expect(s(proxy: 'socks5://127.0.0.1:7897').setsSystemProxy(TrafficMode.tun, android: false), isTrue);
      expect(s(proxy: '  ').setsSystemProxy(TrafficMode.tun, android: false), isFalse);
      // Android VPN mode does full takeover in the core instead.
      expect(s(proxy: 'socks5://127.0.0.1:7897').setsSystemProxy(TrafficMode.tun, android: true), isFalse);
    });

    test('proxy mode and disabled ports never set it', () {
      expect(s(proxy: 'http://127.0.0.1:1').setsSystemProxy(TrafficMode.proxy, android: false), isFalse);
      expect(s(proxy: 'http://127.0.0.1:1', http: 0, socks: 0).setsSystemProxy(TrafficMode.tun, android: false), isFalse);
    });
  });

  group('windows app icons', () {
    test('embedded icon index follows appIcons order', () {
      expect([for (final id in appIcons) windowsIconIndex(id)], [0, 1, 2, 3]);
      expect(windowsIconIndex(defaultAppIcon), 0);
      expect(windowsIconIndex('nope'), 0);
    });

    test('shortcut result', () {
      final ok = ShortcutIconResult.fromMap({'found': 2, 'updated': 2, 'failed': 0})!;
      expect(ok.needsManual, isFalse);
      expect(ShortcutIconResult.fromMap({'found': 2, 'updated': 1, 'failed': 1})!.needsManual, isTrue);
      expect(ShortcutIconResult.fromMap({'found': 0, 'updated': 0, 'failed': 0})!.needsManual, isTrue);
      expect(ShortcutIconResult.fromMap(null), isNull);
    });
  });

  group('guide lens handle', () {
    const size = Size(800, 600);
    final circle = RRect.fromRectAndRadius(Rect.fromCircle(center: const Offset(400, 200), radius: 30), const Radius.circular(30));

    void pointsAt(GuideHandle h, RRect lens, Rect bubble) {
      final end = h.start + h.dir * h.length;
      // Heads for the bubble: the angle between the handle and the line from
      // the lens centre to the bubble's nearest point is ~0.
      final c = lens.center;
      final target = Offset(c.dx.clamp(bubble.left, bubble.right), c.dy.clamp(bubble.top, bubble.bottom));
      final want = (target - c) / (target - c).distance;
      expect((h.dir - want).distance, lessThan(1e-6));
      // Starts on (just outside) the rim, ends before the bubble.
      expect(lens.outerRect.inflate(2).contains(h.start), isTrue);
      expect(bubble.contains(end), isFalse);
      expect((Offset.zero & size).contains(end), isTrue);
      expect(h.length, greaterThanOrEqualTo(6));
    }

    test('bubble below, above, left, right', () {
      for (final b in [
        const Rect.fromLTWH(230, 250, 340, 120), // below
        const Rect.fromLTWH(230, 20, 340, 120).shift(const Offset(0, -10)), // above
        const Rect.fromLTWH(20, 150, 300, 100), // left
        const Rect.fromLTWH(480, 150, 300, 100), // right
        const Rect.fromLTWH(460, 260, 300, 100), // below right (clamped)
        const Rect.fromLTWH(40, 260, 300, 100), // below left
      ]) {
        final h = guideHandleFor(circle, b, size);
        expect(h, isNotNull, reason: '$b');
        pointsAt(h!, circle, b);
      }
    });

    test('below: points straight down, not to a fixed corner', () {
      final h = guideHandleFor(circle, const Rect.fromLTWH(230, 250, 340, 120), size)!;
      expect(h.dir.dx.abs(), lessThan(1e-9));
      expect(h.dir.dy, closeTo(1, 1e-9));
    });

    test('capsule lens (wide field), bubble shifted by the keyboard', () {
      final field = RRect.fromRectAndRadius(const Rect.fromLTWH(40, 300, 700, 56), const Radius.circular(26));
      final above = const Rect.fromLTWH(60, 120, 340, 150);
      final h = guideHandleFor(field, above, size)!;
      pointsAt(h, field, above);
      // Starts on the top edge of the capsule.
      expect(h.start.dy, closeTo(field.top - 1.5 * h.dir.dy.abs(), 1.6));
    });

    test('no handle when the bubble covers the lens or there is no room', () {
      expect(guideHandleFor(circle, const Rect.fromLTWH(300, 100, 300, 300), size), isNull);
      // Bubble right against the rim.
      expect(guideHandleFor(circle, Rect.fromLTWH(360, circle.bottom + 2, 80, 60), size), isNull);
    });

    test('without a bubble rect: falls back to a corner with room', () {
      final h = guideHandleFor(circle, null, size)!;
      expect(h.dir.dx, closeTo(1 / math.sqrt2, 1e-9));
      expect(h.dir.dy, closeTo(1 / math.sqrt2, 1e-9));
      // Lens in the bottom-right corner: handle goes up-left.
      final corner = RRect.fromRectAndRadius(Rect.fromCircle(center: const Offset(770, 570), radius: 24), const Radius.circular(24));
      final h2 = guideHandleFor(corner, null, size)!;
      expect(h2.dir.dx, lessThan(0));
      expect(h2.dir.dy, lessThan(0));
    });

    test('small screens / landscape keep the handle on screen', () {
      for (final sz in const [Size(320, 568), Size(568, 320), Size(1920, 1080)]) {
        final lens = RRect.fromRectAndRadius(
            Rect.fromCircle(center: Offset(sz.width - 30, sz.height / 2), radius: 26), const Radius.circular(26));
        final bubble = Rect.fromLTWH(16, sz.height / 2 + 50, math.min(340, sz.width - 32), 100);
        final h = guideHandleFor(lens, bubble, sz);
        if (h == null) continue;
        final end = h.start + h.dir * h.length;
        expect((Offset.zero & sz).contains(end), isTrue);
        expect(bubble.contains(end), isFalse);
      }
    });
  });
}
