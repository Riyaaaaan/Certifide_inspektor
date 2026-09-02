// Provider-layer tests for InspectionNotifier.
//
// Success AND error paths for the sync entry points. The notifier reaches the
// network through static helpers, so these drive the branch that matters most
// for correctness — the offline guard — via
// ConnectivityChecker.debugReachableOverride, and assert that a pass over real
// Hive data leaves the queue in the right state rather than throwing.
//
// Providers are never mocked; the container is real and only dependencies are
// controlled.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:certifide_inspektor/models/inspection_state.dart';
import 'package:certifide_inspektor/models/local_inspection.dart';
import 'package:certifide_inspektor/models/pending_image.dart';
import 'package:certifide_inspektor/models/pending_media.dart';
import 'package:certifide_inspektor/providers/connectivity_provider.dart';
import 'package:certifide_inspektor/providers/inspection_provider.dart';
import 'package:certifide_inspektor/services/local_storage_services.dart';
import 'package:certifide_inspektor/utils/connectivity_checker.dart';

import 'riverpod_container.dart';

/// Stands in for the real [ConnectivityStatus] so no test touches the
/// connectivity_plus EventChannel.
///
/// The provider is NOT mocked — this is the real notifier type with only
/// build() replaced, so nothing subscribes to a platform channel and no probe
/// runs in the background.
class _FakeConnectivityStatus extends ConnectivityStatus {
  _FakeConnectivityStatus(this._online);

  final bool _online;

  @override
  bool build() => _online;
}

