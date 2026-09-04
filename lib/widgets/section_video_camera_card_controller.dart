import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'section_camera_card.dart'
    show cameraCardPendingDisposal, safeDisposeCamera;

part 'section_video_camera_card_controller.g.dart';

/// Capture resolution for inspection video: 1080p, not the sensor maximum.
///
/// [ResolutionPreset.max] records at whatever the sensor offers — 4K at 40-60
/// Mbps on a current phone, so ~7 MB per second with no duration cap. The
/// upload path reads the whole file into memory before sending
/// (`ApiService.uploadImage`), so a long 4K clip gets the app OOM-killed
/// mid-upload and the video silently never arrives.
///
/// 1080p is 4-9x smaller and still resolves the detail an inspection needs:
/// panel scratches, tyre wear, VIN and odometer plates.
const ResolutionPreset _videoResolution = ResolutionPreset.veryHigh;

/// Hard stop for a single recording.
///
/// Recording was previously unbounded, so a button left held produced a file
/// that took minutes to send over mobile data — and a transfer cut off
/// mid-flight is rejected as a partial upload, which is what the server logged
/// as "The image failed to upload."
///
/// The binding constraint is transfer reliability, NOT the server's size rule
/// (1 GB, far above anything recorded here). Sized against what has actually
/// been observed to complete: the largest video that ever landed on the server
/// was ~173 MB. At 1080p h264's ~12 Mbps peak, two minutes is ~180 MB, which
/// keeps a full-length clip inside that proven range.
const Duration maxRecordingDuration = Duration(minutes: 2);

/// Immutable, rebuild-driving slice of a video camera card's state. Hardware
/// handles (the [CameraController], timers, generation counters) live on the
/// notifier itself — only the fields the UI renders belong here.
class VideoCardState {
  final bool isInitialized;
  final bool hasError;
  final String errorMessage;
  final bool isRecording;
  final bool isPaused;
  final bool flashOn;
  final Duration elapsed;

  const VideoCardState({
    this.isInitialized = false,
    this.hasError = false,
    this.errorMessage = '',
    this.isRecording = false,
    this.isPaused = false,
    this.flashOn = false,
    this.elapsed = Duration.zero,
  });

  VideoCardState copyWith({
    bool? isInitialized,
    bool? hasError,
    String? errorMessage,
    bool? isRecording,
    bool? isPaused,
    bool? flashOn,
    Duration? elapsed,
  }) {
    return VideoCardState(
      isInitialized: isInitialized ?? this.isInitialized,
      hasError: hasError ?? this.hasError,
      errorMessage: errorMessage ?? this.errorMessage,
      isRecording: isRecording ?? this.isRecording,
      isPaused: isPaused ?? this.isPaused,
      flashOn: flashOn ?? this.flashOn,
      elapsed: elapsed ?? this.elapsed,
    );
  }
}

