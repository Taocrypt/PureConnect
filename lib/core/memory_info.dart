import 'dart:io';
import 'dart:math' as math;

/// Memory use shown on the dashboard, after FlClash's memory card
/// (https://github.com/chen08209/FlClash, GPL-3.0): the app (UI process) and
/// the core. The core always runs as its own process here (desktop child or
/// elevated process, Android CoreService), so the two simply add up.
class MemorySnapshot {
  const MemorySnapshot({this.app = 0, this.core = 0});

  /// Resident memory of this (UI) process, bytes.
  final int app;

  /// Resident memory of the core process, bytes; 0 when it is not running.
  final int core;

  int get total => app + core;

  static const empty = MemorySnapshot();

  /// Reads the UI process' RSS (dart:io asks the OS: /proc on Linux and
  /// Android, GetProcessMemoryInfo on Windows, task_info on macOS); [core]
  /// comes from the core's own report.
  static MemorySnapshot read({required int core}) {
    var rss = 0;
    try {
      rss = ProcessInfo.currentRss;
    } catch (_) {}
    return MemorySnapshot(app: math.max(0, rss), core: math.max(0, core));
  }

  /// Whole-percent shares of [parts] for the stacked bar (stable between
  /// polls, so the bar does not re-animate on noise). Sums to 100 unless
  /// everything is 0.
  static List<int> shares(List<int> parts) {
    final total = parts.fold<int>(0, (a, b) => a + math.max(0, b));
    if (total == 0) return List.filled(parts.length, 0);
    final out = [for (final p in parts) (math.max(0, p) * 100 / total).round()];
    final diff = 100 - out.fold<int>(0, (a, b) => a + b);
    if (diff != 0) {
      var i = 0;
      for (var k = 1; k < out.length; k++) {
        if (out[k] > out[i]) i = k;
      }
      out[i] += diff;
    }
    return out;
  }
}
