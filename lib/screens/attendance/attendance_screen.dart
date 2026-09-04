import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/inspector_leave.dart';
import '../../providers/user_provider.dart';
import '../../services/api_services.dart';
import 'admin_attendance_screen.dart';
import 'inspector_attendance_screen.dart';
import 'leave_application_screen.dart';

/// Master switch for the inspector attendance tracker (check-in/check-out).
///
/// While `false`, inspectors see only their leave history with an
/// "Attendance — coming soon" banner. Flip to `true` to restore the full
/// check-in/out page ([InspectorAttendanceScreen]) — nothing else needs to
/// change.
const bool kInspectorAttendanceEnabled = true;

/// Entry point for the attendance tab. Admins get the management view wired to
/// the admin leave/attendance API; inspectors get their own attendance page
/// (check-in/out) with leaves tucked behind a button — unless the tracker is
/// disabled via [kInspectorAttendanceEnabled], in which case they see the
/// leave history with a "coming soon" banner.
class AttendanceScreen extends ConsumerWidget {
  const AttendanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(userProvider.select((s) => s.isAdmin()));
    if (isAdmin) return const AdminAttendanceScreen();
    return kInspectorAttendanceEnabled
        ? const InspectorAttendanceScreen()
        : const InspectorLeavesScreen(showComingSoon: true);
  }
}

/// The signed-in inspector's leave history. Reached from the Attendance page's
/// "Leaves" button (so it shows a back arrow), or rendered as the tab root with
/// [showComingSoon] while the attendance tracker is disabled.
class InspectorLeavesScreen extends StatefulWidget {
  const InspectorLeavesScreen({super.key, this.showComingSoon = false});

  /// When true, an "Attendance — coming soon" banner sits above the list.
  final bool showComingSoon;

  @override
  State<InspectorLeavesScreen> createState() => _InspectorLeavesScreenState();
}

class _InspectorLeavesScreenState extends State<InspectorLeavesScreen> {
  static const _primary = Color(0xFF0F172A);
  static const _accent = Color(0xFF3B82F6);
  static const _accentLight = Color(0xFFEFF6FF);
  static const _surface = Color(0xFFF8FAFC);
  static const _textSecondary = Color(0xFF64748B);
  static const _border = Color(0xFFE2E8F0);
  static const _green = Color(0xFF10B981);
  static const _greenLight = Color(0xFFECFDF5);
  static const _red = Color(0xFFEF4444);
  static const _redLight = Color(0xFFFEF2F2);
  static const _amber = Color(0xFFF59E0B);
  static const _amberLight = Color(0xFFFFFBEB);

  static const _statusFilters = ['all', 'pending', 'approved', 'rejected'];

  final _scrollController = ScrollController();
  final List<InspectorLeave> _leaves = [];