/// Owns the camera lifecycle and recording state for one card, keyed by a
/// stable [cardId] so each on-screen card gets its own autoDisposed instance.
/// Replaces the old `setState`-driven `State` so only widgets that watch this
/// provider rebuild, and the hardware is released via [Ref.onDispose].
@riverpod
class VideoCardController extends _$VideoCardController
    with WidgetsBindingObserver {
  // Shared with SectionCameraCard so photo/video mode switches don't fight over
  // the hardware. Mirrors the old static accessor.
  static Future<void>? get _pendingDisposal => cameraCardPendingDisposal;
  static set _pendingDisposal(Future<void>? v) => cameraCardPendingDisposal = v;

  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isInitializing = false;
  bool _isDisposePending = false;
  bool _isToggling = false;
  bool _disposed = false;
  int _currentCameraIndex = 0;
  // Incremented on every inactive/paused and dispose to cancel in-flight inits.
  int _initGeneration = 0;
  Timer? _timer;

  // Widget-supplied sinks, refreshed each build via [attach].
  void Function(XFile file)? _onCapture;
  void Function(bool isRecording)? _onRecordingChanged;
  void Function(bool isPaused)? _onRecordingPausedChanged;
  void Function(VoidCallback toggle)? _onRecordingToggleReady;
  void Function(VoidCallback toggle)? _onPauseResumeReady;
  void Function(VoidCallback toggle)? _onFlashToggleReady;
  void Function(String message)? _onNotice;

  /// The live controller for [CameraPreview]; null until initialised.
  CameraController? get controller => _controller;

  @override
  VideoCardState build(String cardId) {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      WidgetsBinding.instance.removeObserver(this);
      _initGeneration++;
      _timer?.cancel();
      _disposeController();
    });
    // Touch hardware after build returns so the first frame isn't blocked.
    Future.microtask(initCamera);
    return const VideoCardState();
  }

  /// Refreshes the widget callbacks. Called from the card's build so the
  /// notifier always forwards captures / notices to the current widget.
  void attach({
    void Function(XFile file)? onCapture,
    void Function(bool isRecording)? onRecordingChanged,
    void Function(bool isPaused)? onRecordingPausedChanged,
    void Function(VoidCallback toggle)? onRecordingToggleReady,
    void Function(VoidCallback toggle)? onPauseResumeReady,
    void Function(VoidCallback toggle)? onFlashToggleReady,
    void Function(String message)? onNotice,
  }) {
    _onCapture = onCapture;
    _onRecordingChanged = onRecordingChanged;
    _onRecordingPausedChanged = onRecordingPausedChanged;
    _onRecordingToggleReady = onRecordingToggleReady;
    _onPauseResumeReady = onPauseResumeReady;
    _onFlashToggleReady = onFlashToggleReady;
    _onNotice = onNotice;
  }

  void _set(VideoCardState next) {
    if (_disposed) return;
    state = next;
  }

  @override
  // Named `lifecycle` to avoid shadowing the notifier's own `state`.
  // ignore: avoid_renaming_method_parameters
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      // Cancel any in-flight init (e.g. waiting for iOS permission dialog).
      _initGeneration++;
      _isInitializing = false;
      _stopRecordingIfActive();
      _disposeController();
      _set(state.copyWith(isInitialized: false));
    } else if (lifecycle == AppLifecycleState.resumed && !_disposed) {
      initCamera();
    }
  }

  void _disposeController() {
    if (_isInitializing) {
      _isDisposePending = true;
      return;
    }
    _isDisposePending = false;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      _pendingDisposal = safeDisposeCamera(controller);
    }
  }

  Future<void> initCamera() async {
    if (_isInitializing) return;
    _isInitializing = true;
    final myGen = ++_initGeneration;

    try {
      // Yield one tick so Flutter finishes reconciliation before touching hardware.
      await Future.delayed(Duration.zero);
      if (_disposed || _initGeneration != myGen) return;

      // Wait for the previous card's camera controller to fully release.
      final disposal = _pendingDisposal;
      if (disposal != null) {
        _pendingDisposal = null;
        await disposal.timeout(const Duration(seconds: 2), onTimeout: () {});
      }
      if (_disposed || _initGeneration != myGen) return;

      _set(state.copyWith(
        hasError: false,
        errorMessage: '',
        isInitialized: false,
      ));

      final hasCamPerm = await _ensurePermission(
        Permission.camera,
        'Camera permission is required to record inspection videos',
      );
      // On iOS the permission dialog causes a brief inactive→resumed cycle.
      // Re-wait for any disposal that occurred during the dialog.
      if (_disposed || _initGeneration != myGen) return;
      final postCamDisposal = _pendingDisposal;
      if (postCamDisposal != null) {
        _pendingDisposal = null;
        await postCamDisposal.timeout(const Duration(seconds: 2),
            onTimeout: () {});
      }
      if (_disposed || _initGeneration != myGen) return;
      if (!hasCamPerm) return;

      final hasMicPerm = await _ensurePermission(
        Permission.microphone,
        'Microphone permission is required to record inspection videos',
      );
      if (_disposed || _initGeneration != myGen) return;
      final postMicDisposal = _pendingDisposal;
      if (postMicDisposal != null) {
        _pendingDisposal = null;
        await postMicDisposal.timeout(const Duration(seconds: 2),
            onTimeout: () {});
      }
      if (_disposed || _initGeneration != myGen) return;
      if (!hasMicPerm) return;

      _cameras = await availableCameras();
      if (_disposed || _initGeneration != myGen) return;
      if (_cameras == null || _cameras!.isEmpty) {
        _set(state.copyWith(hasError: true, errorMessage: 'No cameras available'));
        return;
      }

      final backIdx = _cameras!
          .indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      _currentCameraIndex = backIdx >= 0 ? backIdx : 0;

      for (int attempt = 0; attempt < 3; attempt++) {
        if (_disposed || _initGeneration != myGen) return;

        if (attempt > 0) {
          final prev = _pendingDisposal;
          _pendingDisposal = null;
          if (prev != null) {
            await prev.timeout(const Duration(seconds: 1), onTimeout: () {});
          } else {
            await Future.delayed(const Duration(milliseconds: 600));
          }
          if (_disposed || _initGeneration != myGen) return;
        }

        final ok = await _tryStartCamera(_cameras![_currentCameraIndex]);
        if (ok) return;
      }

      _set(state.copyWith(
        hasError: true,
        errorMessage: 'Camera unavailable. Tap to retry.',
      ));
    } catch (_) {
      _set(state.copyWith(
        hasError: true,
        errorMessage: 'Failed to initialize camera',
      ));
    } finally {
      if (_initGeneration == myGen) _isInitializing = false;
    }
  }

  Future<bool> _tryStartCamera(CameraDescription camera) async {
    final old = _controller;
    _controller = null;
    if (old != null) {
      final f = safeDisposeCamera(old);
      _pendingDisposal = f;
      await f.timeout(const Duration(seconds: 1), onTimeout: () {});
      _pendingDisposal = null;
    }

    if (_disposed) return false;

    final controller = CameraController(
      camera,
      // 1080p capture. Encoder compresses in real time to the bitrate below,
      // so the file is born small — no post-capture compression step needed.
      _videoResolution,
      enableAudio: true,
      fps: 30,
      // ~5 Mbps: high quality at 1080p30, ~38 MB/min. Default recorder runs
      // 12-20 Mbps. Tune up for sharper / down for smaller uploads.
      videoBitrate: 5000000,
      audioBitrate: 128000,
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (_isDisposePending || _disposed || _controller != controller) {
        _isDisposePending = false;
        _pendingDisposal = safeDisposeCamera(controller);
        _controller = null;
        return false;
      }
      _set(state.copyWith(
        isInitialized: true,
        hasError: false,
        flashOn: false,
      ));
      _onRecordingToggleReady?.call(toggleRecording);
      _onPauseResumeReady?.call(togglePauseRecording);
      _onFlashToggleReady?.call(toggleFlash);
      return true;
    } on CameraException {
      _isDisposePending = false;
      _pendingDisposal = safeDisposeCamera(_controller);
      _controller = null;
      return false;
    } catch (_) {
      _isDisposePending = false;
      _pendingDisposal = safeDisposeCamera(_controller);
      _controller = null;
      return false;
    }
  }

  Future<bool> _ensurePermission(Permission perm, String errorMsg) async {
    if (!(Platform.isIOS || Platform.isAndroid)) return true;
    var status = await perm.status;
    if (status.isGranted) return true;
    if (status.isPermanentlyDenied || status.isRestricted) {
      _set(state.copyWith(hasError: true, errorMessage: errorMsg));
      return false;
    }
    status = await perm.request();
    if (!status.isGranted) {
      _set(state.copyWith(hasError: true, errorMessage: errorMsg));
    }
    return status.isGranted;
  }

  Future<void> toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final next = state.flashOn ? FlashMode.off : FlashMode.torch;
    try {
      await _controller!.setFlashMode(next);
      _set(state.copyWith(flashOn: !state.flashOn));
    } catch (_) {}
  }

  Future<void> toggleRecording() async {
    if (_isToggling || _controller == null || !_controller!.value.isInitialized) {
      return;
    }
    _isToggling = true;
    try {
      // Stop if EITHER our own flag or the native recorder says we're
      // recording. The two can briefly desync (e.g. a recording auto-stopped
      // when the app was backgrounded, whose parent-UI flag never cleared);
      // trusting the hardware guarantees Stop always stops an active capture
      // instead of accidentally starting a new one.
      if (state.isRecording || (_controller!.value.isRecordingVideo)) {
        await _stopRecording();
      } else {
        await _startRecording();
      }
    } finally {
      _isToggling = false;
    }
  }

  Future<void> _startRecording() async {
    // Guard against the camera already recording at the native level.
    if (_controller!.value.isRecordingVideo) {
      _onNotice?.call('Recording already started');
      return;
    }
    try {
      await _controller!.startVideoRecording();
      _startTimer(reset: true);
      _set(state.copyWith(isRecording: true, isPaused: false));
      _onRecordingChanged?.call(true);
      _onRecordingPausedChanged?.call(false);
    } on CameraException catch (e) {
      final msg = e.description?.toLowerCase() ?? '';
      _onNotice?.call(msg.contains('already')
          ? 'Recording already started'
          : 'Failed to start recording');
    } catch (e) {
      _onNotice?.call('Failed to start recording: $e');
    }
  }

  void _startTimer({bool reset = false}) {
    _timer?.cancel();
    if (reset) _set(state.copyWith(elapsed: Duration.zero));
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final elapsed = state.elapsed + const Duration(seconds: 1);
      _set(state.copyWith(elapsed: elapsed));
      if (elapsed >= maxRecordingDuration) {
        _onNotice?.call(
            'Maximum recording length reached (${maxRecordingDuration.inMinutes} min).');
        unawaited(_stopRecording());
      }
    });
  }

  /// Pauses an active recording or resumes a paused one. No-op when not
  /// recording.
  Future<void> togglePauseRecording() async {
    if (_isToggling || !state.isRecording) return;
    if (!(_controller?.value.isRecordingVideo ?? false)) return;
    _isToggling = true;
    try {
      if (state.isPaused) {
        await _controller!.resumeVideoRecording();
        _startTimer();
        _set(state.copyWith(isPaused: false));
        _onRecordingPausedChanged?.call(false);
      } else {
        await _controller!.pauseVideoRecording();
        _timer?.cancel();
        _timer = null;
        _set(state.copyWith(isPaused: true));
        _onRecordingPausedChanged?.call(true);
      }
    } on CameraException catch (_) {
      _onNotice?.call(state.isPaused
          ? 'Failed to resume recording'
          : 'Failed to pause recording');
    } finally {
      _isToggling = false;
    }
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
    _timer = null;

    // Guard against the native layer not actually recording.
    if (!(_controller?.value.isRecordingVideo ?? false)) {
      _set(state.copyWith(isRecording: false, isPaused: false));
      _onRecordingChanged?.call(false);
      _onRecordingPausedChanged?.call(false);
      return;
    }

    try {
      // A paused recording must be resumed before it can be stopped on some
      // platforms, otherwise stopVideoRecording can throw.
      if (state.isPaused) {
        try {
          await _controller!.resumeVideoRecording();
        } catch (_) {}
        _set(state.copyWith(isPaused: false));
      }
      final file = await _controller!.stopVideoRecording();
      _set(state.copyWith(isRecording: false, isPaused: false));
      _onRecordingChanged?.call(false);
      _onRecordingPausedChanged?.call(false);
      _onCapture?.call(file);
    } on CameraException catch (e) {
      _set(state.copyWith(isRecording: false, isPaused: false));
      _onRecordingChanged?.call(false);
      _onRecordingPausedChanged?.call(false);
      final msg = e.description?.toLowerCase() ?? '';
      _onNotice?.call(
        msg.contains('assertwriter') || msg.contains('assetwriter')
            ? 'Recording was too short. Please try again.'
            : 'Failed to save recording',
      );
    } catch (e) {
      _set(state.copyWith(isRecording: false, isPaused: false));
      _onRecordingPausedChanged?.call(false);
      _onNotice?.call('Failed to stop recording: $e');
    }
  }

  Future<void> _stopRecordingIfActive() async {
    if (state.isRecording || (_controller?.value.isRecordingVideo ?? false)) {
      _timer?.cancel();
      _timer = null;
      try {
        await _controller?.stopVideoRecording();
      } catch (_) {}
      _set(state.copyWith(isRecording: false, isPaused: false));
      _onRecordingChanged?.call(false);
      _onRecordingPausedChanged?.call(false);
    }
  }
}
