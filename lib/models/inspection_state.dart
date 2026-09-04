import 'package:flutter/foundation.dart';

import 'local_inspection.dart';

/// Fine-grained upload progress for a single inspection's media queue.
/// Drives the per-card progress UI in the reports "Awaiting Upload" section.
@immutable
class MediaUploadProgress {
  /// Total media files queued for this inspection.
  final int total;

  /// Files successfully uploaded so far.
  final int uploaded;

  /// Files that failed their last attempt.
  final int failed;

  /// True while an upload pass is actively running for this inspection.
  final bool isUploading;

  const MediaUploadProgress({
    this.total = 0,
    this.uploaded = 0,
    this.failed = 0,
    this.isUploading = false,
  });

  double get fraction => total == 0 ? 0 : (uploaded / total).clamp(0.0, 1.0);
  bool get isComplete => total > 0 && uploaded >= total;
  int get remaining => (total - uploaded).clamp(0, total);

  MediaUploadProgress copyWith({
    int? total,
    int? uploaded,
    int? failed,
    bool? isUploading,
  }) {
    return MediaUploadProgress(
      total: total ?? this.total,
      uploaded: uploaded ?? this.uploaded,
      failed: failed ?? this.failed,
      isUploading: isUploading ?? this.isUploading,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaUploadProgress &&
      other.total == total &&
      other.uploaded == uploaded &&
      other.failed == failed &&
      other.isUploading == isUploading;

  @override
  int get hashCode => Object.hash(total, uploaded, failed, isUploading);
}

/// Byte-level progress for the ONE media file currently being uploaded.
///
/// [MediaUploadProgress] counts whole files, which stands still for minutes
/// while a video transfers. This is what tells the inspector the difference
/// between a slow upload and a dead one.
@immutable
class MediaFileProgress {
  /// Bytes handed to the socket so far.
  final int sent;

  /// Total bytes in the request body (slightly larger than the file itself:
  /// multipart headers and boundaries are included).
  final int total;

  /// Smoothed transfer rate in bytes per second. 0 until two samples exist.
  final double bytesPerSecond;

  const MediaFileProgress({
    required this.sent,
    required this.total,
    this.bytesPerSecond = 0,
  });

  double get fraction => total <= 0 ? 0 : (sent / total).clamp(0.0, 1.0);

  /// Seconds left at the current rate, or null when it cannot be estimated.
  /// Never shown as a countdown the inspector can hold us to — it is a hint
  /// that bytes are still moving.
  Duration? get eta {
    if (bytesPerSecond <= 0 || total <= 0 || sent >= total) return null;
    final secs = (total - sent) / bytesPerSecond;
    if (!secs.isFinite || secs < 0 || secs > 60 * 60 * 6) return null;
    return Duration(seconds: secs.round());
  }

  MediaFileProgress copyWith({int? sent, int? total, double? bytesPerSecond}) {
    return MediaFileProgress(
      sent: sent ?? this.sent,
      total: total ?? this.total,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaFileProgress &&
      other.sent == sent &&
      other.total == total &&
      other.bytesPerSecond == bytesPerSecond;

  @override
  int get hashCode => Object.hash(sent, total, bytesPerSecond);
}

class InspectionState {
  final List<LocalInspection> inspections;
  final bool isLoading;
  final bool refreshCooldown;
  final bool isDirty;
  final Map<String, bool> submittingStates;
  final Map<String, bool> uploadingImagesStates;

  /// Inspections that have media awaiting upload (the "Awaiting Upload"
  /// section). Includes both interrupted in-progress inspections and
  /// offline-submitted ones with leftover media.
  final List<LocalInspection> mediaQueue;

  /// Per-inspection media upload progress, keyed by [LocalInspection.id].
  final Map<String, MediaUploadProgress> mediaProgress;

  /// Byte-level progress for files currently in flight, keyed by
  /// `'<inspection id>/<pendingMedia key>'`. An entry exists only while its
  /// file is transferring; it is removed the moment the file settles, so a
  /// stale bar can never outlive its upload.
  final Map<String, MediaFileProgress> mediaFileProgress;

  const InspectionState({
    this.inspections = const [],
    this.isLoading = false,
    this.refreshCooldown = false,
    this.isDirty = true,
    this.submittingStates = const {},
    this.uploadingImagesStates = const {},
    this.mediaQueue = const [],
    this.mediaProgress = const {},
    this.mediaFileProgress = const {},
  });

  InspectionState copyWith({
    List<LocalInspection>? inspections,
    bool? isLoading,
    bool? refreshCooldown,
    bool? isDirty,
    Map<String, bool>? submittingStates,
    Map<String, bool>? uploadingImagesStates,
    List<LocalInspection>? mediaQueue,
    Map<String, MediaUploadProgress>? mediaProgress,
    Map<String, MediaFileProgress>? mediaFileProgress,
  }) {
    return InspectionState(
      inspections: inspections ?? this.inspections,
      isLoading: isLoading ?? this.isLoading,
      refreshCooldown: refreshCooldown ?? this.refreshCooldown,
      isDirty: isDirty ?? this.isDirty,
      submittingStates: submittingStates ?? this.submittingStates,
      uploadingImagesStates:
          uploadingImagesStates ?? this.uploadingImagesStates,
      mediaQueue: mediaQueue ?? this.mediaQueue,
      mediaProgress: mediaProgress ?? this.mediaProgress,
      mediaFileProgress: mediaFileProgress ?? this.mediaFileProgress,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is InspectionState &&
        listEquals(other.inspections, inspections) &&
        other.isLoading == isLoading &&
        other.refreshCooldown == refreshCooldown &&
        other.isDirty == isDirty &&
        mapEquals(other.submittingStates, submittingStates) &&
        mapEquals(other.uploadingImagesStates, uploadingImagesStates) &&
        listEquals(other.mediaQueue, mediaQueue) &&
        mapEquals(other.mediaProgress, mediaProgress) &&
        mapEquals(other.mediaFileProgress, mediaFileProgress);
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(inspections),
        isLoading,
        refreshCooldown,
        isDirty,
        Object.hashAll(
          submittingStates.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(
          uploadingImagesStates.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(mediaQueue),
        Object.hashAll(
          mediaProgress.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(
          mediaFileProgress.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );
}
