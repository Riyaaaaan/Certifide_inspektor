// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connectivity_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Single source of truth for whether the app can currently reach the backend.
///
/// It subscribes to OS connectivity changes ONCE, confirms real reachability
/// with a DNS probe, and exposes a single `bool`. Every screen watches this
/// provider instead of calling [ConnectivityChecker.canReachServer] on its own,
/// so when the connection drops or is restored every listener updates at once
/// from this one event — no per-screen polling.

@ProviderFor(ConnectivityStatus)
const connectivityStatusProvider = ConnectivityStatusProvider._();

/// Single source of truth for whether the app can currently reach the backend.
///
/// It subscribes to OS connectivity changes ONCE, confirms real reachability
/// with a DNS probe, and exposes a single `bool`. Every screen watches this
/// provider instead of calling [ConnectivityChecker.canReachServer] on its own,
/// so when the connection drops or is restored every listener updates at once
/// from this one event — no per-screen polling.
final class ConnectivityStatusProvider
    extends $NotifierProvider<ConnectivityStatus, bool> {
  /// Single source of truth for whether the app can currently reach the backend.
  ///
  /// It subscribes to OS connectivity changes ONCE, confirms real reachability
  /// with a DNS probe, and exposes a single `bool`. Every screen watches this
  /// provider instead of calling [ConnectivityChecker.canReachServer] on its own,
  /// so when the connection drops or is restored every listener updates at once
  /// from this one event — no per-screen polling.
  const ConnectivityStatusProvider._()
      : super(
          from: null,
          argument: null,
          retry: null,
          name: r'connectivityStatusProvider',
          isAutoDispose: false,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$connectivityStatusHash();

  @$internal
  @override
  ConnectivityStatus create() => ConnectivityStatus();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$connectivityStatusHash() =>
    r'ee4f7848e0364e8dfd11075a8d73643f40f47d78';

/// Single source of truth for whether the app can currently reach the backend.
///
/// It subscribes to OS connectivity changes ONCE, confirms real reachability
/// with a DNS probe, and exposes a single `bool`. Every screen watches this
/// provider instead of calling [ConnectivityChecker.canReachServer] on its own,
/// so when the connection drops or is restored every listener updates at once
/// from this one event — no per-screen polling.

abstract class _$ConnectivityStatus extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<bool, bool>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<bool, bool>, bool, Object?, Object?>;
    element.handleValue(ref, created);
  }
}
