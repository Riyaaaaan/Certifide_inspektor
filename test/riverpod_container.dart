// Shared ProviderContainer helper for provider tests.
//
// Providers are never mocked — their dependencies are overridden instead — so
// every test builds a real container and swaps only what it needs to control.
//
// Riverpod 3 ships `ProviderContainer.test()`, which disposes itself at the end
// of the test. That matters here: InspectionNotifier is keepAlive and registers
// a connectivity listener in build(), so a container left alive would keep
// listening and leak into later tests.
//
// Note `Override` is not in flutter_riverpod's export list, so this wrapper
// takes the overrides untyped and forwards them — keeping the transitive
// `package:riverpod` import out of every test file.

import 'package:flutter_riverpod/flutter_riverpod.dart';

ProviderContainer createContainer({
  ProviderContainer? parent,
  List<dynamic> overrides = const [],
  List<ProviderObserver>? observers,
}) {
  return ProviderContainer.test(
    parent: parent,
    overrides: overrides.cast(),
    observers: observers,
  );
}