void main() {
  // connectivity_plus reaches ServicesBinding.instance even when overridden
  // elsewhere in the tree.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('inspection_provider_test');
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

  tearDown(() {
    // Never leak the override into another test — it would silently convince
    // the next one it is online.
    ConnectivityChecker.debugReachableOverride = null;
  });

  tearDownAll(() async {
    await Hive.close();
    tmp.deleteSync(recursive: true);
  });

  File makeFile(String name) =>
      File('${tmp.path}/$name')..writeAsBytesSync(const [1, 2, 3]);

  /// Container whose connectivity is fixed, so no platform channel is touched.
  ProviderContainer offlineContainer({bool online = false}) => createContainer(
        overrides: [
          connectivityStatusProvider
              .overrideWith(() => _FakeConnectivityStatus(online)),
        ],
      );

  Future<String> queueOneVideo(int serverId, {required String path}) =>
      LocalStorageService.upsertMediaQueue(
        serverInspectionId: serverId,
        vehicleInfo: const {},
        pendingMedia: {
          'video_v': PendingMedia(
            localPath: path,
            section: 'Engine Bay',
            itemId: 'engine_video',
            mediaType: 'video',
            fieldKey: 'engine_video',
          ),
        },
        saveStepItems: const {},
      );

  group('ConnectivityChecker — the seam every sync path branches on', () {
    test('Given no override, When probed, Then the real lookup is used', () {
      expect(ConnectivityChecker.debugReachableOverride, isNull,
          reason: 'production must never see a forced value');
    });

    test('Given an offline override, When probed, Then it reports offline',
        () async {
      ConnectivityChecker.debugReachableOverride = false;
      expect(await ConnectivityChecker.canReachServer(), isFalse);
    });

    test('Given an online override, When probed, Then it reports online',
        () async {
      ConnectivityChecker.debugReachableOverride = true;
      expect(await ConnectivityChecker.canReachServer(), isTrue);
    });
  });

  group('syncPendingMedia — offline is a no-op, not a failure', () {
    test(
        'Given the device is offline, When syncing, Then queued media is left '
        'untouched for a later pass', () async {
      final video = makeFile('offline_noop.mp4');
      final id = await queueOneVideo(6001, path: video.path);
      ConnectivityChecker.debugReachableOverride = false;

      final container = offlineContainer();
      await container.read(inspectionProvider.notifier).syncPendingMedia();

      final after = await LocalStorageService.getMediaQueueById(id);
      expect(after, isNotNull, reason: 'offline must not discard the queue');
      expect(after!.pendingMedia['video_v'], isNotNull);
      expect(after.pendingMedia['video_v']!.isUploaded, isFalse);
      expect(video.existsSync(), isTrue);
    });

    test(
        'Given nothing queued, When syncing offline, Then it completes without '
        'throwing', () async {
      ConnectivityChecker.debugReachableOverride = false;

      final container = offlineContainer();
      await expectLater(
        container.read(inspectionProvider.notifier).syncPendingMedia(),
        completes,
      );
    });

    test(
        'Given the device is offline, When replaying save-steps, Then queued '
        'answers survive for a later pass', () async {
      final id = await LocalStorageService.upsertMediaQueue(
        serverInspectionId: 6002,
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
      ConnectivityChecker.debugReachableOverride = false;

      final container = offlineContainer();
      await container.read(inspectionProvider.notifier).syncPendingSaveSteps();

      final after = await LocalStorageService.getMediaQueueById(id);
      expect((after!.data['pendingAnswerSteps'] as Map)['brakes'], isNotNull,
          reason: 'an offline pass must not drop the answer');
    });
  });

  group('uploadInspectionMedia — offline reports real progress', () {
    test(
        'Given the device is offline, When upload is triggered manually, Then '
        'it returns false and seeds progress from the queue contents',
        () async {
      final video = makeFile('manual_offline.mp4');
      final id = await queueOneVideo(6003, path: video.path);
      final container_ = await LocalStorageService.getMediaQueueById(id);
      ConnectivityChecker.debugReachableOverride = false;

      final container = offlineContainer();
      final notifier = container.read(inspectionProvider.notifier);
      final drained = await notifier.uploadInspectionMedia(container_!);

      expect(drained, isFalse);

      // Progress must reflect the container, not a 0/0 placeholder — the
      // Pending tab renders these numbers.
      final progress = container.read(inspectionProvider).mediaProgress[id];
      expect(progress, isNotNull);
      expect(progress!.total, 1);
      expect(progress.uploaded, 0);
      expect(progress.isUploading, isFalse,
          reason: 'a stuck spinner is the symptom being guarded against');
    });
  });

  group('state model — progress and flags survive copyWith', () {
    test(
        'Given a progress value, When a field is changed, Then the others are '
        'preserved', () {
      const progress = MediaUploadProgress(
        total: 5,
        uploaded: 2,
        failed: 1,
        isUploading: true,
      );

      final stopped = progress.copyWith(isUploading: false);

      expect(stopped.total, 5);
      expect(stopped.uploaded, 2);
      expect(stopped.failed, 1);
      expect(stopped.isUploading, isFalse);
    });

    test(
        'Given a fresh notifier, When first read, Then it starts with an empty '
        'queue and no progress', () {
      final container = offlineContainer();
      final state = container.read(inspectionProvider);

      expect(state.mediaQueue, isEmpty);
      expect(state.mediaProgress, isEmpty);
      expect(state.isLoading, isFalse);
    });
  });

  group('sectionTitlesByFieldId — error paths', () {
    test('Given a null-ish body, When mapping, Then it returns empty', () {
      expect(sectionTitlesByFieldId(const {'inspection_data': null}), isEmpty);
      expect(sectionTitlesByFieldId(const {'inspection_data': []}), isEmpty);
    });

    test(
        'Given items that are not a list, When mapping, Then the section is '
        'skipped without throwing', () {
      expect(
        sectionTitlesByFieldId(const {
          'inspection_data': {
            's': {'title': 'Engine', 'items': 'not-a-list'},
          },
        }),
        isEmpty,
      );
    });

    test(
        'Given a numeric field id, When mapping, Then it is normalised to a '
        'string key', () {
      final titles = sectionTitlesByFieldId(const {
        'inspection_data': {
          's': {
            'title': 'Engine',
            'items': [
              {'id': 42}
            ],
          },
        },
      });

      expect(titles['42'], 'Engine');
    });
  });
}
