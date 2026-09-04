// Formatting rules for upload progress.
//
// These strings are the only thing standing between "this is moving" and "this
// is stuck" for an inspector watching a two-minute video upload, so the
// boundaries matter: a wrong unit or a stale "Uploading..." is the bug this
// whole area exists to fix.

import 'package:flutter_test/flutter_test.dart';

import 'package:certifide_inspektor/models/inspection_state.dart';
import 'package:certifide_inspektor/utils/upload_display.dart';

void main() {
  group('formatBytes', () {
    test('Given bytes under a kilobyte, When formatted, Then it stays in B',
        () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('Given kilobytes, When formatted, Then it rounds to whole KB', () {
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1024 * 947), '947 KB');
    });

    test('Given megabytes, When formatted, Then it keeps one decimal', () {
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes((1024 * 1024 * 88.4).round()), '88.4 MB');
    });

    test('Given gigabytes, When formatted, Then it keeps two decimals', () {
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
    });
  });

  group('formatRate', () {
    test('Given a slow link, When formatted, Then it reads in KB/s', () {
      expect(formatRate(1024 * 820), '820 KB/s');
    });

    test('Given a fast link, When formatted, Then it reads in MB/s', () {
      expect(formatRate(1024 * 1024 * 1.8), '1.8 MB/s');
    });

    test('Given a stopped transfer, When formatted, Then it reads 0 KB/s', () {
      expect(formatRate(0), '0 KB/s');
    });
  });

  group('formatShortDuration', () {
    test('Given under a minute, When formatted, Then it reads in seconds', () {
      expect(formatShortDuration(const Duration(seconds: 41)), '41s');
    });

    test('Given whole minutes, When formatted, Then seconds are dropped', () {
      expect(formatShortDuration(const Duration(minutes: 3)), '3m');
    });

    test('Given minutes and seconds, When formatted, Then both are shown', () {
      expect(formatShortDuration(const Duration(minutes: 3, seconds: 20)),
          '3m 20s');
    });

    test('Given over an hour, When formatted, Then it reads in hours', () {
      expect(formatShortDuration(const Duration(hours: 1, minutes: 5)),
          '1h 5m');
    });
  });

  group('uploadBadgeLabel — the difference between moving and stuck', () {
    test(
        'Given no sample yet, When labelled, Then it falls back to the plain '
        'word', () {
      expect(uploadBadgeLabel(null), 'Uploading...');
    });

    test(
        'Given a body of unknown length, When labelled, Then it falls back '
        'rather than printing a nonsense percentage', () {
      expect(uploadBadgeLabel(const MediaFileProgress(sent: 10, total: 0)),
          'Uploading...');
    });

    test('Given a rate, When labelled, Then percent and speed are shown', () {
      expect(
        uploadBadgeLabel(MediaFileProgress(
          sent: 34,
          total: 100,
          bytesPerSecond: 1024 * 1024 * 1.8,
        )),
        '34% · 1.8 MB/s',
      );
    });

    test(
        'Given a stalled transfer, When labelled, Then the percentage is shown '
        'without a speed', () {
      expect(
        uploadBadgeLabel(const MediaFileProgress(sent: 34, total: 100)),
        '34%',
        reason: 'a zero rate means the stall tick fired; printing "0 KB/s" '
            'next to a percentage reads as a broken figure',
      );
    });

    test(
        'Given no room for the rate, When labelled, Then only the percentage '
        'is returned', () {
      expect(
        uploadBadgeLabel(
          MediaFileProgress(
              sent: 34, total: 100, bytesPerSecond: 1024 * 1024 * 1.8),
          withRate: false,
        ),
        '34%',
      );
    });

    test('Given a finished file, When labelled, Then it reads 100%', () {
      expect(
        uploadBadgeLabel(
            const MediaFileProgress(sent: 100, total: 100, bytesPerSecond: 1)),
        '100% · 0 KB/s',
      );
    });
  });
}
