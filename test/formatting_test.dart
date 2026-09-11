import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/ui/common/formatting.dart';

void main() {
  group('formatDuration', () {
    test('pads to mm:ss', () {
      expect(formatDuration(Duration.zero), '00:00');
      expect(formatDuration(const Duration(seconds: 7)), '00:07');
      expect(formatDuration(const Duration(minutes: 3, seconds: 9)), '03:09');
      expect(formatDuration(const Duration(minutes: 12, seconds: 45)), '12:45');
    });

    test('adds hours only once past an hour', () {
      expect(formatDuration(const Duration(minutes: 59, seconds: 59)), '59:59');
      expect(formatDuration(const Duration(hours: 1, seconds: 5)), '1:00:05');
      expect(
        formatDuration(const Duration(hours: 2, minutes: 3, seconds: 4)),
        '2:03:04',
      );
    });
  });

  group('formatRelative', () {
    final now = DateTime(2026, 9, 11, 12, 0);

    test('describes recent times', () {
      expect(formatRelative(now.subtract(const Duration(seconds: 5)), now: now),
          'just now');
      expect(formatRelative(now.subtract(const Duration(minutes: 12)), now: now),
          '12m ago');
      expect(formatRelative(now.subtract(const Duration(hours: 5)), now: now),
          '5h ago');
      expect(formatRelative(now.subtract(const Duration(days: 3)), now: now),
          '3d ago');
    });

    test('falls back to a date past a week', () {
      expect(formatRelative(DateTime(2026, 8, 20), now: now), '20 Aug');
    });

    test('includes the year for a different year', () {
      expect(formatRelative(DateTime(2025, 12, 31), now: now), '31 Dec 2025');
    });

    test('the one-minute boundary reads as minutes, not "just now"', () {
      expect(formatRelative(now.subtract(const Duration(seconds: 61)), now: now),
          '1m ago');
    });
  });
}
