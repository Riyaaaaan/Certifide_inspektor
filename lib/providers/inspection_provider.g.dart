// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'inspection_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(InspectionNotifier)
const inspectionProvider = InspectionNotifierProvider._();

final class InspectionNotifierProvider
    extends $NotifierProvider<InspectionNotifier, InspectionState> {
  const InspectionNotifierProvider._()
      : super(
          from: null,
          argument: null,
          retry: null,
          name: r'inspectionProvider',
          isAutoDispose: false,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$inspectionNotifierHash();

  @$internal
  @override
  InspectionNotifier create() => InspectionNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(InspectionState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<InspectionState>(value),
    );
  }
}

String _$inspectionNotifierHash() =>
    r'1cc6e2d7ee76b9461a5bd77e3f46bd09e6a5aa63';

abstract class _$InspectionNotifier extends $Notifier<InspectionState> {
  InspectionState build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<InspectionState, InspectionState>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<InspectionState, InspectionState>,
        InspectionState,
        Object?,
        Object?>;
    element.handleValue(ref, created);
  }
}
