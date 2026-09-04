import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/booking.dart';
import '../../providers/bookings_provider.dart';
import '../../services/notification_service.dart';
import '../home/car_spy/car_spy_data.dart';
import 'booking_detail_screen.dart';

/// The inspector's assigned inspection jobs, backed by
/// `GET /api/inspector/bookings`. Four tabs — Today / Upcoming / Past / Done
/// (see [WorkTab]). Tapping a job opens its workflow.
///
/// The lists refetch on their own when work is assigned, so a new job appears
/// without a manual pull-to-refresh: every list watches
/// [assignmentsRevisionProvider], which an assignment push bumps.
class WorkAssignedScreen extends ConsumerStatefulWidget {
  const WorkAssignedScreen({super.key});

  @override
  ConsumerState<WorkAssignedScreen> createState() => _WorkAssignedScreenState();
}

class _WorkAssignedScreenState extends ConsumerState<WorkAssignedScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabController;

  /// Whether the app has actually been backgrounded since the last refresh.
  /// `inactive` alone is not enough to refetch on: a heads-up notification, the
  /// notification shade, a permission dialog and the app switcher all bounce
  /// through inactive→resumed while the screen stays visible, and each one
  /// would otherwise cost a full reload of every tab.
  bool _wasBackgrounded = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: WorkTab.values.length, vsync: this);
    // The home shell keeps this screen alive in an IndexedStack, so initState
    // runs once per session — hence the lifecycle observer rather than a
    // refresh on first build.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Covers a push that arrived while the app was backgrounded and was drawn
    // by the OS: no Dart code ran for it, and the inspector may open the app
    // from the launcher rather than by tapping the notification.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _wasBackgrounded = true;
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      ref.read(assignmentsRevisionProvider.notifier).bump();
    }
  }

  /// A tab label; Today/Upcoming append a count badge once known.
  Widget _buildTab(WorkTab tab) {
    // Watching the tab's own provider for the badge also warms it, so switching
    // to Today or Upcoming shows data immediately.
    final count = tab.showsCount
        ? ref.watch(
            bookingListProvider(tab).select((s) => s.value?.total))
        : null;
    final showBadge = tab.showsCount && count != null;
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tab.label),
          if (showBadge) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: count == 0
                    ? const Color(0xFFE2E8F0)
                    : CarSpyColors.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: count == 0
                      ? CarSpyColors.onSurfaceVariant
                      : Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Debug helper — fires a local notification of the given type. Tapping it
  /// should route to Work Assigned (assignment/today) or Attendance (reminders).
  void _fireTestNotification(String type) {
    const titles = {
      'inspection_assigned': 'New inspection assigned',
      'inspections_today': "Today's inspections",
      'attendance_check_in_reminder': 'Check-in reminder',
      'attendance_check_out_reminder': 'Check-out reminder',
    };
    const bodies = {
      'inspection_assigned': 'Swift Dzire — 18 Jun at 10:30',
      'inspections_today': 'Swift Dzire 09:30, i20 14:00',
      'attendance_check_in_reminder': 'You have 2 inspections today. Check in.',
      'attendance_check_out_reminder': "Don't forget to check out for today.",
    };
    NotificationService.showLocal(
      title: titles[type] ?? 'Certifide',
      body: bodies[type] ?? '',
      type: type,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CarSpyColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          'Work Assigned',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF172B4D),
          ),
        ),
        actions: [
          // Debug-only: fire a local test notification to verify display + the
          // tap-to-tab routing without waiting on the backend. Stripped from
          // release builds.
          if (kDebugMode)
            PopupMenuButton<String>(
              icon: const Icon(Icons.notifications_active_outlined,
                  color: Color(0xFF172B4D)),
              tooltip: 'Test notification',
              onSelected: _fireTestNotification,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'inspection_assigned',
                  child: Text('Inspection assigned → Work Assigned'),
                ),
                PopupMenuItem(
                  value: 'inspections_today',
                  child: Text("Today's inspections → Work Assigned"),
                ),
                PopupMenuItem(
                  value: 'attendance_check_in_reminder',
                  child: Text('Check-in reminder → Attendance'),
                ),
                PopupMenuItem(
                  value: 'attendance_check_out_reminder',
                  child: Text('Check-out reminder → Attendance'),
                ),
              ],
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          // Scrollable so the tabs size to their content: four fixed tabs
          // overflowed once Done was added, and a two-digit count badge would
          // push it further. Left-aligned, so it still reads as a normal tab
          // row while it fits.
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelPadding: const EdgeInsets.symmetric(horizontal: 14),
          indicatorColor: CarSpyColors.primary,
          indicatorWeight: 2.5,
          labelColor: CarSpyColors.primary,
          unselectedLabelColor: CarSpyColors.onSurfaceVariant,
          labelStyle:
              const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          tabs: [for (final tab in WorkTab.values) _buildTab(tab)],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [for (final tab in WorkTab.values) _BookingList(tab: tab)],
      ),
    );
  }
}

