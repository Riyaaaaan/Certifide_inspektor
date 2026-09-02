import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Shared across [SectionCameraCard] and [SectionVideoCameraCard] so that
/// switching between photo and video mode properly waits for the previous
/// controller to release camera hardware before the next one initialises.
Future<void>? cameraCardPendingDisposal;

/// Disposes [controller], swallowing the `PlatformException` that
/// camera_android_camerax throws when `dispose()` runs before the preview's
/// surface producer finished initialising:
///
///   IllegalStateException: releaseFlutterSurfaceTexture() cannot be called if
///   the flutterSurfaceProducer for the camera preview has not yet been
///   initialized.
///
/// This happens when the user navigates away (e.g. tapping next/previous
/// quickly) while a controller is still starting up. The returned future always
/// completes normally so callers awaiting [cameraCardPendingDisposal] never see
/// an unhandled rejection — there is nothing to release in that state anyway.
Future<void> safeDisposeCamera(CameraController? controller) async {
  if (controller == null) return;
  try {
    await controller.dispose();
  } catch (_) {
    // Controller was disposed before fully initialising — safe to ignore.
  }
}

class SectionCameraCard extends StatefulWidget {
  final double height;
  final BorderRadius borderRadius;
  final void Function(XFile file)? onCapture;
  final VoidCallback? onPickFromGallery;

  /// Shown above the preview so users know what this photo is for.
  final String? instructionText;

  /// When false the card is a pure viewfinder — no instruction text overlay
  /// and no bottom shutter/gallery row. Use [onCaptureReady] to trigger
  /// capture from an external button.
  final bool showControls;

  /// Called once the camera is initialized, passing a function that takes a
  /// photo when invoked. Only useful when [showControls] is false.
  final void Function(VoidCallback captureNow)? onCaptureReady;

  /// Called once the camera is initialized, passing a function that opens
  /// the fullscreen preview. Only useful when [showControls] is false.
  final void Function(VoidCallback enlarge)? onEnlargeReady;

  /// Called once the camera is initialized, passing a function that cycles
  /// flash mode. Only useful when [showControls] is false.
  final void Function(VoidCallback toggleFlash)? onFlashReady;

  /// Called whenever the flash mode changes so the parent can update its UI.
  final void Function(FlashMode mode)? onFlashModeChanged;

  const SectionCameraCard({
    super.key,
    this.height = 220,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.onCapture,
    this.onPickFromGallery,
    this.instructionText,
    this.showControls = true,
    this.onCaptureReady,
    this.onEnlargeReady,
    this.onFlashReady,
    this.onFlashModeChanged,
  });

  @override
  State<SectionCameraCard> createState() => _SectionCameraCardState();
}

