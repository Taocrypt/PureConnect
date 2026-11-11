import 'package:flutter_test/flutter_test.dart';
import 'package:zju_connect/core/memory_info.dart';
import 'package:zju_connect/core/protocol.dart';

void main() {
  test('bar shares are whole percents summing to 100', () {
    expect(MemorySnapshot.shares([0, 0]), [0, 0]);
    expect(MemorySnapshot.shares([100, 0]), [100, 0]);
    expect(MemorySnapshot.shares([1, 2]), [33, 67]);
    for (final p in [
      [1, 1, 1],
      [5, 7],
      [123456789, 987654321],
    ]) {
      expect(MemorySnapshot.shares(p).reduce((a, b) => a + b), 100, reason: '$p');
    }
    expect(MemorySnapshot.shares([-5, 10]), [0, 100]);
  });

  test('reads this process and adds the core', () {
    final m = MemorySnapshot.read(core: 50 << 20);
    expect(m.app, greaterThan(0));
    expect(m.total, m.app + (50 << 20));
  });

  test('core memory arrives with the traffic event', () {
    final ev = CoreEvent.parse({
      'type': 'traffic',
      'traffic': {'tx': 1, 'rx': 2, 'tx_rate': 3, 'rx_rate': 4, 'mem': 31457280},
    });
    expect(ev, isA<TrafficEvent>());
    expect((ev as TrafficEvent).stats.mem, 31457280);
    expect(TrafficStats.fromJson(const {}).mem, 0);
  });
}
