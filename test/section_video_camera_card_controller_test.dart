// Empirical verification for the "Stop doesn't stop the recording" bug.
//
// A physical camera can't run in CI, but the *real* [VideoCardController] and
// the *real* `CameraController` are driven here against a faked [CameraPlatform].
// The controller keeps `value.isRecordingVideo` in pure Dart, so start/stop
// flip it exactly as they would on a device — only platform I/O is faked.
//
// These tests reproduce the state-flag desync that made the Stop button fail
// and confirm the fixes in section_video_camera_card_controller.dart.

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:certifide_inspektor/widgets/section_camera_card.dart'
    show cameraCardPendingDisposal;
import 'package:certifide_inspektor/widgets/section_video_camera_card_controller.dart';

/// A [CameraPlatform] that records nothing to disk but faithfully tracks the
/// native "am I recording?" flag so [CameraController.value.isRecordingVideo]
/// behaves like the real thing.
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  bool recording = false;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
        CameraDescription(
          name: 'back',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];

  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async =>
      1;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream<CameraInitializedEvent>.value(
        const CameraInitializedEvent(
          1,
          1920,
          1080,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  // Never-emitting streams: the controller keeps a `.first`/`.listen`
  // subscription on these; leaving them pending avoids the StateError that an
  // empty stream's `.first` would raise inside the plugin's unawaited handler.
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      StreamController<CameraErrorEvent>.broadcast().stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      StreamController<DeviceOrientationChangedEvent>.broadcast().stream;

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    startCalls++;
    recording = true;
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stopCalls++;
    recording = false;
    return XFile('/tmp/fake_recording.mp4');
  }

  @override
  Future<void> pauseVideoRecording(int cameraId) async {}

  @override
  Future<void> resumeVideoRecording(int cameraId) async {}

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Future<void> dispose(int cameraId) async {}

  @override
  Widget buildPreview(int cameraId) => const SizedBox.shrink();
}

Future<void> _pumpUntil(bool Function() done, {int tries = 200}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeCameraPlatform fake;
  late ProviderContainer container;

  setUp(() {
    fake = _FakeCameraPlatform();
    CameraPlatform.instance = fake;
    cameraCardPendingDisposal = null; // reset the cross-card shared handle
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  /// Builds the notifier, keeps the autoDisposed provider alive, waits for the
  /// camera to initialise, and wires capture/recording sinks the parent UI uses.
  Future<VideoCardController> ready(
    List<bool> recordingChanges,
    List<XFile> captures,
  ) async {
    final provider = videoCardControllerProvider('card-1');
    container.listen(provider, (_, __) {}, fireImmediately: true);
    final notifier = container.read(provider.notifier);
    await _pumpUntil(() => container.read(provider).isInitialized);
    expect(container.read(provider).isInitialized, isTrue,
        reason: 'fake camera should initialise');
    notifier.attach(
      onRecordingChanged: recordingChanges.add,
      onRecordingPausedChanged: (_) {},
      onCapture: captures.add,
    );
    return notifier;
  }

  test('Stop actually stops an active recording and reports it once', () async {
    final recordingChanges = <bool>[];
    final captures = <XFile>[];
    final notifier = await ready(recordingChanges, captures);

    // Tap record.
    await notifier.toggleRecording();
    expect(fake.recording, isTrue);
    expect(notifier.controller!.value.isRecordingVideo, isTrue);
    expect(recordingChanges.last, isTrue);

    // Tap stop — the core scenario in the bug report.
    await notifier.toggleRecording();
    expect(fake.recording, isFalse,
        reason: 'native recorder must be stopped after tapping Stop');
    expect(fake.stopCalls, 1);
    expect(recordingChanges.last, isFalse,
        reason: 'parent UI must be told recording ended');
    expect(captures, hasLength(1),
        reason: 'the recorded file must be handed back');
  });

  test('backgrounding mid-recording clears the parent recording flag', () async {
    final recordingChanges = <bool>[];
    final captures = <XFile>[];
    final notifier = await ready(recordingChanges, captures);

    await notifier.toggleRecording(); // start
    expect(recordingChanges.last, isTrue);

    // App sent to background while recording. Before the fix, the native
    // recorder was stopped but onRecordingChanged(false) never fired, so the
    // parent's `_captureUi.isVideoRecording` stayed stuck true — the button
    // kept showing "Stop" yet tapping it started a NEW recording.
    notifier.didChangeAppLifecycleState(AppLifecycleState.paused);
    await _pumpUntil(() => recordingChanges.last == false);

    expect(recordingChanges.last, isFalse,
        reason: 'parent must be notified so the Stop button state stays in sync');
  });

  test('Stop resyncs (never restarts) when native already stopped', () async {
    final recordingChanges = <bool>[];
    final captures = <XFile>[];
    final notifier = await ready(recordingChanges, captures);

    await notifier.toggleRecording(); // start
    expect(recordingChanges.last, isTrue);

    // Force a desync: native recorder stops out-of-band while the notifier
    // still believes it is recording (state.isRecording == true).
    await notifier.controller!.stopVideoRecording();
    expect(fake.recording, isFalse);

    // Tapping Stop must resolve the desync — report recording ended and NOT
    // kick off a fresh recording.
    await notifier.toggleRecording();
    expect(recordingChanges.last, isFalse,
        reason: 'Stop must clear the recording flag even on desync');
    expect(fake.startCalls, 1,
        reason: 'Stop must never start a new recording');
    expect(fake.recording, isFalse);
  });
}