class _SectionCameraCardState extends State<SectionCameraCard>
    with WidgetsBindingObserver {
  // Uses the library-level [cameraCardPendingDisposal] shared with
  // SectionVideoCameraCard so mode switches don't conflict on hardware.
  static Future<void>? get _pendingDisposal => cameraCardPendingDisposal;
  static set _pendingDisposal(Future<void>? v) => cameraCardPendingDisposal = v;

  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _isInitialized = false;
  bool _isInitializing = false;
  // When dispose() is called while _isInitializing, we can't safely call
  // controller.dispose() yet — doing so while initialize() is in-flight causes
  // "CameraController used after being disposed" unhandled exceptions from the
  // platform channel callback. Set this flag instead and let _tryStartCamera
  // do the actual disposal once initialize() resolves.
  bool _isDisposePending = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _isCapturing = false;
  int _currentCameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;
  // Incremented on every inactive/paused and widget-dispose to cancel in-flight inits.
  int _initGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Cancel any in-flight init (e.g. waiting for iOS permission dialog).
      _initGeneration++;
      _isInitializing = false;
      _disposeController();
      if (mounted) {
        setState(() {
          _isInitialized = false;
        });
      }
    } else if (state == AppLifecycleState.resumed && mounted) {
      _initCamera();
    }
  }

  void _disposeController() {
    if (_isInitializing) {
      // Defer: calling controller.dispose() while initialize() is in-flight
      // causes an unhandled platform-channel callback to fire on the disposed
      // controller. Mark the flag and let _tryStartCamera dispose it after init.
      _isDisposePending = true;
      return;
    }
    _isDisposePending = false;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      // Store the async disposal future so the next card can await it.
      _pendingDisposal = safeDisposeCamera(controller);
    }
  }

  Future<void> _initCamera() async {
    if (_isInitializing) return;
    _isInitializing = true;
    final myGen = ++_initGeneration;

    try {
      // Yield one tick so Flutter finishes reconciliation before we touch
      // hardware (the old card's dispose() sets _pendingDisposal).
      await Future.delayed(Duration.zero);
      if (!mounted || _initGeneration != myGen) return;

      // Wait for the previous card's camera controller to fully release.
      final disposal = _pendingDisposal;
      if (disposal != null) {
        _pendingDisposal = null;
        await disposal.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      if (!mounted || _initGeneration != myGen) return;

      if (mounted) {
        setState(() {
          _hasError = false;
          _errorMessage = '';
          _isInitialized = false;
        });
      }

      final hasPermission = await _ensureCameraPermission();

      // On iOS the permission dialog causes a brief inactive→resumed cycle which
      // disposes our controller.  Re-wait for that disposal before proceeding.
      if (!mounted || _initGeneration != myGen) return;
      final postPermDisposal = _pendingDisposal;
      if (postPermDisposal != null) {
        _pendingDisposal = null;
        await postPermDisposal.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      if (!mounted || _initGeneration != myGen) return;

      if (!hasPermission) {
        if (mounted) {
          setState(() {
            _hasError = true;
            _isInitialized = false;
            _errorMessage =
                'Camera permission is required to capture inspection photos';
          });
        }
        return;
      }

      _cameras = await availableCameras();
      if (!mounted || _initGeneration != myGen) return;
      if (_cameras == null || _cameras!.isEmpty) {
        if (mounted) {
          setState(() {
            _hasError = true;
            _errorMessage = 'No cameras available';
          });
        }
        return;
      }

      final backCameraIndex = _cameras!.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      _currentCameraIndex = backCameraIndex >= 0 ? backCameraIndex : 0;

      for (int attempt = 0; attempt < 3; attempt++) {
        if (!mounted || _initGeneration != myGen) return;

        if (attempt > 0) {
          final prev = _pendingDisposal;
          _pendingDisposal = null;
          if (prev != null) {
            await prev.timeout(
              const Duration(seconds: 1),
              onTimeout: () {},
            );
          } else {
            await Future.delayed(const Duration(milliseconds: 600));
          }
          if (!mounted || _initGeneration != myGen) return;
        }

        final ok = await _tryStartCamera(_cameras![_currentCameraIndex]);
        if (ok) return;
      }

      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Camera unavailable. Tap to retry.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Failed to initialize camera';
        });
      }
    } finally {
      if (_initGeneration == myGen) _isInitializing = false;
    }
  }

  /// Attempts to open [camera].  Disposes any existing [_controller] first,
  /// waits for that disposal, then initialises a fresh controller.
  /// Returns [true] on success, [false] on failure.
  Future<bool> _tryStartCamera(CameraDescription camera) async {
    // Release the current (possibly-failed) controller and wait.
    final old = _controller;
    _controller = null;
    if (old != null) {
      final f = safeDisposeCamera(old);
      _pendingDisposal = f;
      await f.timeout(const Duration(seconds: 1), onTimeout: () {});
      _pendingDisposal = null;
    }

    if (!mounted) return false;

    // Stills are downscaled to 1920px and re-encoded at quality 85 before they
    // are stored (LocalStorageService.saveImage), so capturing at the sensor
    // maximum only buys a larger bitmap to allocate and throw away.
    final controller = CameraController(
      camera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = controller;

    try {
      await controller.initialize();
      // If a dispose() arrived while we were awaiting init, honour it now that
      // the platform callback has completed (so no "used after disposed" crash).
      if (_isDisposePending || !mounted || _controller != controller) {
        _isDisposePending = false;
        _pendingDisposal = safeDisposeCamera(controller);
        _controller = null;
        return false;
      }
      setState(() {
        _isInitialized = true;
        _hasError = false;
      });
      widget.onCaptureReady?.call(_captureImage);
      widget.onEnlargeReady?.call(_openFullscreenPreview);
      widget.onFlashReady?.call(_toggleFlash);
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

  Future<bool> _ensureCameraPermission() async {
    if (!(Platform.isIOS || Platform.isAndroid)) return true;

    var status = await Permission.camera.status;
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied || status.isRestricted) {
      return false;
    }

    status = await Permission.camera.request();
    return status.isGranted;
  }

  Future<void> _captureImage() async {
    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isCapturing) {
      return;
    }

    setState(() => _isCapturing = true);

    try {
      final XFile file = await _controller!.takePicture();
      widget.onCapture?.call(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to capture: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final next =
        _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _controller!.setFlashMode(next);
      if (mounted) {
        setState(() => _flashMode = next);
        widget.onFlashModeChanged?.call(next);
      }
    } catch (_) {}
  }

  void _openFullscreenPreview() {
    if (_controller == null || !_controller!.value.isInitialized) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullscreenCameraView(
          controller: _controller!,
          onCapture: (file) {
            widget.onCapture?.call(file);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _initGeneration++; // Invalidate any in-flight _initCamera call
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: widget.borderRadius,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.no_photography_outlined,
                    color: Colors.redAccent,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _errorMessage,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (Platform.isIOS) {
                        // On iOS, after the first denial the system will not
                        // re-prompt — the user must grant access via Settings.
                        await openAppSettings();
                        return;
                      }
                      final status = await Permission.camera.status;
                      if (status.isPermanentlyDenied || status.isRestricted) {
                        await openAppSettings();
                        return;
                      }
                      _initCamera();
                    },
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('Allow Camera Access'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_isInitialized || _controller == null) {
      return Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: widget.borderRadius,
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
              SizedBox(height: 12),
              Text(
                'Starting camera...',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: widget.borderRadius,
        border: widget.showControls
            ? Border.all(color: Colors.blue.withAlpha(100), width: 1.5)
            : null,
      ),
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: CameraPreview(_controller!),
            ),
            if (widget.showControls) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withAlpha(200),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.photo_camera_outlined,
                        color: Colors.white.withAlpha(230),
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.instructionText ??
                              'Center the subject in the frame, then tap Take photo',
                          style: TextStyle(
                            color: Colors.white.withAlpha(242),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withAlpha(200),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 6, right: 6),
                            child: widget.onPickFromGallery != null
                                ? Tooltip(
                                    message: 'Pick photo from gallery',
                                    child: Semantics(
                                      button: true,
                                      label: 'Pick from gallery',
                                      child: _CameraActionButton(
                                        icon: Icons.photo_library_outlined,
                                        onTap: widget.onPickFromGallery,
                                        size: 44,
                                      ),
                                    ),
                                  )
                                : const SizedBox(width: 44, height: 44),
                          ),
                        ),
                      ),
                      Tooltip(
                        message: 'Save this photo for the inspection',
                        child: Semantics(
                          button: true,
                          label: 'Take photo',
                          child: _CameraActionButton(
                            icon: Icons.camera_alt,
                            onTap: _isCapturing ? null : _captureImage,
                            size: 56,
                            isPrimary: true,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 6, left: 6),
                            child: Tooltip(
                              message: 'Open a larger view (same camera)',
                              child: Semantics(
                                button: true,
                                label: 'Larger preview',
                                child: _CameraActionButton(
                                  icon: Icons.open_in_full,
                                  onTap: _openFullscreenPreview,
                                  size: 44,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_isCapturing)
              Container(
                color: Colors.white.withAlpha(100),
                child: const Center(
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CameraActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final bool isPrimary;

  const _CameraActionButton({
    required this.icon,
    this.onTap,
    this.size = 32,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isPrimary
              ? Colors.white.withAlpha(230)
              : Colors.black.withAlpha(120),
          shape: BoxShape.circle,
          border: isPrimary ? Border.all(color: Colors.white, width: 2) : null,
        ),
        child: Icon(
          icon,
          color: isPrimary ? Colors.black87 : Colors.white,
          size: size * 0.5,
        ),
      ),
    );
  }
}

class _FullscreenCameraView extends StatefulWidget {
  final CameraController controller;
  final void Function(XFile file) onCapture;

  const _FullscreenCameraView({
    required this.controller,
    required this.onCapture,
  });

  @override
  State<_FullscreenCameraView> createState() => _FullscreenCameraViewState();
}

class _FullscreenCameraViewState extends State<_FullscreenCameraView> {
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _capture() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final file = await widget.controller.takePicture();
      widget.onCapture(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to capture: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: CameraPreview(widget.controller),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Material(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => Navigator.of(context).pop(),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Tap the white button below to take the photo',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 36,
            left: 0,
            right: 0,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: EdgeInsets.only(right: 8, bottom: 8),
                      child: SizedBox(width: 56, height: 56),
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Take photo',
                  child: Semantics(
                    button: true,
                    label: 'Take photo',
                    child: GestureDetector(
                      onTap: _isCapturing ? null : _capture,
                      child: Container(
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                        ),
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: _isCapturing ? Colors.grey : Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: _isCapturing
                              ? const Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.black54,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(left: 8, bottom: 8),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
