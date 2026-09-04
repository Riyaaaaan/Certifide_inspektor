// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'section_video_camera_card_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Owns the camera lifecycle and recording state for one card, keyed by a
/// stable [cardId] so each on-screen card gets its own autoDisposed instance.
/// Replaces the old `setState`-driven `State` so only widgets that watch this
/// provider rebuild, and the hardware is released via [Ref.onDispose].

@ProviderFor(VideoCardController)
const videoCardControllerProvider = VideoCardControllerFamily._();

/// Owns the camera lifecycle and recording state for one card, keyed by a
/// stable [cardId] so each on-screen card gets its own autoDisposed instance.
/// Replaces the old `setState`-driven `State` so only widgets that watch this
/// provider rebuild, and the hardware is released via [Ref.onDispose].
final class VideoCardControllerProvider
    extends $NotifierProvider<VideoCardController, VideoCardState> {
  /// Owns the camera lifecycle and recording state for one card, keyed by a
  /// stable [cardId] so each on-screen card gets its own autoDisposed instance.
  /// Replaces the old `setState`-driven `State` so only widgets that watch this
  /// provider rebuild, and the hardware is released via [Ref.onDispose].
  const VideoCardControllerProvider._(
      {required VideoCardControllerFamily super.from,
      required String super.argument})
      : super(
          retry: null,
          name: r'videoCardControllerProvider',
          isAutoDispose: true,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$videoCardControllerHash();

  @override
  String toString() {
    return r'videoCardControllerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  VideoCardController create() => VideoCardController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(VideoCardState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<VideoCardState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is VideoCardControllerProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$videoCardControllerHash() =>
    r'2c0fd381ebee559305a700fa557794b4fb056fac';

/// Owns the camera lifecycle and recording state for one card, keyed by a
/// stable [cardId] so each on-screen card gets its own autoDisposed instance.
/// Replaces the old `setState`-driven `State` so only widgets that watch this
/// provider rebuild, and the hardware is released via [Ref.onDispose].

final class VideoCardControllerFamily extends $Family
    with
        $ClassFamilyOverride<VideoCardController, VideoCardState,
            VideoCardState, VideoCardState, String> {
  const VideoCardControllerFamily._()
      : super(
          retry: null,
          name: r'videoCardControllerProvider',
          dependencies: null,
          $allTransitiveDependencies: null,
          isAutoDispose: true,
        );

  /// Owns the camera lifecycle and recording state for one card, keyed by a
  /// stable [cardId] so each on-screen card gets its own autoDisposed instance.
  /// Replaces the old `setState`-driven `State` so only widgets that watch this
  /// provider rebuild, and the hardware is released via [Ref.onDispose].

  VideoCardControllerProvider call(
    String cardId,
  ) =>
      VideoCardControllerProvider._(argument: cardId, from: this);

  @override
  String toString() => r'videoCardControllerProvider';
}

/// Owns the camera lifecycle and recording state for one card, keyed by a
/// stable [cardId] so each on-screen card gets its own autoDisposed instance.
/// Replaces the old `setState`-driven `State` so only widgets that watch this
/// provider rebuild, and the hardware is released via [Ref.onDispose].

abstract class _$VideoCardController extends $Notifier<VideoCardState> {
  late final _$args = ref.$arg as String;
  String get cardId => _$args;

  VideoCardState build(
    String cardId,
  );
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build(
      _$args,
    );
    final ref = this.ref as $Ref<VideoCardState, VideoCardState>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<VideoCardState, VideoCardState>,
        VideoCardState,
        Object?,
        Object?>;
    element.handleValue(ref, created);
  }
}
