// Guards the disposal-safety of ConnectivityStatus.
//
// The notifier probes reachability across an async gap (a DNS lookup with a 3s
// timeout) and then writes `state`. If the provider is disposed while that
// probe is in flight, touching `state` throws:
//
//   "Cannot use the Ref of connectivityStatusProvider after it has been
//    disposed."
//
// It also used to subscribe to connectivity events AFTER the await, so a
// dispose landing mid-probe ran onDispose against a still-null subscription and
// the listener created afterwards was never cancelled — a permanent leak.
//
// These drive the real notifier (not a fake), with the platform channels
// stubbed so no plugin is required.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:certifide_inspektor/providers/connectivity_provider.dart';
import 'package:certifide_inspektor/utils/connectivity_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const eventChannelName =
      'dev.fluttercommunity.plus/connectivity_status';

  setUp(() {
    // connectivity_plus asks for the current status over a MethodChannel and
    // streams changes over an EventChannel. Stub both so build() runs without
    // the plugin present.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async => ['wifi']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(eventChannelName, (message) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(eventChannelName, null);
    ConnectivityChecker.debugReachableOverride = null;
  });

  group('ConnectivityStatus — disposal safety', () {
    test(
        'Given the provider is disposed mid-probe, When the probe resolves, '
        'Then writing state does not throw', () async {
      ConnectivityChecker.debugReachableOverride = true;

      final container = ProviderContainer();
      // Reading starts build() -> _start() -> await _probe().
      container.read(connectivityStatusProvider);

      // Dispose while the probe is still pending on its await.
      container.dispose();

      // Let the probe resolve and attempt its state write. Before the
      // ref.mounted guards this threw from the microtask queue.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });

    test(
        'Given a disposed provider, When refresh is called, Then it returns '
        'instead of throwing on the state read', () async {
      ConnectivityChecker.debugReachableOverride = false;

      final container = ProviderContainer();
      final notifier = container.read(connectivityStatusProvider.notifier);
      container.dispose();

      // refresh() probes then reads state; both are guarded now.
      await expectLater(notifier.refresh(), completes);
    });

    test(
        'Given a live provider, When the probe reports reachable, Then the '
        'state becomes true', () async {
      ConnectivityChecker.debugReachableOverride = true;

      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(connectivityStatusProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(connectivityStatusProvider), isTrue);
    });

    test(
        'Given a live provider, When the probe reports unreachable, Then the '
        'state becomes false', () async {
      ConnectivityChecker.debugReachableOverride = false;

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Starts optimistic, then the probe corrects it.
      expect(container.read(connectivityStatusProvider), isTrue);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(connectivityStatusProvider), isFalse,
          reason: 'the optimistic default must be corrected by the probe');
    });

    test(
        'Given repeated create/dispose cycles, When each is torn down mid-'
        'probe, Then none of them throw', () async {
      ConnectivityChecker.debugReachableOverride = true;

      for (var i = 0; i < 20; i++) {
        final container = ProviderContainer();
        container.read(connectivityStatusProvider);
        container.dispose();
      }

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });
  });
}
