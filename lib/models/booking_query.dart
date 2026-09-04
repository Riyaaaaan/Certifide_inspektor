import 'attendance_record.dart' show AttendanceParse;

/// A single inspector ⇄ admin query raised against a booking.
///
/// Maps `GET/POST /api/inspector/bookings/{id}/queries`. `adminReply` is null
/// until an admin responds; [isAnswered] flips once [repliedAt] is set.
class BookingQuery {
  final int id;
  final String message;
  final String? adminReply;
  final DateTime? repliedAt;
  final String? repliedByName;
  final String? inspectorName;
  final DateTime? createdAt;

  const BookingQuery({
    required this.id,
    required this.message,
    required this.adminReply,
    required this.repliedAt,
    required this.repliedByName,
    required this.inspectorName,
    required this.createdAt,
  });

  bool get isAnswered =>
      repliedAt != null ||
      (adminReply != null && adminReply!.trim().isNotEmpty);

  factory BookingQuery.fromJson(Map<String, dynamic> json) {
    String? nameOf(dynamic v) {
      if (v is Map) return AttendanceParse.toNullableString(v['name']);
      return AttendanceParse.toNullableString(v);
    }

    return BookingQuery(
      id: AttendanceParse.toInt(json['id']) ?? 0,
      message: (json['message'] ?? '').toString(),
      adminReply: AttendanceParse.toNullableString(json['admin_reply']),
      repliedAt: AttendanceParse.toDate(json['replied_at']),
      repliedByName: nameOf(json['replied_by']),
      inspectorName: nameOf(json['inspector']),
      createdAt: AttendanceParse.toDate(json['created_at']),
    );
  }
}
