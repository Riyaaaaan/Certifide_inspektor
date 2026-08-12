import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../../models/attendance_record.dart';
import '../../services/api_services.dart';
import 'attendance_screen.dart';

/// The inspector's Attendance page — a single daily check-in / check-out backed
/// by the API (`POST /inspector/attendance/check-in`, `/check-out`,
/// `GET /inspector/attendance`).
///
/// The backend keeps exactly one attendance row per day: a check-in (with
/// location, and a server-decided `available`/`working` type) and an optional
/// check-out that closes the day and yields `worked_minutes`. This screen shows
/// today's status up top and the month's history below.
class InspectorAttendanceScreen extends StatefulWidget {
  const InspectorAttendanceScreen({super.key});

  @override
  State<InspectorAttendanceScreen> createState() =>
      _InspectorAttendanceScreenState();
}

class _InspectorAttendanceScreenState extends State<InspectorAttendanceScreen> {
  static const _primary = Color(0xFF0F172A);
  static const _accent = Color(0xFF3B82F6);
  static const _surface = Color(0xFFF8FAFC);
  static const _textSecondary = Color(0xFF64748B);
  static const _border = Color(0xFFE2E8F0);
  static const _green = Color(0xFF10B981);
  static const _red = Color(0xFFEF4444);

  final List<AttendanceRecord> _history = [];

  bool _loading = true;
  bool _punching = false; // check-in / check-out in flight
  bool _locating = false;
  String? _error;

  /// Live ticker so the "open" hero card shows elapsed time counting up.
  Timer? _ticker;

