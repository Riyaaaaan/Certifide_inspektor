import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/inspection_state.dart';
import '../models/local_inspection.dart';
import '../models/pending_media.dart';
import '../services/api_services.dart';
import '../services/local_storage_services.dart';
import '../utils/connectivity_checker.dart';
import 'connectivity_provider.dart';

part 'inspection_provider.g.dart';

@Riverpod(keepAlive: true)
class InspectionNotifier extends _$InspectionNotifier {
  Timer? _cooldownTimer;
  bool _isAutoSubmitting = false;
  bool _isSyncingMedia = false;

  /// Per-container locks so the connectivity-driven [syncPendingMedia] and the
  /// manual [uploadInspectionMedia] never process the same queue container
  /// concurrently (which would double-upload its files).
  final Set<String> _uploadingContainerIds = {};

  @override
  InspectionState build() {
    ref.onDispose(() {
      _cooldownTimer?.cancel();
    });
    // React to the app-wide connectivity source instead of owning a second
    // subscription: when it flips offline -> online (debounce + reachability
    // probe already done there), drain everything queued while offline.
    ref.listen(connectivityStatusProvider, (previous, next) {
      if (next == true && previous != true) {
        // Provider listeners must stay synchronous; async work is scheduled via
        // unawaited() and all errors are caught explicitly inside.
        unawaited(Future(() async {
          try {
            // First drain the media-only upload queue (uploads each file and
            // replays save-step, keeping the inspection resumable), replay any
            // answer-only fields edited offline, then submit any inspections
            // that were fully completed while offline.
            await syncPendingMedia();
            await syncPendingSaveSteps();
            await _autoSubmitPending();
          } catch (e) {
            log('Connectivity sync error: $e');
          }
        }));
      }
    });
    return const InspectionState();
  }

  Future<void> _autoSubmitPending() async {
    if (_isAutoSubmitting) return;
    _isAutoSubmitting = true;
    try {
      final pending = await LocalStorageService.getPendingInspections();
      if (pending.isEmpty) return;
      for (final inspection in pending) {
        if (!(state.submittingStates[inspection.id] ?? false)) {
          await retrySubmission(inspection);
        }
      }
      state = state.copyWith(isDirty: true);
    } catch (e) {
      log('Error auto-submitting pending inspections: $e');
    } finally {
      _isAutoSubmitting = false;
    }
  }

  void _startRefreshCooldown() {
    _cooldownTimer?.cancel();
    state = state.copyWith(refreshCooldown: true);
    _cooldownTimer = Timer(const Duration(seconds: 10), () {
      state = state.copyWith(refreshCooldown: false);
    });
  }

