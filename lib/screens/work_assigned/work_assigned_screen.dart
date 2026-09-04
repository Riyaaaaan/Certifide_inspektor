import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/booking.dart';
import '../../services/api_services.dart';
import '../../services/notification_service.dart';
import '../home/car_spy/car_spy_data.dart';
import 'booking_detail_screen.dart';

/// The inspector's assigned inspection jobs, backed by
/// `GET /api/inspector/bookings`. Three filter tabs — Today / Upcoming / Past —
/// each drive the `filter` query param. Tapping a job opens its workflow.
class WorkAssignedScreen extends StatefulWidget {
  const WorkAssignedScreen({super.key});

  @override
  State<WorkAssignedScreen> createState() => _WorkAssignedScreenState();
}

class _WorkAssignedScreenState extends State<WorkAssignedScreen>
    with SingleTickerProviderStateMixin {
  static const _filters = ['today', 'upcoming', 'past'];
  static const _labels = ['Today', 'Upcoming', 'Past'];

  /// Whether each tab shows its job count in the label. Per the design, Today
  /// and Upcoming do; Past stays plain.
  static const _showCount = [true, true, false];

  late final TabController _tabController;

  /// Total job count per filter, reported by each list once it loads. Null until
  /// the first successful fetch (so the label shows no badge yet).
  final Map<String, int?> _counts = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _filters.length, vsync: this);
    _prefetchCounts();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Load the badge counts up front so they show without opening each tab. The
  /// currently-visible tab loads its own data (and reports its count), so we
  /// only prefetch the other badged tabs with a minimal `per_page: 1` request.
  void _prefetchCounts() {
    for (var i = 0; i < _filters.length; i++) {
      if (!_showCount[i] || i == _tabController.index) continue;
      _fetchCount(_filters[i]);
    }
  }

  Future<void> _fetchCount(String filter) async {
    final res =
        await ApiService.getInspectorBookings(filter: filter, perPage: 1);
    if (!mounted || res['success'] != true) return;
    final total =
        res['pagination']?.total ?? (res['bookings'] as List).length;
    _setCount(filter, total);
  }

  void _setCount(String filter, int count) {
    if (_counts[filter] == count) return;
    if (mounted) setState(() => _counts[filter] = count);
  }

  /// A tab label; for Today/Upcoming it appends a count badge once known.
  Widget _buildTab(int index) {
    final count = _counts[_filters[index]];
    final showBadge = _showCount[index] && count != null;
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_labels[index]),
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
          indicatorColor: CarSpyColors.primary,
          indicatorWeight: 2.5,
          labelColor: CarSpyColors.primary,
          unselectedLabelColor: CarSpyColors.onSurfaceVariant,
          labelStyle:
              const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          tabs: [
            for (var i = 0; i < _labels.length; i++) _buildTab(i),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          for (final f in _filters)
            _BookingList(filter: f, onCount: (c) => _setCount(f, c)),
        ],
      ),
    );
  }
}

/// A paginated, refreshable list of bookings for one filter.
class _BookingList extends StatefulWidget {
  const _BookingList({required this.filter, this.onCount});

  final String filter;

  /// Reports the total job count for this filter (from pagination) so the parent
  /// can badge the tab.
  final ValueChanged<int>? onCount;

  @override
  State<_BookingList> createState() => _BookingListState();
}

class _BookingListState extends State<_BookingList>
    with AutomaticKeepAliveClientMixin {
  final _scrollController = ScrollController();
  final List<Booking> _bookings = [];

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 300 &&
        !_loadingMore &&
        _hasMore) {
      _load();
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
        _hasMore = true;
      });
    } else {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    }

    final res = await ApiService.getInspectorBookings(
      filter: widget.filter,
      page: reset ? 1 : _page,
    );
    if (!mounted) return;

    int? total;
    setState(() {
      _loading = false;
      _loadingMore = false;
      if (res['success'] == true) {
        final list = (res['bookings'] as List).cast<Booking>();
        if (reset) _bookings.clear();
        _bookings.addAll(list);
        final pagination = res['pagination'];
        _hasMore = pagination?.hasMore ?? false;
        if (_hasMore) _page = (pagination?.currentPage ?? _page) + 1;
        // Prefer the server's total; fall back to what we've loaded.
        total = pagination?.total ?? _bookings.length;
      } else {
        _error = res['message']?.toString() ?? 'Failed to load bookings.';
      }
    });
    if (total != null) widget.onCount?.call(total!);
  }

  Future<void> _openBooking(Booking b) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => BookingDetailScreen(bookingId: b.id),
      ),
    );
    if (changed == true) _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading && _bookings.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _bookings.isEmpty) {
      return _ErrorView(message: _error!, onRetry: () => _load(reset: true));
    }
    if (_bookings.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: ListView(
          children: const [
            SizedBox(height: 120),
            _EmptyView(),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: _bookings.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _bookings.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _BookingCard(
            booking: _bookings[index],
            onTap: () => _openBooking(_bookings[index]),
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
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.assignment_turned_in_outlined,
              size: 56, color: CarSpyColors.outlineVariant),
          SizedBox(height: 12),
          Text(
            'No jobs here',
            style: TextStyle(
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