  String _status = 'all';
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  final Set<int> _busyIds = {};

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
            _scrollController.position.maxScrollExtent - 240 &&
        !_loadingMore &&
        _hasMore &&
        !_loading) {
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
        _leaves.clear();
      });
    } else {
      if (_loadingMore) return;
      setState(() => _loadingMore = true);
    }

    final result = await ApiService.getInspectorLeaves(
      page: _page,
      status: _status == 'all' ? null : _status,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      final fetched = (result['leaves'] as List).cast<InspectorLeave>();
      final pagination = result['pagination'];
      final lastPage = (pagination?.lastPage as int?) ?? _page;
      setState(() {
        _leaves.addAll(fetched);
        _hasMore = _page < lastPage && fetched.isNotEmpty;
        if (_hasMore) _page++;
        _loading = false;
        _loadingMore = false;
      });
    } else {
      setState(() {
        _error = result['message']?.toString() ?? 'Something went wrong';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _openApplyLeave() async {
    final submitted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const LeaveApplicationScreen()),
    );
    if (submitted == true) {
      _load(reset: true);
    }
  }

  Future<void> _cancel(InspectorLeave leave) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        backgroundColor: Colors.white,
        title: const Text(
          'Cancel leave request?',
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: _primary),
        ),
        content: Text(
          'Your pending request for '
          '${leave.leaveDate != null ? DateFormat('d MMM yyyy').format(leave.leaveDate!) : 'this date'} '
          'will be withdrawn.',
          style: const TextStyle(
              fontSize: 13, color: _textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep', style: TextStyle(color: _textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              foregroundColor: Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Cancel Request'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busyIds.add(leave.id));
    final result = await ApiService.cancelLeave(leave.id);
    if (!mounted) return;
    setState(() => _busyIds.remove(leave.id));

    if (result['success'] == true) {
      setState(() => _leaves.removeWhere((l) => l.id == leave.id));
      _toast(result['message']?.toString() ?? 'Leave request cancelled.',
          color: _green);
    } else {
      _toast(result['message']?.toString() ?? 'Could not cancel.', color: _red);
    }
  }

  void _toast(String msg, {required Color color}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// Reveals a leave card's reason / admin note (kept off the card itself).
  void _showDetail({
    required String title,
    required String body,
    required IconData icon,
    required Color color,
    required Color bg,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: _primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              body,
              style: const TextStyle(
                fontSize: 14,
                color: _primary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: _primary,
        title: const Text(
          'My Leaves',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: _primary,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: TextButton.icon(
              onPressed: _openApplyLeave,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Apply Leave'),
              style: TextButton.styleFrom(
                foregroundColor: _accent,
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.showComingSoon) _buildComingSoonBanner(),
          _buildFilterBar(),
          Expanded(
            child: RefreshIndicator(
              color: _accent,
              onRefresh: () => _load(reset: true),
              child: _buildBody(),
            ),
          ),
        ],
      ),
      floatingActionButton: _leaves.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _openApplyLeave,
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              elevation: 2,
              icon: const Icon(Icons.event_available_rounded, size: 20),
              label: const Text('Apply Leave',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
    );
  }

  /// Placeholder shown where the check-in/out tracker will live once enabled.
  Widget _buildComingSoonBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
        ),
        boxShadow: [
          BoxShadow(
            color: _primary.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.fingerprint_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Attendance',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _amber.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Coming soon',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: _amber,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Check-in / check-out tracking is on the way. For now, '
                  'manage your leaves below.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: _statusFilters.map((s) {
          final isSel = s == _status;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                if (s == _status) return;
                setState(() => _status = s);
                _load(reset: true);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isSel ? _accent : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isSel ? _accent : _border),
                ),
                child: Text(
                  s == 'all' ? 'All' : '${s[0].toUpperCase()}${s.substring(1)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isSel ? Colors.white : _primary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_error != null && _leaves.isEmpty) {
      return _buildScrollableMessage(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load leaves",
        subtitle: _error!,
        action: _RetryButton(onTap: () => _load(reset: true)),
      );
    }
    if (_leaves.isEmpty) {
      return _buildScrollableMessage(
        icon: Icons.beach_access_rounded,
        title: 'No leave requests yet',
        subtitle: 'Tap “Apply Leave” to request a day off.',
        action: Padding(
          padding: const EdgeInsets.only(top: 18),
          child: ElevatedButton.icon(
            onPressed: _openApplyLeave,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Apply Leave'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
      itemCount: _leaves.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        if (i >= _leaves.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
          );
        }
        return _buildLeaveCard(_leaves[i]);
      },
    );
  }

  Widget _buildScrollableMessage({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.16),
        Icon(icon, size: 56, color: const Color(0xFFCBD5E1)),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: _primary),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13, color: _textSecondary, height: 1.5),
          ),
        ),
        if (action != null) Center(child: action),
      ],
    );
  }

  Widget _buildLeaveCard(InspectorLeave leave) {
    final cfg = _statusConfig(leave.status);
    final busy = _busyIds.contains(leave.id);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: cfg.bg,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(cfg.icon, size: 22, color: cfg.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      leave.leaveDate != null
                          ? DateFormat('EEE, d MMM yyyy')
                              .format(leave.leaveDate!)
                          : 'Date unknown',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _primary,
                      ),
                    ),
                    if (leave.createdAt != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Requested ${DateFormat('d MMM').format(leave.createdAt!)}',
                        style: const TextStyle(
                            fontSize: 12, color: _textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              _StatusPill(label: cfg.label, color: cfg.color, bg: cfg.bg),
            ],
          ),
          if (leave.reason.isNotEmpty ||
              (leave.adminNote != null && leave.adminNote!.isNotEmpty)) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (leave.reason.isNotEmpty)
                  _DetailChip(
                    icon: Icons.notes_rounded,
                    label: 'Reason',
                    color: _accent,
                    bg: _accentLight,
                    onTap: () => _showDetail(
                      title: 'Reason',
                      body: leave.reason,
                      icon: Icons.notes_rounded,
                      color: _accent,
                      bg: _accentLight,
                    ),
                  ),
                if (leave.adminNote != null && leave.adminNote!.isNotEmpty)
                  _DetailChip(
                    icon: Icons.sticky_note_2_outlined,
                    label: 'Admin Note',
                    color: _amber,
                    bg: _amberLight,
                    onTap: () => _showDetail(
                      title: 'Admin Note',
                      body: leave.adminNote!,
                      icon: Icons.sticky_note_2_outlined,
                      color: _amber,
                      bg: _amberLight,
                    ),
                  ),
              ],
            ),
          ],
          if (leave.isPending) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => _cancel(leave),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(_red),
                        ),
                      )
                    : const Icon(Icons.close_rounded, size: 18),
                label: const Text('Cancel Request'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _red,
                  side: const BorderSide(color: _redLight),
                  backgroundColor: _redLight,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  _StatusCfg _statusConfig(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return const _StatusCfg(
          label: 'Approved',
          color: _green,
          bg: _greenLight,
          icon: Icons.check_circle_rounded,
        );
      case 'rejected':
        return const _StatusCfg(
          label: 'Rejected',
          color: _red,
          bg: _redLight,
          icon: Icons.cancel_rounded,
        );
      default:
        return const _StatusCfg(
          label: 'Pending',
          color: _amber,
          bg: _amberLight,
          icon: Icons.hourglass_top_rounded,
        );
    }
  }
}

class _StatusCfg {
  final String label;
  final Color color;
  final Color bg;
  final IconData icon;

  const _StatusCfg({
    required this.label,
    required this.color,
    required this.bg,
    required this.icon,
  });
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.color,
    required this.bg,
  });

  final String label;
  final Color color;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.bg,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color bg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.chevron_right_rounded, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onTap});

  final VoidCallback onTap;

  static const _accent = Color(0xFF3B82F6);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Retry'),
        style: OutlinedButton.styleFrom(
          foregroundColor: _accent,
          side: const BorderSide(color: _accent),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        ),
      ),
    );
  }
}