  Future<void> loadInspections() async {
    if (state.isLoading || state.refreshCooldown || !state.isDirty) return;

    _startRefreshCooldown();
    state = state.copyWith(isLoading: true);

    try {
      final inspections = await LocalStorageService.getPendingInspections();
      inspections.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      // Merge (don't clobber) progress maps so an in-flight upload's flags
      // survive a reload triggered mid-sync.
      final submitting = {
        for (var i in inspections) i.id: state.submittingStates[i.id] ?? false,
      };
      final uploading = {
        for (var i in inspections)
          i.id: state.uploadingImagesStates[i.id] ?? false,
      };

      state = state.copyWith(
        inspections: inspections,
        isDirty: false,
        isLoading: false,
        submittingStates: submitting,
        uploadingImagesStates: uploading,
      );

      await _reloadMediaQueue();

      final hasInternet = await ConnectivityChecker.canReachServer();
      if (hasInternet) {
        await syncPendingImages();
        await syncPendingMedia();
        await syncPendingSaveSteps();
      }
    } catch (e) {
      log('Error loading inspections: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Reloads the "awaiting upload" media queue from local storage and tries to
  /// sync it. Not gated by the refresh cooldown, so the Pending tab reflects a
  /// just-closed inspection immediately.
  Future<void> refreshMediaQueue() async {
    await _reloadMediaQueue();
    await syncPendingMedia();
  }

  /// Refreshes the "awaiting upload" media queue from local storage, pruning
  /// progress entries for inspections that have fully drained.
  Future<void> _reloadMediaQueue() async {
    var queue = await LocalStorageService.getInspectionsWithPendingMedia();

    // A pass killed mid-upload (force-close, OS reclaim, crash) leaves its
    // entries at "uploading" forever: nothing else ever writes that status
    // back, and the queue picks work by isUploaded, so the file was silently
    // waiting for a retry while the Pending tab showed a live-looking
    // "Uploading..." row for it. Reset any entry no running pass owns.
    var resetStale = false;
    for (final c in queue) {
      if (_uploadingContainerIds.contains(c.id)) continue;
      for (final e in c.pendingMedia.entries) {
        if (e.value.uploadStatus != PendingMediaStatus.uploading) continue;
        await LocalStorageService.setPendingMediaStatus(
          inspectionId: c.id,
          key: e.key,
          status: PendingMediaStatus.queued,
        );
        resetStale = true;
      }
    }
    if (resetStale) {
      queue = await LocalStorageService.getInspectionsWithPendingMedia();
    }

    queue.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final ids = queue.map((e) => e.id).toSet();
    final prunedProgress = {
      for (final e in state.mediaProgress.entries)
        if (ids.contains(e.key)) e.key: e.value,
    };
    state = state.copyWith(mediaQueue: queue, mediaProgress: prunedProgress);
  }

  /// Wall-clock sample of the last progress event per in-flight file, used to
  /// derive a rate and to throttle. Not in [state]: it is bookkeeping, and
  /// putting it there would rebuild the UI on every 64 KB chunk.
  final Map<String, ({DateTime at, int sent})> _fileProgressSamples = {};

  /// Files whose upload this pass still owns. A timed-out request is abandoned
  /// by [ApiService.uploadImage] but its body keeps draining for a moment
  /// afterwards, so without this a late chunk could re-publish a bar for a file
  /// that has already been settled and cleared.
  final Set<String> _inFlightFileKeys = {};

  /// How often a transferring file is allowed to push a new frame. Chunks
  /// arrive every few milliseconds on a fast link; at that rate the rebuilds
  /// cost more than the upload.
  static const Duration _progressFrame = Duration(milliseconds: 400);

  /// Silence with no bytes for this long counts as stalled rather than slow.
  /// Long enough that a normal pause between chunks on a weak signal does not
  /// trip it, short enough to beat the 10-minute upload timeout by a mile.
  static const Duration _stallAfter = Duration(seconds: 4);

  /// Records byte progress for one queued file and publishes a smoothed rate.
  ///
  /// Called from [ApiService.uploadImage] on every streamed chunk, so it must
  /// stay cheap and must throttle before touching [state].
  void _reportFileProgress(String id, String key, int sent, int total) {
    // Before anything touches `state`: reading it on a disposed notifier
    // throws, and this runs inside the request body stream, so the throw would
    // surface as a failed upload and mark a healthy file as failed.
    if (!ref.mounted) return;
    final mapKey = '$id/$key';
    if (!_inFlightFileKeys.contains(mapKey)) return;
    final now = DateTime.now();
    final previous = _fileProgressSamples[mapKey];
    final complete = total > 0 && sent >= total;

    if (previous != null &&
        !complete &&
        now.difference(previous.at) < _progressFrame) {
      return;
    }

    double rate = state.mediaFileProgress[mapKey]?.bytesPerSecond ?? 0;
    if (previous != null) {
      final seconds = now.difference(previous.at).inMicroseconds / 1000000;
      final delta = sent - previous.sent;
      if (seconds > 0 && delta >= 0) {
        final sample = delta / seconds;
        // Exponential smoothing: a raw per-frame rate on mobile data jumps
        // between 0 and several MB/s and reads as noise.
        rate = rate <= 0 ? sample : (rate * 0.7) + (sample * 0.3);
      }
    }

    _fileProgressSamples[mapKey] = (at: now, sent: sent);
    state = state.copyWith(
      mediaFileProgress: {
        ...state.mediaFileProgress,
        mapKey: MediaFileProgress(sent: sent, total: total, bytesPerSecond: rate),
      },
    );
  }

  /// Drops a file's byte progress once it settles, so the row falls back to its
  /// uploaded/failed status instead of freezing at whatever fraction it
  /// reached.
  void _clearFileProgress(String id, String key) {
    final mapKey = '$id/$key';
    _inFlightFileKeys.remove(mapKey);
    _fileProgressSamples.remove(mapKey);
    if (!ref.mounted) return;
    if (!state.mediaFileProgress.containsKey(mapKey)) return;
    state = state.copyWith(
      mediaFileProgress: {...state.mediaFileProgress}..remove(mapKey),
    );
  }

  /// Zeroes the rate of any in-flight file that has not moved for
  /// [_stallAfter], so the row stops advertising a speed and an ETA.
  ///
  /// Progress is chunk-driven: when a transfer stalls, no callback fires at
  /// all, so the last good "1.8 MB/s, 41s left" would otherwise sit on screen
  /// claiming the upload is healthy right up to the 10-minute timeout. This
  /// tick is the only thing that can tell the difference between slow and
  /// stopped.
  void _tickStalledProgress(String id) {
    if (!ref.mounted) return;
    final now = DateTime.now();
    final prefix = '$id/';
    var next = state.mediaFileProgress;
    var changed = false;

    for (final mapKey in _inFlightFileKeys) {
      if (!mapKey.startsWith(prefix)) continue;
      final current = next[mapKey];
      final sample = _fileProgressSamples[mapKey];
      if (current == null || sample == null) continue;
      if (current.bytesPerSecond <= 0) continue;
      if (now.difference(sample.at) < _stallAfter) continue;
      next = {...next, mapKey: current.copyWith(bytesPerSecond: 0)};
      changed = true;
    }

    if (changed) state = state.copyWith(mediaFileProgress: next);
  }

  void _setMediaProgress(String id, MediaUploadProgress progress) {
    state = state.copyWith(
      mediaProgress: {...state.mediaProgress, id: progress},
    );
  }

  /// Re-reads one queue container and replaces it in [InspectionState.mediaQueue]
  /// so the per-file upload status (queued/uploading/uploaded/failed) shown in
  /// the Pending tab updates live as each file is processed.
  Future<void> _patchContainerInState(String id) async {
    final updated = await LocalStorageService.getMediaQueueById(id);
    if (updated == null) {
      if (state.mediaQueue.any((c) => c.id == id)) {
        state = state.copyWith(
          mediaQueue: state.mediaQueue.where((c) => c.id != id).toList(),
        );
      }
      return;
    }
    final list = state.mediaQueue.toList();
    final idx = list.indexWhere((c) => c.id == id);
    if (idx >= 0) {
      list[idx] = updated;
    } else {
      list.insert(0, updated);
    }
    state = state.copyWith(mediaQueue: list);
  }

  /// Re-reads one container AND updates its progress entry in a SINGLE state
  /// mutation. Equivalent to [_patchContainerInState] + [_setMediaProgress]
  /// back-to-back, but with one notify/equality pass instead of two — called
  /// once per file in the upload loop, so this halves that per-file cost.
  Future<void> _patchContainerAndProgress(
      String id, MediaUploadProgress progress) async {
    final updated = await LocalStorageService.getMediaQueueById(id);
    final newProgress = {...state.mediaProgress, id: progress};
    if (updated == null) {
      state = state.copyWith(
        mediaQueue: state.mediaQueue.where((c) => c.id != id).toList(),
        mediaProgress: newProgress,
      );
      return;
    }
    final list = state.mediaQueue.toList();
    final idx = list.indexWhere((c) => c.id == id);
    if (idx >= 0) {
      list[idx] = updated;
    } else {
      list.insert(0, updated);
    }
    state = state.copyWith(mediaQueue: list, mediaProgress: newProgress);
  }

  /// Uploads every queued media file (any type) for inspections that have
  /// pending media, WITHOUT submitting the inspection. Each uploaded file's URL
  /// is recorded and the field is re-saved server-side via save-step so the
  /// inspection stays resumable with its media already on the server.
  Future<void> syncPendingMedia() async {
    if (_isSyncingMedia) return;
    _isSyncingMedia = true;
    try {
      final hasInternet = await ConnectivityChecker.canReachServer();
      if (!hasInternet) return;

      final containers =
          await LocalStorageService.getInspectionsWithPendingMedia();
      // Surface in-flight containers as live cards BEFORE uploading so their
      // progress spinner is visible during an auto-sync.
      await _reloadMediaQueue();
      for (final container in containers) {
        await _uploadContainerMedia(container.id);
      }
      await _reloadMediaQueue();
    } catch (e) {
      log('Error syncing pending media: $e');
    } finally {
      _isSyncingMedia = false;
    }
  }

  /// Replays answer-only save-steps (values/options/remarks edited offline on
  /// media-less fields) for every queue container that has them, then clears
  /// each one on success. Media-bearing fields are NOT touched here — their
  /// save-step is replayed by [_uploadContainerMedia] after upload, so this
  /// only handles the answers that would otherwise never reach the server.
  Future<void> syncPendingSaveSteps() async {
    try {
      final hasInternet = await ConnectivityChecker.canReachServer();
      if (!hasInternet) return;

      final containers =
          await LocalStorageService.getInspectionsWithPendingSaveSteps();
      for (final container in containers) {
        final serverId = container.serverInspectionId;
        final steps = (container.data['pendingAnswerSteps'] as Map?)
                ?.cast<String, dynamic>() ??
            const <String, dynamic>{};
        // Iterate a snapshot — removeAnswerStepFor mutates the stored container.
        for (final entry in steps.entries.toList()) {
          final fieldKey = entry.key;
          final desc = entry.value;
          final section =
              (desc is Map ? desc['section']?.toString() : null) ?? '';
          // Unusable descriptor (no server id / section) — drop it rather than
          // retry forever.
          if (serverId == null || desc is! Map || section.isEmpty) {
            await LocalStorageService.removeAnswerStepFor(
                container.id, fieldKey);
            continue;
          }
          final item = Map<String, dynamic>.from((desc['item'] as Map?) ?? {});
          // Never POST a local filesystem path; any media here is http or null.
          _stripLocalMediaPaths(item);
          try {
            final r = await ApiService.saveInspectionStep(
              serverId,
              section: section,
              items: [item],
            );
            if (r['success'] != false) {
              await LocalStorageService.removeAnswerStepFor(
                  container.id, fieldKey);
            }
          } catch (e) {
            log('Answer save-step replay error ($fieldKey): $e');
          }
        }
      }
      await _reloadMediaQueue();
    } catch (e) {
      log('Error syncing pending save-steps: $e');
    }
  }

  /// Manually triggers upload of a single inspection's queued media (the
  /// Pending-tab "Upload" button). Returns true if the queue fully drained.
  Future<bool> uploadInspectionMedia(LocalInspection container) async {
    final hasInternet = await ConnectivityChecker.canReachServer();
    if (!hasInternet) {
      // Seed progress from the container's real contents (not a 0/0 default).
      _setMediaProgress(
        container.id,
        MediaUploadProgress(
          total: container.pendingMedia.length,
          uploaded: container.pendingMedia.values.where((m) => m.isUploaded).length,
          isUploading: false,
        ),
      );
      return false;
    }
    await _uploadContainerMedia(container.id);
    await _reloadMediaQueue();
    final remaining =
        await LocalStorageService.getInspectionsWithPendingMedia();
    return !remaining.any((c) => c.id == container.id);
  }

  /// Uploads all not-yet-uploaded media for one queue container, then — only
  /// once EVERY entry of a field has uploaded — replays that field's save-step
  /// (with each media type substituted into its own slot and any non-http path
  /// stripped) and removes the field's entries (deleting their local files).
  ///
  /// Takes the container id and re-reads the record fresh from storage so
  /// per-entry status guards reflect concurrent passes. Guarded by a
  /// per-container lock so a manual upload can't race the auto-sync.
  Future<void> _uploadContainerMedia(String id) async {
    if (_uploadingContainerIds.contains(id)) return;
    _uploadingContainerIds.add(id);
    final stallTicker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickStalledProgress(id),
    );
    try {
      var container = await LocalStorageService.getMediaQueueById(id);
      if (container == null) return;
      final serverId = container.serverInspectionId;

      // Drop entries whose file is genuinely gone BEFORE counting or selecting
      // work. Such an entry can never upload, so leaving it queued retried it
      // on every reconnect AND blocked its field's save-step forever — a field
      // only replays once every one of its entries has uploaded, so one dead
      // file held back the rest of that field's media indefinitely.
      var droppedMissing = false;
      for (final e in container.pendingMedia.entries.toList()) {
        if (e.value.isUploaded) continue;
        final resolved =
            LocalStorageService.resolveMediaPath(e.value.localPath);
        if (!File(resolved).existsSync()) {
          log('Media queue: file missing for ${e.key} ($resolved); dropping.');
          await LocalStorageService.removePendingMedia(id, e.key,
              deleteLocalFile: false);
          droppedMissing = true;
        }
      }
      if (droppedMissing) {
        // Dropping the last entry deletes the container outright.
        final refreshed = await LocalStorageService.getMediaQueueById(id);
        if (refreshed == null) {
          _setMediaProgress(
            id,
            const MediaUploadProgress(total: 0, uploaded: 0, isUploading: false),
          );
          return;
        }
        container = refreshed;
      }

      int total = container.pendingMedia.length;
      int uploaded = container.pendingMedia.values.where((m) => m.isUploaded).length;
      int failed = 0;
      _setMediaProgress(
        id,
        MediaUploadProgress(total: total, uploaded: uploaded, isUploading: true),
      );

      // 1) Upload every not-yet-uploaded entry. Already-uploaded entries are
      //    kept (their save-step may still be pending) and replayed below.
      //
      //    The network upload (the slow part) runs in bounded-parallel chunks,
      //    but every Hive status write stays sequential: setPendingMediaStatus
      //    is a read-modify-write of the whole container, so concurrent writes
      //    on different keys would clobber each other (lost update).
      final pending = container.pendingMedia.entries
          .where((e) =>
              !(e.value.isUploaded && (e.value.uploadedUrl?.isNotEmpty ?? false)))
          .toList();

      // Photos first, then videos one at a time. A clip uploading beside other
      // files splits the link four ways, so nothing finished for minutes and
      // the card sat at "0 of 6" with every row reading "Uploading..." — a
      // working queue that looked hung. Photos take ~2s each, so front-loading
      // them moves the counter immediately, and a lone video then gets the
      // whole link instead of a quarter of it.
      const uploadConcurrency = 4;
      final photos = pending.where((e) => e.value.mediaType != 'video').toList();
      final videos = pending.where((e) => e.value.mediaType == 'video').toList();
      final batches = <List<MapEntry<String, PendingMedia>>>[
        for (var i = 0; i < photos.length; i += uploadConcurrency)
          photos.sublist(
              i,
              i + uploadConcurrency < photos.length
                  ? i + uploadConcurrency
                  : photos.length),
        for (final v in videos) [v],
      ];

      for (final chunk in batches) {
        // Mark only the files starting right now. Marking the whole batch
        // upfront made every row claim "Uploading..." while most were still
        // waiting their turn, which is indistinguishable from a hang.
        for (final entry in chunk) {
          await LocalStorageService.setPendingMediaStatus(
            inspectionId: id,
            key: entry.key,
            status: PendingMediaStatus.uploading,
          );
        }
        await _patchContainerInState(id);

        // Upload this chunk concurrently (no Hive writes here).
        final results = await Future.wait(chunk.map((entry) async {
          final media = entry.value;
          _inFlightFileKeys.add('$id/${entry.key}');
          final result = await ApiService.uploadImage(
            media.localPath,
            inspectionId: serverId,
            section: media.section,
            itemId: media.itemId,
            mediaType: media.mediaType,
            onProgress: (sent, total) =>
                _reportFileProgress(id, entry.key, sent, total),
          );
          _clearFileProgress(id, entry.key);
          return MapEntry(entry.key, result);
        }));

        // Apply each result's status sequentially (RMW-safe), patching after
        // every file so a row flips when its own upload lands rather than when
        // the slowest file beside it does.
        for (final r in results) {
          final url = r.value['url']?.toString();
          if (r.value['success'] == true && url != null && url.isNotEmpty) {
            await LocalStorageService.setPendingMediaStatus(
              inspectionId: id,
              key: r.key,
              status: PendingMediaStatus.uploaded,
              url: url,
            );
            uploaded++;
          } else {
            await LocalStorageService.setPendingMediaStatus(
              inspectionId: id,
              key: r.key,
              status: PendingMediaStatus.failed,
              error: r.value['message']?.toString(),
            );
            failed++;
          }

          await _patchContainerAndProgress(
            id,
            MediaUploadProgress(
              total: total,
              uploaded: uploaded,
              failed: failed,
              isUploading: true,
            ),
          );
        }
      }

      // 2) Re-read and group remaining entries by their form field.
      container = await LocalStorageService.getMediaQueueById(id) ?? container;
      final byField = <String, List<MapEntry<String, PendingMedia>>>{};
      for (final e in container.pendingMedia.entries) {
        byField.putIfAbsent(e.value.fieldKey, () => []).add(e);
      }

      // 3) Replay save-step ONLY for fields whose every entry has uploaded
      //    (so a multi-type / multi-image field is never sent half-local), then
      //    remove that field's entries.
      for (final fieldKey in byField.keys) {
        final entries = byField[fieldKey]!;
        final allUploaded = entries.every(
          (e) => e.value.isUploaded && (e.value.uploadedUrl?.isNotEmpty ?? false),
        );
        if (!allUploaded) continue;

        final desc = await LocalStorageService.getSaveStepFor(id, fieldKey);
        final section = desc?['section']?.toString() ?? '';

        bool persisted = false;
        if (serverId != null && desc != null && section.isNotEmpty) {
          final item = Map<String, dynamic>.from((desc['item'] as Map?) ?? {});
          _applyUrlsToSaveStepItem(item, entries.map((e) => e.value).toList());
          _stripLocalMediaPaths(item);
          try {
            final r = await ApiService.saveInspectionStep(
              serverId,
              section: section,
              items: [item],
            );
            persisted = r['success'] != false;
          } catch (e) {
            log('Media save-step replay error ($fieldKey): $e');
            persisted = false;
          }
        } else {
          // No usable save-step descriptor — the upload itself already carried
          // inspection_id/section/itemId, so drain rather than loop forever.
          if (section.isEmpty) {
            log('Media queue: empty section for field $fieldKey; draining.');
          }
          persisted = true;
        }

        if (persisted) {
          for (final e in entries) {
            // Keep the local file: the live working copy (current_inspection)
            // still references this path to display the image on resume, even
            // offline. Deleting it here orphaned the path and lost the image.
            // The file is cleaned when the inspection is finalised/discarded.
            await LocalStorageService.removePendingMedia(id, e.key,
                deleteLocalFile: false);
          }
        }
      }

      // 4) Final progress from the post-drain state.
      final after = await LocalStorageService.getMediaQueueById(id);
      if (after == null) {
        _setMediaProgress(
          id,
          MediaUploadProgress(total: total, uploaded: total, isUploading: false),
        );
      } else {
        _setMediaProgress(
          id,
          MediaUploadProgress(
            total: after.pendingMedia.length,
            uploaded: after.pendingMedia.values.where((m) => m.isUploaded).length,
            failed: after.pendingMedia.values
                .where((m) => m.uploadStatus == PendingMediaStatus.failed)
                .length,
            isUploading: false,
          ),
        );
      }
    } catch (e) {
      log('Error uploading container media ($id): $e');
    } finally {
      stallTicker.cancel();
      _uploadingContainerIds.remove(id);
      // Always clear a lingering spinner even if something threw mid-pass.
      final p = state.mediaProgress[id];
      if (p != null && p.isUploading) {
        _setMediaProgress(id, p.copyWith(isUploading: false));
      }
      // Same for a half-filled byte bar: a throw skips the per-file clear, and
      // a bar frozen at 40% is the exact thing this whole change exists to
      // stop showing.
      final prefix = '$id/';
      _inFlightFileKeys.removeWhere((k) => k.startsWith(prefix));
      _fileProgressSamples.removeWhere((k, _) => k.startsWith(prefix));
      if (state.mediaFileProgress.keys.any((k) => k.startsWith(prefix))) {
        state = state.copyWith(
          mediaFileProgress: {...state.mediaFileProgress}
            ..removeWhere((k, _) => k.startsWith(prefix)),
        );
      }
    }
  }

  /// Substitutes each uploaded entry's URL into its own slot of a save-step
  /// item (image/video/audio/file/multiImages), so a field that owns several
  /// media types gets all of them filled.
  void _applyUrlsToSaveStepItem(
    Map<String, dynamic> item,
    List<PendingMedia> entries,
  ) {
    final multiUrls = <String, String>{}; // localPath -> url
    for (final m in entries) {
      final url = m.uploadedUrl;
      if (url == null || url.isEmpty) continue;
      switch (m.mediaType) {
        case 'video':
          item['videoPath'] = url;
          break;
        case 'audio':
          item['audioPath'] = url;
          break;
        case 'file':
          item['filePath'] = url;
          break;
        case 'multiImage':
          multiUrls[m.localPath] = url;
          break;
        case 'image':
        default:
          item['imagePath'] = url;
          break;
      }
    }
    if (multiUrls.isNotEmpty) {
      final existing =
          (item['multiImages'] as List?)?.map((e) => e.toString()).toList();
      if (existing != null && existing.isNotEmpty) {
        // Preserve order; map local paths to URLs and keep only uploaded ones.
        item['multiImages'] = existing
            .map((p) => multiUrls[p] ?? p)
            .where((u) => u.startsWith('http'))
            .toList();
      } else {
        item['multiImages'] = multiUrls.values.toList();
      }
    }
  }

  /// Nulls out any single media slot still holding a local (non-http) path and
  /// filters multiImages to http URLs, so a local filesystem path is never
  /// POSTed to the server.
  void _stripLocalMediaPaths(Map<String, dynamic> item) {
    for (final k in const ['imagePath', 'videoPath', 'audioPath', 'filePath']) {
      final v = item[k];
      if (v is String && v.isNotEmpty && !v.startsWith('http')) item[k] = null;
    }
    final mi = item['multiImages'];
    if (mi is List) {
      item['multiImages'] =
          mi.map((e) => e.toString()).where((u) => u.startsWith('http')).toList();
    }
  }

  Future<void> syncPendingImages() async {
    try {
      final pending =
          await LocalStorageService.getInspectionsWithPendingImages();

      for (var inspection in pending) {
        if (inspection.pendingImages.isEmpty) continue;

        state = state.copyWith(
          uploadingImagesStates: {
            ...state.uploadingImagesStates,
            inspection.id: true,
          },
        );

        final uploadedImages = <String, String>{};

        for (var entry in inspection.pendingImages.entries) {
          final result = await ApiService.uploadImage(
            entry.value.imagePath,
            inspectionId: null,
            section: entry.value.section,
            itemId: entry.value.itemId,
          );

          final url = result['url'] as String?;
          if (result['success'] == true && url != null && url.isNotEmpty) {
            uploadedImages[entry.key] = url;
          }
        }

        if (uploadedImages.isNotEmpty) {
          await LocalStorageService.updateInspectionImages(
            inspectionId: inspection.id,
            uploadedImages: uploadedImages,
          );
        }

        state = state.copyWith(
          uploadingImagesStates: {
            ...state.uploadingImagesStates,
            inspection.id: false,
          },
        );
      }

      state = state.copyWith(isDirty: true);
      await loadInspections();
    } catch (e) {
      log('Error syncing pending images: $e');
    }
  }

  Future<bool> retrySubmission(LocalInspection inspection) async {
    if (state.submittingStates[inspection.id] ?? false) return false;

    state = state.copyWith(
      submittingStates: {...state.submittingStates, inspection.id: true},
    );

    try {
      final hasInternet = await ConnectivityChecker.canReachServer();
      if (!hasInternet) {
        state = state.copyWith(
          submittingStates: {...state.submittingStates, inspection.id: false},
        );
        return false;
      }

      var currentInspection = inspection;

      // Tracks whether any media failed to upload this pass. If so we must NOT
      // submit — the stored body still holds local file paths for those items
      // and the server would reject them (or store an empty field). Mirrors the
      // abort-on-failure guard the online submit path uses.
      bool anyUploadFailed = false;

      // Recover each item key -> server field id from the stored body so media
      // uploaded on retry is tagged with the same itemId the online path sends.
      // Falls back to the item key for legacy records saved before fieldId was
      // persisted. (Images already carry their fieldId via PendingImage.itemId.)
      final fieldIdByKey = <String, String>{};
      final storedData = currentInspection.data['inspection_data'];
      if (storedData is Map<String, dynamic>) {
        for (final section in storedData.values) {
          if (section is Map<String, dynamic>) {
            final items = section['items'];
            if (items is List) {
              for (final item in items) {
                if (item is Map<String, dynamic> && item['id'] != null) {
                  final fid = item['fieldId'];
                  if (fid != null && fid.toString().isNotEmpty) {
                    fieldIdByKey[item['id'].toString()] = fid.toString();
                  }
                }
              }
            }
          }
        }
      }

      // Upload pending images
      if (inspection.pendingImages.isNotEmpty) {
        state = state.copyWith(
          uploadingImagesStates: {
            ...state.uploadingImagesStates,
            inspection.id: true,
          },
        );

        final uploadedImages = <String, String>{};

        for (var entry in inspection.pendingImages.entries) {
          final result = await ApiService.uploadImage(
            entry.value.imagePath,
            inspectionId: null,
            section: entry.value.section,
            itemId: entry.value.itemId,
          );
          final url = result['url'] as String?;
          if (result['success'] == true && url != null && url.isNotEmpty) {
            uploadedImages[entry.key] = url;
          } else {
            anyUploadFailed = true;
          }
        }

        if (uploadedImages.isNotEmpty) {
          await LocalStorageService.updateInspectionImages(
            inspectionId: inspection.id,
            uploadedImages: uploadedImages,
          );
          final updated = await LocalStorageService.getPendingInspections();
          currentInspection = updated.firstWhere(
            (i) => i.id == inspection.id,
            orElse: () => currentInspection,
          );
        }

        state = state.copyWith(
          uploadingImagesStates: {
            ...state.uploadingImagesStates,
            inspection.id: false,
          },
        );
      }

      // Upload local videos, audios, and files.
      // Maps: fieldId -> uploadedUrl (for in-data replacement).
      final videoReplacements = <String, String>{};
      final audioReplacements = <String, String>{};
      final fileReplacements = <String, String>{};

      // The endpoint rejects a blank `section` ("The section field is
      // required."), so recover each field's section title from the stored
      // body and skip any field we can't place rather than burning an upload
      // on a request the server will refuse.
      final sectionTitles = sectionTitlesByFieldId(currentInspection.data);
      final rawId = currentInspection.data['inspection_id'];
      final int? uploadInspectionId =
          rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');

      // `itemKey` is the local map key (item['id']); both the section titles and
      // fieldIdByKey are keyed by it. The upload itself must be tagged with the
      // server field id, otherwise the server can't place the media.
      Future<String?> uploadMedia(
          String path, String itemKey, String mediaType) async {
        final section = sectionTitles[itemKey] ?? '';
        if (section.isEmpty) {
          log('Retry upload: no section for field $itemKey; skipping.');
          return null;
        }
        final result = await ApiService.uploadImage(
          path,
          inspectionId: uploadInspectionId,
          section: section,
          itemId: fieldIdByKey[itemKey] ?? itemKey,
          fieldName: 'image',
          mediaType: mediaType,
        );
        final url = result['url'] as String?;
        if (result['success'] == true && url != null && url.isNotEmpty) {
          return url;
        }
        log('Retry upload failed ($itemKey): ${result['message']}');
        return null;
      }

      for (var entry in currentInspection.videos.entries) {
        if (!entry.value.startsWith('http')) {
          final url = await uploadMedia(entry.value, entry.key, 'video');
          if (url != null) {
            videoReplacements[entry.key] = url;
          } else {
            anyUploadFailed = true;
          }
        }
      }

      for (var entry in currentInspection.audios.entries) {
        if (!entry.value.startsWith('http')) {
          final url = await uploadMedia(entry.value, entry.key, 'audio');
          if (url != null) {
            audioReplacements[entry.key] = url;
          } else {
            anyUploadFailed = true;
          }
        }
      }

      for (var entry in currentInspection.files.entries) {
        if (!entry.value.startsWith('http')) {
          final url = await uploadMedia(entry.value, entry.key, 'file');
          if (url != null) {
            fileReplacements[entry.key] = url;
          } else {
            anyUploadFailed = true;
          }
        }
      }

      // Upload local multi-images (each local path in the list -> URL).
      final multiImageReplacements = <String, List<String>>{};
      for (var entry in currentInspection.multiImages.entries) {
        final newList = <String>[];
        bool changed = false;
        for (final p in entry.value) {
          if (p.startsWith('http')) {
            newList.add(p);
            continue;
          }
          final url = await uploadMedia(p, entry.key, 'multiImage');
          if (url != null) {
            newList.add(url);
            changed = true;
          } else {
            newList.add(p);
            anyUploadFailed = true;
          }
        }
        if (changed) multiImageReplacements[entry.key] = newList;
      }

      // Persist uploaded media URLs to local storage
      if (videoReplacements.isNotEmpty ||
          audioReplacements.isNotEmpty ||
          fileReplacements.isNotEmpty ||
          multiImageReplacements.isNotEmpty) {
        // Replacement maps are already keyed by the item key (the same key the
        // videos/audios/files maps use), which is exactly what
        // updateInspectionMedia's addAll expects. Looking these up by local
        // path instead silently produced empty maps, so a successful upload was
        // discarded and the next retry re-sent the whole file.
        await LocalStorageService.updateInspectionMedia(
          inspectionId: inspection.id,
          uploadedVideos: videoReplacements,
          uploadedAudios: audioReplacements,
          uploadedFiles: fileReplacements,
          uploadedMultiImages: multiImageReplacements,
        );
      }

      // At least one upload failed: keep the successfully-uploaded URLs we just
      // persisted, but do NOT submit. The body still references local paths for
      // the failed items, so submitting now would POST paths the server can't
      // resolve — the exact failure that left media "stored locally only".
      // Leave the record pending so a later retry finishes the remaining media.
      if (anyUploadFailed) {
        state = state.copyWith(
          submittingStates: {...state.submittingStates, inspection.id: false},
        );
        return false;
      }

      // Build final submission payload with all uploaded URLs applied.
      // Deep-copy so mutations to nested item maps don't affect Riverpod state.
      // A manual clone avoids the encode-to-string + parse round trip that
      // json.decode(json.encode(...)) pays on the UI thread for a large map.
      final inspectionData =
          _deepCopyJson(currentInspection.data) as Map<String, dynamic>;
      final itemIndex = <String, Map<String, dynamic>>{};
      List<dynamic>? summaryImages;

      final inspDataRaw = inspectionData['inspection_data'];
      if (inspDataRaw is Map<String, dynamic>) {
        for (final section in inspDataRaw.values) {
          if (section is Map<String, dynamic>) {
            final items = section['items'];
            if (items is List) {
              for (final item in items) {
                if (item is Map<String, dynamic> && item['id'] != null) {
                  itemIndex[item['id'].toString()] = item;
                }
              }
            }
          }
        }
      }
      final summaryRaw = inspectionData['summaryImages'];
      if (summaryRaw is List) summaryImages = summaryRaw;

      for (var entry in currentInspection.images.entries) {
        if (!entry.value.startsWith('http')) continue;
        final item = itemIndex[entry.key];
        if (item != null) {
          item['imagePath'] = entry.value;
          if (item['multiImages'] is List) {
            for (final img in item['multiImages'] as List<dynamic>) {
              if (img is Map<String, dynamic> && img.containsKey('imagePath')) {
                final p = img['imagePath'];
                if (p is String && !p.startsWith('http')) img['imagePath'] = entry.value;
              }
            }
          }
        }
        if (summaryImages != null) {
          for (final img in summaryImages) {
            if (img is Map<String, dynamic> && img['key'] == entry.key) {
              img['imagePath'] = entry.value;
            }
          }
        }
      }
      for (var entry in videoReplacements.entries) {
        itemIndex[entry.key]?['videoPath'] = entry.value;
      }
      for (var entry in audioReplacements.entries) {
        itemIndex[entry.key]?['audioPath'] = entry.value;
      }
      for (var entry in fileReplacements.entries) {
        itemIndex[entry.key]?['filePath'] = entry.value;
      }
      for (var entry in multiImageReplacements.entries) {
        final item = itemIndex[entry.key];
        if (item != null) {
          item['multiImages'] =
              entry.value.map((u) => {'imagePath': u}).toList();
        }
      }

      // Finalise the existing server draft by id when the stored body carries
      // one (it was initialized online before going offline), so reconnecting
      // never creates a duplicate. When there is no server id (the inspection was
      // created entirely offline and never initialized), initialize a draft now
      // to mint one, then finalise that — the legacy all-at-once create endpoint
      // is no longer used.
      final rawServerId = inspectionData['inspection_id'];
      int? serverId = rawServerId is int
          ? rawServerId
          : int.tryParse(rawServerId?.toString() ?? '');
      if (serverId == null) {
        serverId = await _initializeDraftForOfflineBody(inspectionData);
        if (serverId == null) {
          // Could not mint a server id (missing brand/model or network) — keep
          // the record for a later retry instead of dropping it.
          state = state.copyWith(
            submittingStates: {...state.submittingStates, inspection.id: false},
          );
          return false;
        }
        inspectionData['inspection_id'] = serverId;
      }
      final result =
          await ApiService.submitInspectionById(serverId, inspectionData);

      if (result['success'] == true) {
        await LocalStorageService.markInspectionAsSubmitted(inspection.id);
        final updatedList = state.inspections
            .where((i) => i.id != inspection.id)
            .toList();
        final updatedSubmitting =
            Map<String, bool>.from(state.submittingStates)
              ..remove(inspection.id);
        final updatedUploading =
            Map<String, bool>.from(state.uploadingImagesStates)
              ..remove(inspection.id);
        state = state.copyWith(
          inspections: updatedList,
          submittingStates: updatedSubmitting,
          uploadingImagesStates: updatedUploading,
        );
        return true;
      } else {
        state = state.copyWith(
          submittingStates: {
            ...state.submittingStates,
            inspection.id: false,
          },
        );
        return false;
      }
    } catch (e) {
      log('Error submitting inspection ${inspection.id}: $e');
      state = state.copyWith(
        submittingStates: {...state.submittingStates, inspection.id: false},
      );
      return false;
    }
  }

  /// Mints a server draft for an offline-created inspection that never had an
  /// `inspection_id`, using the brand/model (and any vehicle details) carried in
  /// its stored submission body. Returns the new id, or null when the body lacks
  /// brand/model or initialize fails — the caller keeps the record for retry.
  Future<int?> _initializeDraftForOfflineBody(
      Map<String, dynamic> inspectionData) async {
    int? asInt(dynamic v) =>
        v is int ? v : int.tryParse(v?.toString() ?? '');
    final brandId = asInt(inspectionData['vehicle_brand_id']);
    final modelId = asInt(inspectionData['vehicle_model_id']);
    if (brandId == null || modelId == null) {
      log('Offline drain: missing brand/model id — cannot initialize draft');
      return null;
    }
    String? str(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    try {
      final result = await ApiService.initializeInspection(
        vehicleBrandId: brandId,
        vehicleModelId: modelId,
        year: str(inspectionData['year']),
        variant: str(inspectionData['variant']),
        colour: str(inspectionData['color']),
        transmission: str(inspectionData['transmission']),
        regNo: str(inspectionData['registration_number']),
      );
      if (result['success'] == true) {
        return asInt(result['inspection_id']);
      }
      log('Offline drain: initialize failed — ${result['message']}');
    } catch (e) {
      log('Offline drain: initialize exception — $e');
    }
    return null;
  }

  Future<void> deleteInspection(String id) async {
    if (state.isLoading || (state.submittingStates[id] ?? false)) return;

    state = state.copyWith(isLoading: true);
    try {
      await LocalStorageService.deleteInspection(id);
      state = state.copyWith(isDirty: true, isLoading: false);
      await loadInspections();
    } catch (e) {
      log('Error deleting inspection: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  void markDirty() {
    state = state.copyWith(isDirty: true);
  }

}

/// Maps every field id in a stored submission body to its section *title*.
///
/// The upload endpoint validates `section` as `required|string`, and the
/// per-field media maps ([LocalInspection.videos] and friends) only carry the
/// field id — the section is recoverable solely from the stored body, whose
/// `inspection_data` holds `{sectionSlug: {title, items:[{id, ...}]}}`.
/// Field id and unique id are the same value in both item shapes, so an item's
/// `id` is what the endpoint wants as `itemId`.
///
/// Tolerates a partial or malformed body by omitting whatever it can't read:
/// callers skip fields with no section rather than sending a request the
/// server will reject.
Map<String, String> sectionTitlesByFieldId(Map<String, dynamic> data) {
  final titles = <String, String>{};
  final inspData = data['inspection_data'];
  if (inspData is! Map) return titles;
  for (final section in inspData.values) {
    if (section is! Map) continue;
    final title = section['title']?.toString() ?? '';
    if (title.isEmpty) continue;
    final items = section['items'];
    if (items is! List) continue;
    for (final item in items) {
      if (item is Map && item['id'] != null) {
        titles[item['id'].toString()] = title;
      }
    }
  }
  return titles;
}

/// Recursively deep-copies a JSON-shaped value (Maps and Lists). Primitives
/// (String, num, bool, null) are immutable so they are shared as-is. Cheaper
/// than json.decode(json.encode(...)) because it skips the string round trip.
dynamic _deepCopyJson(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _deepCopyJson(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _deepCopyJson(item)];
  }
  return value;
}