/// A paginated, refreshable list of the jobs on one [WorkTab].
class _BookingList extends ConsumerStatefulWidget {
  const _BookingList({required this.tab});

  final WorkTab tab;

  @override
  ConsumerState<_BookingList> createState() => _BookingListState();
}

class _BookingListState extends ConsumerState<_BookingList>
    with AutomaticKeepAliveClientMixin {
  final _scrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      // The notifier ignores this while a page is in flight or the server has
      // nothing more, so there is no need to track that here.
      ref.read(bookingListProvider(widget.tab).notifier).loadMore();
    }
  }

  Future<void> _openBooking(Booking b) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => BookingDetailScreen(bookingId: b.id)),
    );
    if (!mounted || changed != true) return;
    // Refresh every tab, not just this one: finishing the workflow moves the
    // job into Done, and reloading only this list would leave Done stale.
    ref.read(assignmentsRevisionProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final async = ref.watch(bookingListProvider(widget.tab));

    return async.when(
      // A bump of assignmentsRevision is a dependency change, which Riverpod
      // treats as a reload — and `when` shows `loading` on a reload by default.
      // Without this, every auto-refresh would blank the jobs behind a spinner;
      // with it the current list stays put until the new data lands.
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorView(
        message: e is BookingFetchException
            ? e.message
            : 'Failed to load bookings.',
        onRetry: () => ref.invalidate(bookingListProvider(widget.tab)),
      ),
      data: (state) => _buildList(state),
    );
  }

  Widget _buildList(BookingListState state) {
    Future<void> refresh() =>
        ref.read(bookingListProvider(widget.tab).notifier).refresh();

    if (state.bookings.isEmpty) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            _EmptyView(
              message: widget.tab == WorkTab.done
                  ? 'No completed jobs yet'
                  : 'No jobs here',
            ),
          ],
        ),
      );
    }

    final showFooter = state.hasMore;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: state.bookings.length + (showFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= state.bookings.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final booking = state.bookings[index];
          return _BookingCard(
            booking: booking,
            onTap: () => _openBooking(booking),
          );
        },
      ),
    );
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({required this.booking, required this.onTap});

  final Booking booking;
  final VoidCallback onTap;

  static const _green = Color(0xFF10B981);
  static const _amber = Color(0xFFF59E0B);
  static const _primary = CarSpyColors.primary;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final dateStr =
        b.bookingDate != null ? DateFormat('d MMM').format(b.bookingDate!) : '';
    final timeStr = b.assignedTime ?? (b.slot != null ? 'Slot ${b.slot}' : '');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    b.vehicleTitle,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF172B4D),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _statusBadge(b),
              ],
            ),
            const SizedBox(height: 4),
            Text('Order ${b.orderId}',
                style: const TextStyle(
                    fontSize: 12, color: CarSpyColors.onSurfaceVariant)),
            const SizedBox(height: 10),
            _infoRow(Icons.location_on_outlined, b.shortAddress),
            const SizedBox(height: 6),
            _infoRow(
              Icons.access_time_rounded,
              [dateStr, timeStr].where((e) => e.isNotEmpty).join(' · '),
            ),
            const SizedBox(height: 12),
            _progressBar(b),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge(Booking b) {
    if (b.isFullyDone) {
      return _pill('DONE', const Color(0xFFECFDF5), _green);
    }
    if (b.inspectionCompleted) {
      return _pill('REPORT PENDING', const Color(0xFFFFFBEB), _amber);
    }
    if (b.hasArrived) {
      return _pill('IN PROGRESS', const Color(0xFFEFF6FF), _primary);
    }
    return _pill(b.status.toUpperCase(), const Color(0xFFEFF6FF), _primary);
  }

  Widget _progressBar(Booking b) {
    final steps = [
      b.whatsappIntimated,
      b.hasArrived,
      b.inspectionStarted,
      b.inspectionCompleted,
      b.reportUploaded,
    ];
    final done = steps.where((e) => e).length;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: done / steps.length,
              minHeight: 6,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: AlwaysStoppedAnimation(
                  b.isFullyDone ? _green : _primary),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('$done/${steps.length}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: CarSpyColors.onSurfaceVariant)),
      ],
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: CarSpyColors.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text.isEmpty ? '—' : text,
            style: const TextStyle(
                fontSize: 13, color: CarSpyColors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _pill(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
      );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.assignment_turned_in_outlined,
              size: 56, color: CarSpyColors.outlineVariant),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(
              fontSize: 16,
              color: CarSpyColors.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: CarSpyColors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