  /// Today's record, if any (drives the hero card).
  AttendanceRecord? get _today {
    final now = DateTime.now();
    for (final r in _history) {
      final d = r.date;
      if (d != null &&
          d.year == now.year &&
          d.month == now.month &&
          d.day == now.day) {
        return r;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final open = _today?.isOpen ?? false;
    if (open && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!open) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final month = DateFormat('yyyy-MM').format(DateTime.now());
    final res = await ApiService.getInspectorAttendance(month: month);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['success'] == true) {
        _history
          ..clear()
          ..addAll((res['records'] as List).cast<AttendanceRecord>());
        _history.sort((a, b) => (b.date ?? DateTime(0))
            .compareTo(a.date ?? DateTime(0)));
      } else {
        _error = res['message']?.toString() ?? 'Failed to load attendance.';
      }
    });
    _syncTicker();
  }

  // ─────────────────────────────── Actions ──────────────────────────────

  Future<void> _checkIn() => _punch(checkIn: true);
  Future<void> _checkOut() => _punch(checkIn: false);

  Future<void> _punch({required bool checkIn}) async {
    setState(() {
      _punching = true;
      _locating = true;
    });
    final pos = await _currentPosition();
    if (!mounted) return;
    setState(() => _locating = false);

    final res = checkIn
        ? await ApiService.checkInAttendance(
            latitude: pos?.latitude, longitude: pos?.longitude)
        : await ApiService.checkOutAttendance(
            latitude: pos?.latitude, longitude: pos?.longitude);
    if (!mounted) return;
    setState(() => _punching = false);

    if (res['success'] == true) {
      _mergeRecord(res['record'] as AttendanceRecord);
      _toast(
        checkIn
            ? (pos == null
                ? 'Checked in — location unavailable.'
                : 'Checked in successfully.')
            : 'Checked out. Have a good one!',
        color: checkIn ? _green : _accent,
      );
      _syncTicker();
    } else {
      // 422 = already checked in/out today; reload to reflect true state.
      if (res['alreadyCheckedIn'] == true) await _load();
      _toast(res['message']?.toString() ?? 'Something went wrong.',
          color: _red);
    }
  }

  /// Insert or replace today's record with the server's version.
  void _mergeRecord(AttendanceRecord record) {
    setState(() {
      _history.removeWhere((r) => r.id == record.id);
      _history.insert(0, record);
      _history.sort(
          (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)));
    });
  }

  Future<Position?> _currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        log('geolocator: location services disabled', name: 'attendance');
        return null;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 12));
    } catch (e) {
      log('geolocator error: $e', name: 'attendance');
      return null;
    }
  }

  void _openLeaves() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InspectorLeavesScreen()),
    );
  }

  void _toast(String msg, {required Color color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ──────────────────────────────── Build ───────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          'Attendance',
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w700, color: _primary),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: _openLeaves,
              icon: const Icon(Icons.beach_access_rounded, size: 18),
              label: const Text('Leaves'),
              style: TextButton.styleFrom(
                foregroundColor: _accent,
                backgroundColor: const Color(0xFFEFF6FF),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  if (_error != null) _errorBanner(_error!),
                  _heroCard(),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Text(
                        'This month',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _primary),
                      ),
                      const Spacer(),
                      if (_history.isNotEmpty)
                        Text(
                          '${_history.length} day${_history.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                              fontSize: 12, color: _textSecondary),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_history.isEmpty)
                    _emptyState()
                  else
                    ..._history.map(_historyCard),
                ],
              ),
            ),
    );
  }

  Widget _errorBanner(String msg) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: _red, size: 20),
            const SizedBox(width: 8),
            Expanded(
                child: Text(msg,
                    style: const TextStyle(fontSize: 13, color: _red))),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );

  Widget _heroCard() {
    final today = _today;
    final checkedIn = today != null;
    final open = today?.isOpen ?? false;

    final gradient = open
        ? const [Color(0xFF059669), Color(0xFF10B981)]
        : (checkedIn
            ? const [Color(0xFF334155), Color(0xFF1E293B)]
            : const [Color(0xFF1E293B), Color(0xFF0F172A)]);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
        boxShadow: [
          BoxShadow(
            color: (open ? _green : _primary).withValues(alpha: 0.25),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statusPill(today),
          const SizedBox(height: 16),
          if (!checkedIn) ...[
            const Text(
              'Not checked in',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white),
            ),
            const SizedBox(height: 4),
            const Text(
              'Check in to mark your attendance and share your location.',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ] else ...[
            Text(
              open ? _elapsedText(today.checkIn!) : _workedText(today),
              style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(
              open
                  ? 'Checked in at ${DateFormat('h:mm a').format(today.checkIn!)}'
                      '${today.hasLocation ? '  •  📍 Location captured' : ''}'
                  : 'Worked ${DateFormat('h:mm a').format(today.checkIn!)} – '
                      '${today.checkOut != null ? DateFormat('h:mm a').format(today.checkOut!) : '—'}',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ],
          const SizedBox(height: 18),
          _heroButton(today),
        ],
      ),
    );
  }

  Widget _heroButton(AttendanceRecord? today) {
    final open = today?.isOpen ?? false;
    final checkedOut = today?.isCheckedOut ?? false;

    if (checkedOut) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Day complete ✓',
          style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15),
        ),
      );
    }

    final label = open ? 'Check Out' : 'Check In';
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: _punching ? null : (open ? _checkOut : _checkIn),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: open ? _green : _primary,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
        icon: _punching
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(open ? Icons.logout_rounded : Icons.login_rounded),
        label: Text(
          _punching ? (_locating ? 'Getting location…' : 'Please wait…') : label,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
    );
  }

  Widget _statusPill(AttendanceRecord? today) {
    String text;
    if (today == null) {
      text = 'TODAY';
    } else if (today.isOpen) {
      text = today.isWorking ? 'WORKING • ACTIVE' : 'AVAILABLE • ACTIVE';
    } else {
      text = 'CHECKED OUT';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
                color: Colors.white, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }

  Widget _historyCard(AttendanceRecord r) {
    final dateStr = r.date != null
        ? DateFormat('EEE, d MMM').format(r.date!)
        : 'Unknown date';
    final Color typeColor = r.isWorking ? _accent : const Color(0xFF8B5CF6);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(dateStr,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _primary)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(r.type.toUpperCase(),
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: typeColor)),
              ),
              const Spacer(),
              if (r.isOpen)
                const Text('Open',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _green))
              else if (r.duration != null)
                Text(_fmtDuration(r.duration!),
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _textSecondary)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _timeCol(
                    'Check in',
                    r.checkIn != null
                        ? DateFormat('h:mm a').format(r.checkIn!)
                        : '—'),
              ),
              Expanded(
                child: _timeCol(
                    'Check out',
                    r.checkOut != null
                        ? DateFormat('h:mm a').format(r.checkOut!)
                        : '—'),
              ),
              Expanded(
                child: _timeCol(
                    'Location',
                    r.locationLabel ?? (r.hasLocation ? '📍 Captured' : '—')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timeCol(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: _textSecondary)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _primary)),
        ],
      );

  Widget _emptyState() => Container(
        padding: const EdgeInsets.symmetric(vertical: 40),
        alignment: Alignment.center,
        child: const Column(
          children: [
            Icon(Icons.event_available_outlined,
                size: 52, color: _border),
            SizedBox(height: 12),
            Text('No attendance yet this month',
                style: TextStyle(fontSize: 14, color: _textSecondary)),
          ],
        ),
      );

  String _elapsedText(DateTime since) {
    final d = DateTime.now().difference(since);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  String _workedText(AttendanceRecord r) {
    final dur = r.duration;
    if (dur == null) return '—';
    return _fmtDuration(dur);
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h ${m}m';
  }
}
