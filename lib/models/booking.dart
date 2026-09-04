import 'attendance_record.dart' show AttendanceParse;
import 'booking_query.dart';

/// Nested customer contact on a booking.
class BookingContact {
  final int? id;
  final String name;
  final String? phone;
  final String? email;

  const BookingContact({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
  });

  factory BookingContact.fromJson(Map<String, dynamic> json) => BookingContact(
        id: AttendanceParse.toInt(json['id']),
        name: (json['name'] ?? '').toString(),
        phone: AttendanceParse.toNullableString(json['phone']),
        email: AttendanceParse.toNullableString(json['email']),
      );
}

/// A lightweight named reference (office / vehicle) embedded in a booking.
class NamedRef {
  final int? id;
  final String name;

  const NamedRef({required this.id, required this.name});

  factory NamedRef.fromJson(Map<String, dynamic> json) => NamedRef(
        id: AttendanceParse.toInt(json['id']),
        name: (json['name'] ?? '').toString(),
      );
}

/// An inspector's assigned inspection job.
///
/// Maps `GET /api/inspector/bookings` (and `/{id}`). Carries the full inspector
/// workflow state — WhatsApp intimation, arrival, inspection start/complete, and
/// the report screenshot — so a single [Booking] drives the whole detail screen.
class Booking {
  final int id;
  final String orderId;
  final DateTime? bookingDate;
  final String? slot;
  final String? assignedTime;
  final String status;
  final String? vehicleNumber;
  final bool isNewCarPdi;

  final String? googleMapsLink;
  final double? latitude;
  final double? longitude;
  final String? addressLine1;
  final String? addressLine2;
  final String? city;
  final String? state;
  final String? pincode;
  final String? notes;

  final BookingContact? customer;
  final NamedRef? office;
  final NamedRef? vehicle;

  // Inspector workflow state.
  final bool whatsappIntimated;
  final String? whatsappScreenshotUrl;
  final DateTime? arrivedAt;
  final DateTime? inspectionStartedAt;
  final DateTime? inspectionCompletedAt;
  final int? inspectionDurationMinutes;
  final String? reportScreenshotUrl;

  /// Present only on the detail endpoint.
  final List<BookingQuery> queries;

  const Booking({
    required this.id,
    required this.orderId,
    required this.bookingDate,
    required this.slot,
    required this.assignedTime,
    required this.status,
    required this.vehicleNumber,
    required this.isNewCarPdi,
    required this.googleMapsLink,
    required this.latitude,
    required this.longitude,
    required this.addressLine1,
    required this.addressLine2,
    required this.city,
    required this.state,
    required this.pincode,
    required this.notes,
    required this.customer,
    required this.office,
    required this.vehicle,
    required this.whatsappIntimated,
    required this.whatsappScreenshotUrl,
    required this.arrivedAt,
    required this.inspectionStartedAt,
    required this.inspectionCompletedAt,
    required this.inspectionDurationMinutes,
    required this.reportScreenshotUrl,
    this.queries = const [],
  });

  // ─────────────────────────── Workflow helpers ───────────────────────────

  bool get hasArrived => arrivedAt != null;
  bool get inspectionStarted => inspectionStartedAt != null;
  bool get inspectionCompleted => inspectionCompletedAt != null;
  bool get reportUploaded =>
      reportScreenshotUrl != null && reportScreenshotUrl!.isNotEmpty;

  /// True once every workflow step is done.
  bool get isFullyDone =>
      whatsappIntimated &&
      hasArrived &&
      inspectionStarted &&
      inspectionCompleted &&
      reportUploaded;

  /// The next action the inspector should take, as a stable step key. Drives
  /// which button the detail screen highlights.
  BookingStep get nextStep {
    if (!whatsappIntimated) return BookingStep.whatsapp;
    if (!hasArrived) return BookingStep.arrive;
    if (!inspectionStarted) return BookingStep.start;
    if (!inspectionCompleted) return BookingStep.complete;
    if (!reportUploaded) return BookingStep.report;
    return BookingStep.done;
  }

  String get shortAddress {
    final parts = [addressLine1, addressLine2, city]
        .map((e) => e?.trim())
        .where((e) => e != null && e.isNotEmpty)
        .toList();
    return parts.isEmpty ? 'No address' : parts.join(', ');
  }

  String get fullAddress {
    final parts = [addressLine1, addressLine2, city, state, pincode]
        .map((e) => e?.trim())
        .where((e) => e != null && e.isNotEmpty)
        .toList();
    return parts.join(', ');
  }

  String get vehicleTitle {
    final name = vehicle?.name.trim();
    if (name != null && name.isNotEmpty) {
      return vehicleNumber != null && vehicleNumber!.isNotEmpty
          ? '$name • $vehicleNumber'
          : name;
    }
    return vehicleNumber ?? 'Vehicle';
  }

  factory Booking.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? mapOf(dynamic v) =>
        v is Map ? v.cast<String, dynamic>() : null;

    final rawQueries = json['queries'];
    final queries = rawQueries is List
        ? rawQueries
            .whereType<Map>()
            .map((e) => BookingQuery.fromJson(e.cast<String, dynamic>()))
            .toList()
        : <BookingQuery>[];

    return Booking(
      id: AttendanceParse.toInt(json['id']) ?? 0,
      orderId: (json['order_id'] ?? '').toString(),
      bookingDate: AttendanceParse.toDate(json['booking_date']),
      slot: AttendanceParse.toNullableString(json['slot']),
      assignedTime:
          AttendanceParse.toNullableString(json['inspector_assigned_time']),
      status: (json['status'] ?? 'assigned').toString(),
      vehicleNumber: AttendanceParse.toNullableString(json['vehicle_number']),
      isNewCarPdi: json['is_new_car_pdi'] == true,
      googleMapsLink:
          AttendanceParse.toNullableString(json['google_maps_link']),
      latitude: AttendanceParse.toDouble(json['latitude']),
      longitude: AttendanceParse.toDouble(json['longitude']),
      addressLine1: AttendanceParse.toNullableString(json['address_line_1']),
      addressLine2: AttendanceParse.toNullableString(json['address_line_2']),
      city: AttendanceParse.toNullableString(json['city']),
      state: AttendanceParse.toNullableString(json['state']),
      pincode: AttendanceParse.toNullableString(json['pincode']),
      notes: AttendanceParse.toNullableString(json['notes']),
      customer: mapOf(json['customer']) == null
          ? null
          : BookingContact.fromJson(mapOf(json['customer'])!),
      office: mapOf(json['office']) == null
          ? null
          : NamedRef.fromJson(mapOf(json['office'])!),
      vehicle: mapOf(json['vehicle']) == null
          ? null
          : NamedRef.fromJson(mapOf(json['vehicle'])!),
      whatsappIntimated: json['whatsapp_intimated'] == true,
      whatsappScreenshotUrl:
          AttendanceParse.toNullableString(json['whatsapp_screenshot_url']),
      arrivedAt: AttendanceParse.toDate(json['arrived_at']),
      inspectionStartedAt:
          AttendanceParse.toDate(json['inspection_started_at']),
      inspectionCompletedAt:
          AttendanceParse.toDate(json['inspection_completed_at']),
      inspectionDurationMinutes:
          AttendanceParse.toInt(json['inspection_duration_minutes']),
      reportScreenshotUrl:
          AttendanceParse.toNullableString(json['report_screenshot_url']),
      queries: queries,
    );
  }
}

/// The inspector workflow steps, in order.
enum BookingStep { whatsapp, arrive, start, complete, report, done }
