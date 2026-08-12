import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/booking.dart';
import '../../models/booking_query.dart';
import '../../services/api_services.dart';

/// Drives a single inspection job through its workflow:
/// WhatsApp intimation → arrival → inspection start → complete → report upload,
/// plus a query thread with admin.
class BookingDetailScreen extends StatefulWidget {
  const BookingDetailScreen({super.key, required this.bookingId});

  final int bookingId;

  @override
  State<BookingDetailScreen> createState() => _BookingDetailScreenState();
}

class _BookingDetailScreenState extends State<BookingDetailScreen> {
  static const _primary = Color(0xFF0052CC);
  static const _onSurface = Color(0xFF172B4D);
  static const _surface = Color(0xFFF4F7FA);
  static const _muted = Color(0xFF44546F);
  static const _border = Color(0xFFE2E8F0);
  static const _green = Color(0xFF10B981);
  static const _amber = Color(0xFFF59E0B);

  final _picker = ImagePicker();

  Booking? _booking;
  bool _loading = true;
  String? _error;

  /// The workflow step currently running (so we can show a spinner on it).
  BookingStep? _busyStep;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await ApiService.getInspectorBookingDetail(widget.bookingId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['success'] == true) {
        _booking = res['booking'] as Booking;
      } else {
        _error = res['message']?.toString() ?? 'Failed to load booking.';
      }
    });
  }

  // ─────────────────────────────── Actions ──────────────────────────────

  Future<void> _runStep(BookingStep step, Future<Map<String, dynamic>> Function() action) async {
    setState(() => _busyStep = step);
    final res = await action();
    if (!mounted) return;
    setState(() => _busyStep = null);
    final ok = res['success'] == true;
    _toast(res['message']?.toString() ?? (ok ? 'Done.' : 'Something went wrong.'),
        color: ok ? _green : Colors.redAccent);
    if (ok) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _whatsappIntimation() async {
    final path = await _pickScreenshot();
    if (path == null) return;
    await _runStep(
      BookingStep.whatsapp,
      () => ApiService.uploadWhatsappIntimation(widget.bookingId, path),
    );
  }

  Future<void> _markArrived() async {
    final pos = await _currentPosition();
    await _runStep(
      BookingStep.arrive,
      () => ApiService.markArrived(
        widget.bookingId,
        latitude: pos?.latitude,
        longitude: pos?.longitude,
      ),
    );
  }

  Future<void> _startInspection() => _runStep(
        BookingStep.start,
        () => ApiService.markInspectionStarted(widget.bookingId),
      );

  Future<void> _completeInspection() => _runStep(
        BookingStep.complete,
        () => ApiService.markInspectionCompleted(widget.bookingId),
      );

  Future<void> _uploadReport() async {
    final path = await _pickScreenshot();
    if (path == null) return;
    await _runStep(
      BookingStep.report,
      () => ApiService.uploadReportScreenshot(widget.bookingId, path),
    );
  }

  Future<String?> _pickScreenshot() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      return file?.path;
    } catch (e) {
      log('pickScreenshot error: $e', name: 'booking');
      _toast('Could not pick image.', color: Colors.redAccent);
      return null;
    }
  }

  Future<Position?> _currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
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
      log('geolocator error: $e', name: 'booking');
      return null;
    }
  }

  Future<void> _openMaps() async {
    final b = _booking;
    if (b == null) return;
    final url = b.googleMapsLink ??
        (b.latitude != null && b.longitude != null
            ? 'https://www.google.com/maps/search/?api=1&query=${b.latitude},${b.longitude}'
            : null);
    if (url == null) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _callCustomer() async {
    final phone = _booking?.customer?.phone;
    if (phone == null || phone.isEmpty) return;
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _openQuerySheet() async {
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QuerySheet(bookingId: widget.bookingId),
    );
    if (submitted == true && mounted) {
      _changed = true;
      await _load();
    }
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
    // Return whether anything changed so the list can refresh on the way back.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {},
      child: Scaffold(
        backgroundColor: _surface,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          foregroundColor: _onSurface,
          title: const Text(
            'Inspection Job',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: _onSurface),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changed),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _buildError()
                : _buildContent(),
      ),
    );
  }

  Widget _buildError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: _muted),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );

  Widget _buildContent() {
    final b = _booking!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _headerCard(b),
          const SizedBox(height: 16),
          _sectionTitle('Location'),
          _locationCard(b),
          const SizedBox(height: 16),
          _sectionTitle('Workflow'),
          _workflowCard(b),
          const SizedBox(height: 16),
          _sectionTitle('Queries'),
          _queriesCard(b),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 2),
        child: Text(t,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: _onSurface)),
      );

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _border),
        ),
        child: child,
      );

  Widget _headerCard(Booking b) {
    final dateStr = b.bookingDate != null
        ? DateFormat('EEE, d MMM yyyy').format(b.bookingDate!)
        : '—';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  b.vehicleTitle,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: _onSurface),
                ),
              ),
              if (b.isNewCarPdi)
                _pill('PDI', const Color(0xFFEFF6FF), _primary),
            ],
          ),
          const SizedBox(height: 4),
          Text('Order ${b.orderId}',
              style: const TextStyle(fontSize: 13, color: _muted)),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.event, size: 16, color: _muted),
              const SizedBox(width: 6),
              Text(dateStr,
                  style: const TextStyle(fontSize: 13, color: _muted)),
              const SizedBox(width: 14),
              const Icon(Icons.schedule, size: 16, color: _muted),
              const SizedBox(width: 6),
              Text(b.assignedTime ?? (b.slot != null ? 'Slot ${b.slot}' : '—'),
                  style: const TextStyle(fontSize: 13, color: _muted)),
            ],
          ),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: _statusChip(b.status)),
          if (b.customer != null) ...[
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.person_outline, size: 18, color: _muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(b.customer!.name,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _onSurface)),
                ),
                if ((b.customer!.phone ?? '').isNotEmpty)
                  IconButton(
                    onPressed: _callCustomer,
                    icon: const Icon(Icons.call, color: _green),
                    tooltip: 'Call customer',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _locationCard(Booking b) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.location_on_outlined,
                    size: 18, color: _muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    b.fullAddress.isEmpty ? 'No address on file' : b.fullAddress,
                    style: const TextStyle(fontSize: 14, color: _onSurface),
                  ),
                ),
              ],
            ),
            if ((b.notes ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.sticky_note_2_outlined,
                      size: 18, color: _amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(b.notes!,
                        style: const TextStyle(fontSize: 13, color: _muted)),
                  ),
                ],
              ),
            ],
            if (b.googleMapsLink != null ||
                (b.latitude != null && b.longitude != null)) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openMaps,
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Open in Maps'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _primary,
                  side: const BorderSide(color: _primary),
                ),
              ),
            ],
          ],
        ),
      );

  Widget _workflowCard(Booking b) {
    final next = b.nextStep;
    return _card(
      child: Column(
        children: [
          _stepRow(
            step: BookingStep.whatsapp,
            label: 'WhatsApp intimation',
            done: b.whatsappIntimated,
            isNext: next == BookingStep.whatsapp,
            actionLabel: 'Upload screenshot',
            onTap: _whatsappIntimation,
          ),
          _stepRow(
            step: BookingStep.arrive,
            label: 'Mark arrived',
            done: b.hasArrived,
            isNext: next == BookingStep.arrive,
            subtitle: b.arrivedAt != null ? _time(b.arrivedAt!) : null,
            actionLabel: 'I have arrived',
            onTap: _markArrived,
          ),
          _stepRow(
            step: BookingStep.start,
            label: 'Start inspection',
            done: b.inspectionStarted,
            isNext: next == BookingStep.start,
            subtitle:
                b.inspectionStartedAt != null ? _time(b.inspectionStartedAt!) : null,
            actionLabel: 'Start',
            onTap: _startInspection,
          ),
          _stepRow(
            step: BookingStep.complete,
            label: 'Complete inspection',
            done: b.inspectionCompleted,
            isNext: next == BookingStep.complete,
            subtitle: b.inspectionCompletedAt != null
                ? '${_time(b.inspectionCompletedAt!)}'
                    '${b.inspectionDurationMinutes != null ? ' · ${b.inspectionDurationMinutes} min' : ''}'
                : null,
            actionLabel: 'Complete',
            onTap: _completeInspection,
          ),
          _stepRow(
            step: BookingStep.report,
            label: 'Upload report screenshot',
            done: b.reportUploaded,
            isNext: next == BookingStep.report,
            actionLabel: 'Upload report',
            onTap: _uploadReport,
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _stepRow({
    required BookingStep step,
    required String label,
    required bool done,
    required bool isNext,
    String? subtitle,
    required String actionLabel,
    required VoidCallback onTap,
    bool isLast = false,
  }) {
    final busy = _busyStep == step;
    final Color dotColor = done ? _green : (isNext ? _primary : _border);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: done ? _green : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: dotColor, width: 2),
                ),
                child: done
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                      width: 2, color: done ? _green : _border),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: done ? _muted : _onSurface)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(fontSize: 12, color: _muted)),
                  ],
                  if (isNext && !done) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 38,
                      child: FilledButton(
                        onPressed: busy ? null : onTap,
                        style: FilledButton.styleFrom(
                            backgroundColor: _primary),
                        child: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Text(actionLabel),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _queriesCard(Booking b) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (b.queries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('No queries yet.',
                    style: TextStyle(fontSize: 13, color: _muted)),
              )
            else
              ...b.queries.map(_queryTile),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openQuerySheet,
              icon: const Icon(Icons.help_outline, size: 18),
              label: const Text('Ask admin a question'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _primary,
                side: const BorderSide(color: _primary),
              ),
            ),
          ],
        ),
      );

  Widget _queryTile(BookingQuery q) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(q.message,
                style: const TextStyle(fontSize: 13, color: _onSurface)),
            const SizedBox(height: 6),
            if (q.isAnswered && q.adminReply != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.support_agent, size: 16, color: _green),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(q.adminReply!,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF065F46))),
                    ),
                  ],
                ),
              )
            else
              _pill('Awaiting reply', const Color(0xFFFFFBEB), _amber),
          ],
        ),
      );

  Widget _statusChip(String status) {
    final s = status.toLowerCase();
    Color bg = const Color(0xFFEFF6FF), fg = _primary;
    if (s == 'completed') {
      bg = const Color(0xFFECFDF5);
      fg = _green;
    } else if (s == 'pending') {
      bg = const Color(0xFFFFFBEB);
      fg = _amber;
    }
    return _pill(status.toUpperCase(), bg, fg);
  }

  Widget _pill(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
      );

  String _time(DateTime d) => DateFormat('d MMM, h:mm a').format(d);
}

/// Bottom sheet to compose and submit a new query for a booking.
class _QuerySheet extends StatefulWidget {
  const _QuerySheet({required this.bookingId});

  final int bookingId;

  @override
  State<_QuerySheet> createState() => _QuerySheetState();
}

class _QuerySheetState extends State<_QuerySheet> {
  final _controller = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _submitting = true);
    final res = await ApiService.submitBookingQuery(widget.bookingId, text);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (res['success'] == true) {
      Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['message']?.toString() ?? 'Failed to submit.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Ask admin a question',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF172B4D))),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              maxLines: 4,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: 'Describe the issue…',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0052CC),
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Submit'),
            ),
          ],
        ),
      ),
    );
  }
}
