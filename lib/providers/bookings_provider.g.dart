// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bookings_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// A revision counter that increments whenever the inspector's assigned work
/// may have changed. Every [BookingList] watches it, so one bump refetches all
/// four tabs at once — which is what makes a job that moves between tabs (an
/// assignment landing in Today, a finished job appearing in Done) show up
/// everywhere rather than only on the tab in view.
///
/// Kept alive so a bump is never lost to the screen being disposed between the
/// push arriving and the list rebuilding.

@ProviderFor(AssignmentsRevision)
const assignmentsRevisionProvider = AssignmentsRevisionProvider._();

/// A revision counter that increments whenever the inspector's assigned work
/// may have changed. Every [BookingList] watches it, so one bump refetches all
/// four tabs at once — which is what makes a job that moves between tabs (an
/// assignment landing in Today, a finished job appearing in Done) show up
/// everywhere rather than only on the tab in view.
///
/// Kept alive so a bump is never lost to the screen being disposed between the
/// push arriving and the list rebuilding.
final class AssignmentsRevisionProvider
    extends $NotifierProvider<AssignmentsRevision, int> {
  /// A revision counter that increments whenever the inspector's assigned work
  /// may have changed. Every [BookingList] watches it, so one bump refetches all
  /// four tabs at once — which is what makes a job that moves between tabs (an
  /// assignment landing in Today, a finished job appearing in Done) show up
  /// everywhere rather than only on the tab in view.
  ///
  /// Kept alive so a bump is never lost to the screen being disposed between the
  /// push arriving and the list rebuilding.
  const AssignmentsRevisionProvider._()
      : super(
          from: null,
          argument: null,
          retry: null,
          name: r'assignmentsRevisionProvider',
          isAutoDispose: false,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$assignmentsRevisionHash();

  @$internal
  @override
  AssignmentsRevision create() => AssignmentsRevision();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(int value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<int>(value),
    );
  }
}

String _$assignmentsRevisionHash() =>
    r'd609b9060c06970fe83e3b72ce5030522e511eb0';

/// A revision counter that increments whenever the inspector's assigned work
/// may have changed. Every [BookingList] watches it, so one bump refetches all
/// four tabs at once — which is what makes a job that moves between tabs (an
/// assignment landing in Today, a finished job appearing in Done) show up
/// everywhere rather than only on the tab in view.
///
/// Kept alive so a bump is never lost to the screen being disposed between the
/// push arriving and the list rebuilding.

abstract class _$AssignmentsRevision extends $Notifier<int> {
  int build();
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build();
    final ref = this.ref as $Ref<int, int>;
    final element = ref.element
        as $ClassProviderElement<AnyNotifier<int, int>, int, Object?, Object?>;
    element.handleValue(ref, created);
  }
}

/// The paginated job list for one [WorkTab].

@ProviderFor(BookingList)
const bookingListProvider = BookingListFamily._();

/// The paginated job list for one [WorkTab].
final class BookingListProvider
    extends $AsyncNotifierProvider<BookingList, BookingListState> {
  /// The paginated job list for one [WorkTab].
  const BookingListProvider._(
      {required BookingListFamily super.from, required WorkTab super.argument})
      : super(
          retry: null,
          name: r'bookingListProvider',
          isAutoDispose: true,
          dependencies: null,
          $allTransitiveDependencies: null,
        );

  @override
  String debugGetCreateSourceHash() => _$bookingListHash();

  @override
  String toString() {
    return r'bookingListProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  BookingList create() => BookingList();

  @override
  bool operator ==(Object other) {
    return other is BookingListProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$bookingListHash() => r'0010a86585b3fbcc75403d9dff6d408ac9a098e1';

/// The paginated job list for one [WorkTab].

final class BookingListFamily extends $Family
    with
        $ClassFamilyOverride<BookingList, AsyncValue<BookingListState>,
            BookingListState, FutureOr<BookingListState>, WorkTab> {
  const BookingListFamily._()
      : super(
          retry: null,
          name: r'bookingListProvider',
          dependencies: null,
          $allTransitiveDependencies: null,
          isAutoDispose: true,
        );

  /// The paginated job list for one [WorkTab].

  BookingListProvider call(
    WorkTab tab,
  ) =>
      BookingListProvider._(argument: tab, from: this);

  @override
  String toString() => r'bookingListProvider';
}

/// The paginated job list for one [WorkTab].

abstract class _$BookingList extends $AsyncNotifier<BookingListState> {
  late final _$args = ref.$arg as WorkTab;
  WorkTab get tab => _$args;

  FutureOr<BookingListState> build(
    WorkTab tab,
  );
  @$mustCallSuper
  @override
  void runBuild() {
    final created = build(
      _$args,
    );
    final ref =
        this.ref as $Ref<AsyncValue<BookingListState>, BookingListState>;
    final element = ref.element as $ClassProviderElement<
        AnyNotifier<AsyncValue<BookingListState>, BookingListState>,
        AsyncValue<BookingListState>,
        Object?,
        Object?>;
    element.handleValue(ref, created);
  }
}
