/// A single attendance record — one row per inspector per day.
///
/// Maps the inspector check-in/out endpoints (`POST /inspector/attendance/
/// check-in`, `/check-out`, `GET /inspector/attendance`) and the admin list
/// (`GET /admin/attendance`).
///
/// `type` is `available` (free day — inspector marked themselves present) or
/// `working` (has bookings that day). The day stays "open" until [checkOut] is
/// recorded; [workedMinutes] is server-computed and null while open.
class AttendanceRecord {
  final int id;
  final int? inspectorId;
  final String inspectorName;
  final String inspectorEmail;
  final String type;
  final DateTime? date;

  // Check-in.
  final DateTime? checkIn;
  final double? latitude;
  final double? longitude;
  final String? locationLabel;

  // Check-out (all null while the day is still open).
  final DateTime? checkOut;
  final double? checkoutLatitude;
  final double? checkoutLongitude;
  final String? checkoutLocationLabel;

  /// Server-computed worked minutes; null until the day is checked out.
  final int? workedMinutes;

  const AttendanceRecord({
    required this.id,
    required this.inspectorId,
    required this.inspectorName,
    required this.inspectorEmail,
    required this.type,
    required this.date,
    required this.checkIn,
    required this.latitude,
    required this.longitude,
    required this.locationLabel,
    required this.checkOut,
    required this.checkoutLatitude,
    required this.checkoutLongitude,
    required this.checkoutLocationLabel,
    required this.workedMinutes,
  });

  bool get isWorking => type.toLowerCase() == 'working';
  bool get isAvailable => type.toLowerCase() == 'available';
  bool get hasLocation => latitude != null && longitude != null;
  bool get hasCheckoutLocation =>
      checkoutLatitude != null && checkoutLongitude != null;

  /// True once checked in but not yet checked out.
  bool get isOpen => checkIn != null && checkOut == null;
  bool get isCheckedOut => checkOut != null;

  /// Worked duration. Prefers the server's [workedMinutes]; falls back to the
  /// check-in→check-out delta when only timestamps are present.
  Duration? get duration {
    if (workedMinutes != null) return Duration(minutes: workedMinutes!);
    if (checkIn == null || checkOut == null) return null;
    final d = checkOut!.difference(checkIn!);
    return d.isNegative ? null : d;
  }

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    final inspector = json['inspector'];
    final inspectorMap =
        inspector is Map ? inspector.cast<String, dynamic>() : const {};

    return AttendanceRecord(
      id: AttendanceParse.toInt(json['id']) ?? 0,
      inspectorId:
          AttendanceParse.toInt(json['inspector_id'] ?? inspectorMap['id']),
      inspectorName: (inspectorMap['name'] ??
              json['inspector_name'] ??
              json['name'] ??
              'Inspector')
          .toString(),
      inspectorEmail: (inspectorMap['email'] ??
              json['inspector_email'] ??
              json['email'] ??
              '')
          .toString(),
      type: (json['type'] ?? 'available').toString(),
      date: AttendanceParse.toDate(
          json['attendance_date'] ?? json['date'] ?? json['created_at']),
      checkIn: AttendanceParse.toDate(
          json['checked_in_at'] ?? json['check_in']),
      latitude: AttendanceParse.toDouble(json['latitude'] ?? json['lat']),
      longitude: AttendanceParse.toDouble(json['longitude'] ?? json['lng']),
      locationLabel:
          AttendanceParse.toNullableString(json['location_label']),
      checkOut: AttendanceParse.toDate(
          json['checked_out_at'] ?? json['check_out']),
      checkoutLatitude:
          AttendanceParse.toDouble(json['checkout_latitude']),
      checkoutLongitude:
          AttendanceParse.toDouble(json['checkout_longitude']),
      checkoutLocationLabel:
          AttendanceParse.toNullableString(json['checkout_location_label']),
      workedMinutes: AttendanceParse.toInt(json['worked_minutes']),
    );
  }
}

/// Shared, null-tolerant parsing helpers for the attendance/leave models.
extension AttendanceParse on Never {
  static int? toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static double? toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static DateTime? toDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString())?.toLocal();
  }

  static List<String> toStringList(dynamic v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }

  /// Returns a trimmed string, or null when the value is absent, blank, or a
  /// stringified null (`"null"`/`"none"`) — so optional text fields don't
  /// render placeholder noise.
  static String? toNullableString(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s.toLowerCase() == 'null' || s.toLowerCase() == 'none') {
      return null;
    }
    return s;
  }
}
