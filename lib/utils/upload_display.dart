import '../models/inspection_state.dart';

/// Formatting for upload progress, shared by the inspection screen's capture
/// badges and the reports queue rows so the same transfer never reads two
/// different ways on two screens.

/// Bytes as an inspector reads them: "947 KB", "88.1 MB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.round()} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// Transfer rate: "820 KB/s", "1.8 MB/s".
String formatRate(double bytesPerSecond) {
  final kb = bytesPerSecond / 1024;
  if (kb < 1024) return '${kb.round()} KB/s';
  return '${(kb / 1024).toStringAsFixed(1)} MB/s';
}

/// Short remaining time: "41s", "3m 20s", "1h 5m".
String formatShortDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  if (minutes < 60) {
    return seconds == 0 ? '${minutes}m' : '${minutes}m ${seconds}s';
  }
  return '${d.inHours}h ${minutes % 60}m';
}

/// Badge text for an upload in flight: "34% · 1.8 MB/s".
///
/// A bare "Uploading..." on a two-minute video looks the same at 5% as it does
/// when the connection has died, so that wording is only used until the first
/// sample lands. Pass [withRate] false where there is no room for the speed.
String uploadBadgeLabel(MediaFileProgress? progress, {bool withRate = true}) {
  if (progress == null || progress.total <= 0) return 'Uploading...';
  final percent = '${(progress.fraction * 100).round()}%';
  if (!withRate || progress.bytesPerSecond <= 0) return percent;
  return '$percent · ${formatRate(progress.bytesPerSecond)}';
}
