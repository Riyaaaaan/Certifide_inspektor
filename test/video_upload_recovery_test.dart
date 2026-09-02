// Guards the video/media upload path: routing metadata, size and error
// handling, URL persistence, and crash-resume through the durable queue.
//
// Every failure these cover was observed in production. The server log showed
// repeated "The section field is required." (offline retry sent a blank
// section) alongside "The image failed to upload." (a transfer that never
// completed). The rest protect the recovery path that turns such a failure
// into a retry instead of a lost recording.
//
// Pure Hive + filesystem: no network, no path_provider.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:certifide_inspektor/models/local_inspection.dart';
import 'package:certifide_inspektor/models/pending_image.dart';
import 'package:certifide_inspektor/models/pending_media.dart';
import 'package:certifide_inspektor/providers/inspection_provider.dart';
import 'package:certifide_inspektor/services/api_services.dart';
import 'package:certifide_inspektor/services/local_storage_services.dart';
import 'package:certifide_inspektor/widgets/section_video_camera_card_controller.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('video_upload_recovery_test');
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(LocalInspectionAdapter());
    }
    if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(PendingImageAdapter());
    if (!Hive.isAdapterRegistered(5)) Hive.registerAdapter(PendingMediaAdapter());
  });

  setUp(() async {
    await (await Hive.openLazyBox<LocalInspection>(
            LocalStorageService.INSPECTIONS_BOX))
        .clear();
    await (await Hive.openBox(LocalStorageService.INSPECTIONS_INDEX_BOX))
        .clear();
  });

  tearDownAll(() async {
    await Hive.close();
    tmp.deleteSync(recursive: true);
  });

  File makeFile(String name, [List<int> bytes = const [1, 2, 3]]) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  // ---------------------------------------------------------------------------
  group('sectionTitlesByFieldId — the blank-section regression', () {
    // The upload endpoint validates `section` as required|string. Offline retry
    // used to send '', so every queued video was rejected before it uploaded.
    Map<String, dynamic> body() => {
          'inspection_id': 42,
          'inspection_data': {
            'engine_bay': {
              'title': 'Engine Bay',
              'items': [
                {'id': 'engine_video', 'title': 'Engine running'},
                {'id': 'engine_photo', 'title': 'Engine photo'},
              ],
            },
            'test_drive': {
              'title': 'Test Drive',
              'items': [
                {'id': 'drive_video', 'title': 'Drive clip'},
              ],
            },
          },
        };

    test(
        'Given a stored submission body, When mapping fields, Then every field '
        'resolves to its own section title', () {
      final titles = sectionTitlesByFieldId(body());

      expect(titles['engine_video'], 'Engine Bay');
      expect(titles['engine_photo'], 'Engine Bay');
      expect(titles['drive_video'], 'Test Drive');
      expect(titles, hasLength(3));
    });

    test(
        'Given a resolved section, When used as the upload section, Then it is '
        'non-empty so the server rule passes', () {
      final titles = sectionTitlesByFieldId(body());
      for (final fieldId in titles.keys) {
        expect(titles[fieldId], isNotEmpty,
            reason: 'a blank section is rejected: "The section field is '
                'required."');
      }
    });

    test(
        'Given a body with no inspection_data, When mapping, Then it returns '
        'empty instead of throwing', () {
      expect(sectionTitlesByFieldId(const {}), isEmpty);
      expect(sectionTitlesByFieldId(const {'inspection_data': 'garbage'}),
          isEmpty);
    });

    test(
        'Given a section missing its title, When mapping, Then its fields are '
        'omitted so the caller skips them rather than sending a blank section',
        () {
      final titles = sectionTitlesByFieldId({
        'inspection_data': {
          'untitled': {
            'items': [
              {'id': 'orphan'}
            ],
          },
          'ok': {
            'title': 'Interior',
            'items': [
              {'id': 'seat'}
            ],
          },
        },
      });

      expect(titles.containsKey('orphan'), isFalse);
      expect(titles['seat'], 'Interior');
    });

    test(
        'Given malformed items, When mapping, Then well-formed siblings still '
        'resolve', () {
      final titles = sectionTitlesByFieldId({
        'inspection_data': {
          's': {
            'title': 'Mixed',
            'items': [
              'not-a-map',
              {'no_id': true},
              {'id': 'good'},
            ],
          },
        },
      });

      expect(titles, {'good': 'Mixed'});
    });
  });

  // ---------------------------------------------------------------------------
  group('updateInspectionMedia — uploaded URLs must survive a retry', () {
    // The old call site looked entries up by local PATH against maps keyed by
    // FIELD ID, so the maps were always empty: a 150 MB video would upload
    // successfully, its URL would be discarded, and the next retry re-sent the
    // whole file.
    // Seeds an offline record directly. saveInspection copies media through
    // getApplicationDocumentsDirectory(), which no unit test can reach, so
    // going through it here would silently drop every entry and hide what this
    // group is actually asserting.
    Future<String> seedOfflineRecord({
      required String id,
      Map<String, String> videos = const {},
      Map<String, String> audios = const {},
    }) async {
      final box = await Hive.openLazyBox<LocalInspection>(
          LocalStorageService.INSPECTIONS_BOX);
      await box.put(
        id,
        LocalInspection(
          id: id,
          createdAt: DateTime.now(),
          data: const {},
          images: const {},
          status: 'offline',
          videos: videos,
          audios: audios,
        ),
      );
      return id;
    }

    Future<LocalInspection?> read(String id) async =>
        (await Hive.openLazyBox<LocalInspection>(
                LocalStorageService.INSPECTIONS_BOX))
            .get(id);

    test(
        'Given field-id keyed URLs, When persisted, Then each field holds its '
        'server URL instead of the local path', () async {
      final id = await seedOfflineRecord(
        id: 'rec-7',
        videos: const {'engine_video': '/local/a.mp4'},
        audios: const {'horn_audio': '/local/b.m4a'},
      );

      await LocalStorageService.updateInspectionMedia(
        inspectionId: id,
        uploadedVideos: const {'engine_video': 'https://cdn/a.mp4'},
        uploadedAudios: const {'horn_audio': 'https://cdn/b.m4a'},
      );

      final saved = await read(id);
      expect(saved!.videos['engine_video'], 'https://cdn/a.mp4');
      expect(saved.audios['horn_audio'], 'https://cdn/b.m4a');
    });

    test(
        'Given a persisted URL, When a later pass inspects the field, Then it '
        'is http so the re-upload guard skips it', () async {
      final id = await seedOfflineRecord(
        id: 'rec-8',
        videos: const {'v': '/local/c.mp4'},
      );

      await LocalStorageService.updateInspectionMedia(
        inspectionId: id,
        uploadedVideos: const {'v': 'https://cdn/c.mp4'},
      );

      final saved = await read(id);
      // retrySubmission skips any value already starting with http.
      expect(saved!.videos['v']!.startsWith('http'), isTrue,
          reason: 'a discarded URL made the next retry re-upload the file');
    });

    test(
        'Given a partially successful pass, When only some URLs are persisted, '
        'Then the failed field keeps its local path for retry', () async {
      final id = await seedOfflineRecord(
        id: 'rec-9',
        videos: const {'ok': '/local/ok.mp4', 'bad': '/local/bad.mp4'},
      );

      await LocalStorageService.updateInspectionMedia(
        inspectionId: id,
        uploadedVideos: const {'ok': 'https://cdn/ok.mp4'},
      );

      final saved = await read(id);
      expect(saved!.videos['ok'], 'https://cdn/ok.mp4');
      expect(saved.videos['bad'], '/local/bad.mp4',
          reason: 'still local, so the next retry picks it up');
    });

    test(
        'Given the old path-keyed lookup, When it is used, Then it produces no '
        'entries — the regression this group guards', () {
      // Reproduces the shipped bug: maps keyed by field id were probed with the
      // local path, so the built map was always empty and every uploaded URL
      // was thrown away.
      const videos = {'engine_video': '/local/a.mp4'};
      const replacements = {'engine_video': 'https://cdn/a.mp4'};

      final wrong = {
        for (final e in videos.entries)
          if (replacements.containsKey(e.value)) e.key: replacements[e.value]!,
      };
      expect(wrong, isEmpty);

      final right = {
        for (final e in videos.entries)
          if (replacements.containsKey(e.key)) e.key: replacements[e.key]!,
      };
      expect(right, {'engine_video': 'https://cdn/a.mp4'});
    });
  });

  // ---------------------------------------------------------------------------
  group('ApiService — upload guards and user-facing errors', () {
    test(
        'Given a file over the server limit, When uploading, Then it is '
        'refused locally with an actionable message', () async {
      // Sparse file: length without writing 200 MB to disk.
      final big = File('${tmp.path}/too_big.mp4');
      final raf = big.openSync(mode: FileMode.write);
      raf.setPositionSync(ApiService.maxUploadBytes + 1);
      raf.writeByteSync(0);
      raf.closeSync();
      addTearDown(() => big.deleteSync());

      final result = await ApiService.uploadImage(
        big.path,
        section: 'Engine Bay',
        itemId: 'engine_video',
        mediaType: 'video',
      );

      expect(result['success'], isFalse);
      expect(result['message'], contains('too large'));
      expect(result['message'], contains('MB'),
          reason: 'the inspector needs the actual size to judge a re-record');
    });

    test(
        'Given a missing file, When uploading, Then it fails fast without '
        'reaching the network', () async {
      final result = await ApiService.uploadImage(
        '${tmp.path}/definitely_absent.mp4',
        section: 'Engine Bay',
        itemId: 'engine_video',
        mediaType: 'video',
      );

      expect(result['success'], isFalse);
      expect(result['message'], 'File not found');
    });

    test(
        'Given the local limit, When compared to the server rule, Then they '
        'agree so the app never blocks a file the server would accept', () {
      // Laravel: 'image' => '...|max:1048576' (kilobytes) on the upload
      // endpoint, raised from 204800 in the "video issue fix" commit.
      expect(ApiService.maxUploadBytes, 1048576 * 1024);
    });

    test(
        'Given a body-too-large rejection, When shown to the inspector, Then '
        'the message explains the cause, not a bare status code', () {
      final msg = ApiService.uploadStatusMessage(413);
      expect(msg, contains('too large'));
      expect(msg, isNot(contains('413')));
    });

    test(
        'Given gateway and timeout statuses, When shown, Then each maps to '
        'plain guidance', () {
      expect(ApiService.uploadStatusMessage(408), contains('timed out'));
      expect(ApiService.uploadStatusMessage(504), contains('timed out'));
      expect(ApiService.uploadStatusMessage(502), contains('unavailable'));
      expect(ApiService.uploadStatusMessage(503), contains('unavailable'));
    });

    test(
        'Given an unmapped status, When shown, Then it still surfaces the code '
        'rather than an empty string', () {
      expect(ApiService.uploadStatusMessage(451), contains('451'));
    });

    test(
        'Given an absolute url from the server, When normalised, Then it is '
        'kept unchanged', () {
      const url = 'https://api.certifide.in/inspections/files/2026/09/02/a.mp4';
      expect(ApiService.absoluteMediaUrl(url), url);
    });

    test(
        'Given a bare inspections/ path, When normalised, Then it becomes an '
        'absolute url so the submit filter cannot drop it', () {
      // The submission body keeps only values starting with http; a relative
      // path here means the upload succeeds and the media vanishes.
      final resolved =
          ApiService.absoluteMediaUrl('inspections/files/2026/09/02/a.mp4');

      expect(resolved, startsWith('https://'));
      expect(resolved, endsWith('/inspections/files/2026/09/02/a.mp4'));
      expect(resolved, isNot(contains('/api/')),
          reason: 'media is served from the host root, not under /api');
    });

    test(
        'Given a leading-slash path, When normalised, Then it does not produce '
        'a doubled slash', () {
      expect(ApiService.absoluteMediaUrl('/inspections/a.mp4'),
          'https://api.certifide.in/inspections/a.mp4');
    });

    test(
        'Given null or empty, When normalised, Then it stays null so the '
        'caller still treats the upload as failed', () {
      expect(ApiService.absoluteMediaUrl(null), isNull);
      expect(ApiService.absoluteMediaUrl(''), isNull);
      expect(ApiService.absoluteMediaUrl('   '), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('endpoint routing — prefer the authenticated video route', () {
    // routes/api.php:744 defines /inspection/upload-image at the top level,
    // outside the jwt.auth group — the server never checks the token the app
    // sends. /dynamic-inspections/upload-video (line 277) sits inside
    // Route::group(['middleware' => ['jwt.auth', 'check.status']]).
    test(
        'Given a video with full routing metadata, When choosing an endpoint, '
        'Then the authenticated video route is used', () {
      expect(
        ApiService.usesVideoEndpoint(
          mediaType: 'video',
          section: 'Engine Bay',
          itemId: 'engine_video',
          fileName: 'abc.mp4',
        ),
        isTrue,
      );
    });

    test('Given a non-video, When choosing an endpoint, Then it stays legacy',
        () {
      for (final type in ['image', 'audio', 'file', 'multiImage', null]) {
        expect(
          ApiService.usesVideoEndpoint(
            mediaType: type,
            section: 'Engine Bay',
            itemId: 'x',
            fileName: 'abc.jpg',
          ),
          isFalse,
          reason: '$type has no dedicated endpoint',
        );
      }
    });

    test(
        'Given a video with no section or itemId, When choosing an endpoint, '
        'Then it falls back rather than hard-failing', () {
      // The video route requires both; the legacy route now accepts null. A
      // fallback uploads the file instead of losing it to a 422.
      expect(
        ApiService.usesVideoEndpoint(
          mediaType: 'video',
          section: '',
          itemId: 'engine_video',
          fileName: 'abc.mp4',
        ),
        isFalse,
      );
      expect(
        ApiService.usesVideoEndpoint(
          mediaType: 'video',
          section: '   ',
          itemId: 'engine_video',
          fileName: 'abc.mp4',
        ),
        isFalse,
      );
      expect(
        ApiService.usesVideoEndpoint(
          mediaType: 'video',
          section: 'Engine Bay',
          itemId: '',
          fileName: 'abc.mp4',
        ),
        isFalse,
      );
    });

    test(
        'Given a format only the legacy route accepts, When choosing an '
        'endpoint, Then it falls back', () {
      // The legacy mimes list gained 3gp; the video route's did not.
      expect(
        ApiService.usesVideoEndpoint(
          mediaType: 'video',
          section: 'Engine Bay',
          itemId: 'v',
          fileName: 'clip.3gp',
        ),
        isFalse,
      );
      expect(
        ApiService.usesVideoEndpoint(
          mediaType: 'video',
          section: 'Engine Bay',
          itemId: 'v',
          fileName: 'noextension',
        ),
        isFalse,
      );
    });

    test(
        'Given every format the video route accepts, When choosing an '
        'endpoint, Then each routes there', () {
      for (final ext in ApiService.videoEndpointExtensions) {
        expect(
          ApiService.usesVideoEndpoint(
            mediaType: 'video',
            section: 'Engine Bay',
            itemId: 'v',
            fileName: 'clip.$ext',
          ),
          isTrue,
          reason: '.$ext is in the server mimes rule',
        );
      }
      // Mirrors 'mimes:mp4,avi,mov,wmv,flv,webm,mkv' — no 3gp.
      expect(ApiService.videoEndpointExtensions, isNot(contains('3gp')));
    });

    test('Given an uppercase extension, When choosing, Then case is ignored',
        () {
      expect(
        ApiService.usesVideoEndpoint(
          mediaType: 'video',
          section: 'Engine Bay',
          itemId: 'v',
          fileName: 'CLIP.MP4',
        ),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('crash resume — an interrupted upload is retried, not lost', () {
    test(
        'Given a crash mid-upload (entry left "uploading"), When the queue is '
        'read back, Then the entry is still pending so it re-uploads', () async {
      final video = makeFile('resume_uploading.mp4');

      final id = await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 1001,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'v',
            mediaType: 'video',
            fieldKey: 'v',
          ),
        },
        saveStepItems: const {},
      );

      // Simulate the process dying after the "uploading" mark but before any
      // result was written.
      await LocalStorageService.setPendingMediaStatus(
        inspectionId: id,
        key: 'video_v',
        status: PendingMediaStatus.uploading,
      );

      final queued = await LocalStorageService.getInspectionsWithPendingMedia();
      expect(queued.map((e) => e.id), contains(id),
          reason: 'a half-finished upload must still surface for retry');

      final entry = queued.first.pendingMedia['video_v']!;
      expect(entry.isUploaded, isFalse);
      // The drain selects anything not (uploaded AND carrying a URL).
      final selected =
          !(entry.isUploaded && (entry.uploadedUrl?.isNotEmpty ?? false));
      expect(selected, isTrue);
    });

    test(
        'Given a failed upload, When the queue is read back, Then the entry is '
        'retried and its error and attempt count are recorded', () async {
      final video = makeFile('resume_failed.mp4');

      final id = await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 1002,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'v',
            mediaType: 'video',
            fieldKey: 'v',
          ),
        },
        saveStepItems: const {},
      );

      await LocalStorageService.setPendingMediaStatus(
        inspectionId: id,
        key: 'video_v',
        status: PendingMediaStatus.failed,
        error: 'The image failed to upload.',
      );

      final container = await LocalStorageService.getMediaQueueById(id);
      final entry = container!.pendingMedia['video_v']!;

      expect(entry.isUploaded, isFalse, reason: 'stays eligible for retry');
      expect(entry.lastError, 'The image failed to upload.');
      expect(entry.retryCount, 1);
    });

    test(
        'Given an uploaded entry, When the screen re-commits the queue, Then '
        'the URL is not downgraded back to a local path', () async {
      final video = makeFile('no_downgrade.mp4');

      final id = await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 1003,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'v',
            mediaType: 'video',
            fieldKey: 'v',
          ),
        },
        saveStepItems: const {},
      );

      await LocalStorageService.setPendingMediaStatus(
        inspectionId: id,
        key: 'video_v',
        status: PendingMediaStatus.uploaded,
        url: 'https://cdn/v.mp4',
      );

      // A later lifecycle commit re-scans and offers the same key as local.
      await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 1003,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'v',
            mediaType: 'video',
            fieldKey: 'v',
          ),
        },
        saveStepItems: const {},
      );

      final container = await LocalStorageService.getMediaQueueById(id);
      final entry = container!.pendingMedia['video_v']!;

      expect(entry.isUploaded, isTrue, reason: 're-uploading wastes the file');
      expect(entry.uploadedUrl, 'https://cdn/v.mp4');
    });

    test(
        'Given a queued video whose file was deleted, When the queue is '
        'committed again, Then the dead entry is not carried forward', () async {
      final video = makeFile('will_vanish.mp4');

      await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 1004,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'v',
            mediaType: 'video',
            fieldKey: 'v',
          ),
        },
        saveStepItems: const {},
      );

      video.deleteSync();

      // Re-commit: a missing file must not be re-queued (it can never upload,
      // and it would block its field's save-step forever).
      await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 1004,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'v',
            mediaType: 'video',
            fieldKey: 'v',
          ),
        },
        saveStepItems: const {},
      );

      final container = await LocalStorageService.getMediaQueueById(
          LocalStorageService.mediaQueueId(1004));
      expect(container?.pendingMedia['video_v'], isNull);
    });

    test(
        'Given a video queued while offline, When the app restarts, Then the '
        'entry keeps the routing metadata the upload needs', () async {
      final video = makeFile('offline_survives.mp4');

      final id = await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 1005,
        vehicleInfo: const {'registration_number': 'KA01AB1234'},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'engine_video',
            mediaType: 'video',
            fieldKey: 'engine_video',
          ),
        },
        saveStepItems: const {},
      );

      // A restart re-reads the box; nothing is held in memory.
      final container = await LocalStorageService.getMediaQueueById(id);
      final entry = container!.pendingMedia['video_v']!;

      expect(entry.section, 'Engine Bay', reason: 'blank section = 422');
      expect(entry.itemId, 'engine_video');
      expect(entry.mediaType, 'video');
      expect(container.serverInspectionId, 1005,
          reason: 'sent as inspection_id so the media lands on the right draft');
      expect(File(entry.localPath).existsSync(), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('durability — a failed submit leaves something to retry', () {
    // _handleSubmission persists the inspection as an offline record on BOTH
    // the rejected-response path and the exception path. Previously a throw
    // only showed a snackbar, so the work had no queue entry behind it.
    // These assert the storage contract that path depends on.
    test(
        'Given a saved offline record, When pending work is listed, Then it is '
        'picked up for automatic retry', () async {
      final id = await LocalStorageService.saveInspection(
        data: const {'inspection_id': 5001},
        images: const {},
        status: 'offline',
      );

      final pending = await LocalStorageService.getPendingInspections();
      expect(pending.map((e) => e.id), contains(id),
          reason: 'nothing retries an inspection that was never persisted');
    });

    test(
        'Given a persisted record, When the queue container is cleared without '
        'deleting files, Then the media the open screen still points at '
        'survives', () async {
      final video = makeFile('failed_submit_keeps.mp4');

      await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 5002,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: video.path,
            section: 'Engine Bay',
            itemId: 'v',
            mediaType: 'video',
            fieldKey: 'v',
          ),
        },
        saveStepItems: const {},
      );

      await LocalStorageService.clearMediaQueueFor(5002,
          deleteLocalFiles: false);

      expect(video.existsSync(), isTrue,
          reason: 'deleting here made every later retry fail File not found');
      expect(
          await LocalStorageService.getMediaQueueById(
              LocalStorageService.mediaQueueId(5002)),
          isNull,
          reason: 'the container itself is still removed');
    });

    test(
        'Given a media-less field edited offline, When queued, Then its answer '
        'is replayed rather than silently dropped', () async {
      // Backstop for a per-field save-step the server rejected: the answer is
      // queued and drained by syncPendingSaveSteps.
      final id = await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 5003,
        vehicleInfo: const {},
        pendingMedia: const {},
        saveStepItems: const {},
        answerStepItems: {
          'brakes': {
            'section': 'test_drive',
            'item': {'id': 'brakes', 'value': 'pass'},
          },
        },
      );

      final pending =
          await LocalStorageService.getInspectionsWithPendingSaveSteps();
      expect(pending.map((e) => e.id), contains(id));

      final container = await LocalStorageService.getMediaQueueById(id);
      expect((container!.data['pendingAnswerSteps'] as Map)['brakes'],
          isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('recording limits — keeping files inside what can be uploaded', () {
    // 1080p h264 runs ~8-12 Mbps; budget the pessimistic end plus audio.
    const worstCaseBytesPerSecond = 12 * 1000 * 1000 ~/ 8;

    test(
        'Given the recording cap, When compared to the server limit, Then a '
        'full-length clip is comfortably inside it', () {
      expect(maxRecordingDuration, const Duration(minutes: 2));

      final worstCase =
          maxRecordingDuration.inSeconds * worstCaseBytesPerSecond;

      expect(worstCase, lessThan(ApiService.maxUploadBytes));
    });

    test(
        'Given the recording cap, When compared to the largest transfer ever '
        'observed to complete, Then it stays inside that proven range', () {
      // The server rule (1 GB) is not the real constraint — a transfer cut off
      // mid-flight is what the logs recorded as "The image failed to upload."
      // The biggest video that actually landed was ~173 MB.
      const largestObservedSuccessBytes = 173 * 1024 * 1024;
      final worstCase =
          maxRecordingDuration.inSeconds * worstCaseBytesPerSecond;

      expect(worstCase, lessThanOrEqualTo(largestObservedSuccessBytes),
          reason: 'raising the cap past what has been seen to complete trades '
              'a working upload for a partial one');
    });

    test('Given the cap, When read, Then it is a usable inspection length', () {
      expect(maxRecordingDuration.inSeconds, greaterThanOrEqualTo(60));
    });
  });
}
