import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../utils/connectivity_checker.dart';

part 'connectivity_provider.g.dart';

/// Single source of truth for whether the app can currently reach the backend.
///
/// It subscribes to OS connectivity changes ONCE, confirms real reachability
/// with a DNS probe, and exposes a single `bool`. Every screen watches this
/// provider instead of calling [ConnectivityChecker.canReachServer] on its own,
/// so when the connection drops or is restored every listener updates at once
/// from this one event — no per-screen polling.
@Riverpod(keepAlive: true)
class ConnectivityStatus extends _$ConnectivityStatus {
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounce;

  @override
  bool build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _subscription?.cancel();
    });
    _start();
    // Optimistic until the first probe resolves; corrected within milliseconds.
    return true;
  }

  Future<void> _start() async {
    await _probe();
    // The probe is a DNS lookup with a 3s timeout; the provider can be disposed
    // while it runs. onDispose has already cancelled a still-null subscription
    // by then, so subscribing now would leak a listener nothing ever cancels.
    if (!ref.mounted) return;
    _subscription =
        Connectivity().onConnectivityChanged.listen((results) {
      final hasInterface =
          results.isNotEmpty && results.first != ConnectivityResult.none;
      // A Wi-Fi/cellular handoff emits a burst of events; coalesce them into a
      // single update after a short quiet period.
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 800), () {
        if (!hasInterface) {
          _set(false);
        } else {
          unawaited(_probe());
        }
      });
    });
  }

  Future<void> _probe() async {
    _set(await ConnectivityChecker.canReachServer());
  }

  void _set(bool online) {
    // Reading or writing `state` after disposal throws. Every caller arrives
    // here across an async gap (the DNS probe) or from a debounce timer, so the
    // provider may already be gone.
    if (!ref.mounted) return;
    if (state != online) state = online;
  }

  /// Imperative re-check (e.g. from a "Retry" button). Returns the fresh state.
  Future<bool> refresh() async {
    await _probe();
    // Assume reachable if we were disposed mid-probe; the value is unused then.
    return ref.mounted ? state : true;
  }
}
