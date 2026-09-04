import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/booking.dart';
import '../models/pagination_data_model.dart';
import '../services/api_services.dart';
import '../services/notification_service.dart';

part 'bookings_provider.g.dart';

/// The tabs on the Work Assigned screen.
///
/// The first three map straight onto the bookings endpoint's `filter` query
/// param. `done` has no server-side equivalent — the endpoint only filters by
/// date (`today` / `upcoming` / `past` / `all`) — so it reads the widest filter
/// and keeps the jobs whose whole inspector workflow is finished. That is the
/// same predicate behind the card's DONE badge, so the tab holds exactly the
/// jobs badged DONE elsewhere.
enum WorkTab {
  today('today', 'Today'),
  upcoming('upcoming', 'Upcoming'),
  past('past', 'Past'),
  done('all', 'Done');

  const WorkTab(this.serverFilter, this.label);

  /// The `filter` value to send to `GET /api/inspector/bookings`.
  final String serverFilter;

  /// The tab's display name.
  final String label;

  /// Whether results still need narrowing after the fetch. When true the
  /// server's pagination totals describe more rows than this tab shows.
  bool get isClientFiltered => this == WorkTab.done;

  /// Whether [booking] belongs on this tab.
  bool matches(Booking booking) =>
      this != WorkTab.done || booking.isFullyDone;

  /// Whether the tab carries a count badge. Done cannot: its total is only
  /// knowable by paging the entire history and filtering client-side, so there
  /// is no cheap number to show.
  bool get showsCount => this == WorkTab.today || this == WorkTab.upcoming;
}

/// Thrown when a booking fetch fails and there is nothing to show; surfaces as
/// the list's `AsyncError` so the screen can render its retry view.
class BookingFetchException implements Exception {
  const BookingFetchException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A revision counter that increments whenever the inspector's assigned work
/// may have changed. Every [BookingList] watches it, so one bump refetches all
/// four tabs at once — which is what makes a job that moves between tabs (an
/// assignment landing in Today, a finished job appearing in Done) show up
/// everywhere rather than only on the tab in view.
///
/// Kept alive so a bump is never lost to the screen being disposed between the
/// push arriving and the list rebuilding.
@Riverpod(keepAlive: true)
class AssignmentsRevision extends _$AssignmentsRevision {
  @override
  int build() {
    // Bridge the FCM signal into the provider graph. NotificationService is
    // static (it has to be reachable from the background isolate's top-level
    // handler), so it publishes a ValueNotifier rather than holding a Ref.
    final source = NotificationService.assignmentsRevision;
    void onChanged() {
      if (ref.mounted) state = source.value;
    }

    source.addListener(onChanged);
    ref.onDispose(() => source.removeListener(onChanged));
    return source.value;
  }

  /// Bump for a change this device made itself — finishing a job's workflow, or
  /// coming back to the foreground after a push was drawn by the OS while the
  /// app was backgrounded (no Dart code ran for it).
  void bump() => state++;
}

/// One tab's loaded jobs, plus where the next page starts.
class BookingListState {
  const BookingListState({
    required this.bookings,
    required this.hasMore,
    required this.nextPage,
    required this.total,
    this.loadingMore = false,
  });

  final List<Booking> bookings;

  /// Whether the server has further pages to walk.
  final bool hasMore;

  /// The page number [BookingList.loadMore] should request next.
  final int nextPage;

  /// The server's total for this filter, or null on a client-filtered tab
  /// where that total counts rows this tab doesn't show.
  final int? total;

  final bool loadingMore;

  BookingListState copyWith({
    List<Booking>? bookings,
    bool? hasMore,
    int? nextPage,
    int? total,
    bool? loadingMore,
  }) =>
      BookingListState(
        bookings: bookings ?? this.bookings,
        hasMore: hasMore ?? this.hasMore,
        nextPage: nextPage ?? this.nextPage,
        total: total ?? this.total,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

/// The paginated job list for one [WorkTab].
@riverpod
class BookingList extends _$BookingList {
  /// How many matching jobs to gather before returning, on a client-filtered
  /// tab. Without this a page holding no matches would render as an empty list
  /// even when later pages hold plenty.
  static const _minMatches = 10;

  /// Cap on pages walked per load, so a long history with few matches can't
  /// walk the whole archive in one go. Infinite scroll resumes where this
  /// stopped.
  static const _maxPagesPerLoad = 5;

  @override
  Future<BookingListState> build(WorkTab tab) {
    // Refetch when work is assigned, without the UI having to ask.
    ref.watch(assignmentsRevisionProvider);
    return _fetch(page: 1, existing: const []);
  }

  /// Append the next page. A no-op when a page is already in flight or the
  /// server has nothing more.
  Future<void> loadMore() async {
    // Riverpod 3: AsyncValue.value is nullable (valueOrNull is gone).
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;

    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final next =
          await _fetch(page: current.nextPage, existing: current.bookings);
      if (ref.mounted) state = AsyncData(next);
    } on BookingFetchException {
      // Keep what is already on screen; the scroll listener will retry when the
      // user scrolls again.
      if (ref.mounted) state = AsyncData(current.copyWith(loadingMore: false));
    }
  }

  /// Re-fetch from page one, for pull-to-refresh.
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  /// Walks pages from [page], keeping the ones [WorkTab.matches] accepts and
  /// appending them to [existing].
  Future<BookingListState> _fetch({
    required int page,
    required List<Booking> existing,
  }) async {
    final collected = [...existing];
    final startedWith = collected.length;
    var nextPage = page;
    var hasMore = true;
    int? total;
    String? error;

    // One request is enough for a server-filtered tab. A client-filtered one
    // keeps pulling until it has a screenful of matches, the server runs out,
    // or it hits the page cap.
    for (var walked = 0; walked < _maxPagesPerLoad; walked++) {
      final res = await ApiService.getInspectorBookings(
        filter: tab.serverFilter,
        page: nextPage,
      );

      if (res['success'] != true) {
        error = res['message']?.toString() ?? 'Failed to load bookings.';
        break;
      }

      collected.addAll((res['bookings'] as List).cast<Booking>().where(tab.matches));

      final pagination = res['pagination'] as PaginationData?;
      hasMore = pagination?.hasMore ?? false;
      total = pagination?.total;
      nextPage = (pagination?.currentPage ?? nextPage) + 1;

      if (!hasMore) break;
      if (!tab.isClientFiltered ||
          collected.length - startedWith >= _minMatches) {
        break;
      }
    }

    // A walk that collected something keeps it; only a load that came back with
    // nothing at all is a failure.
    if (error != null && collected.length == startedWith) {
      throw BookingFetchException(error);
    }

    return BookingListState(
      bookings: collected,
      hasMore: hasMore,
      nextPage: nextPage,
      total: tab.isClientFiltered ? null : total,
    );
  }
}
