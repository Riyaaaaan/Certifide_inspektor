# Inspector Workflow — Attendance, Work Assigned & Notifications

Implements the inspector-facing parts of the **Inspector Workflow API** spec:
the daily attendance check-in/check-out, the assigned-jobs ("Work Assigned")
workflow, and FCM push notifications displayed via `awesome_notifications`.

> Reference spec: `inspector-workflow-api (1).md`.
> Base URL is `https://api.certifide.in/api` (already set in `ApiService`).

---

## 1. Dependencies

`pubspec.yaml`:

| Package | Version | Purpose |
|---|---|---|
| `firebase_messaging` | `^15.1.3` | Receive FCM push + device token |
| `awesome_notifications` | `^0.10.0` | Display notifications (foreground/background) + tap actions |

`firebase_core` (`^3.6.0`) and `geolocator` (`^14.0.2`) were already present.
Firebase was already configured in the project: `google-services.json`,
`ios/Runner/GoogleService-Info.plist`, `lib/firebase_options.dart`, the
`com.google.gms.google-services` Gradle plugin, and `Firebase.initializeApp` in
`main()`.

Run after pulling:

```bash
flutter pub get
cd ios && pod install --clean-install && cd ..   # iOS only
```

---

## 2. Models

### `lib/models/booking.dart` (new)
`Booking` + nested `BookingContact` (customer) and `NamedRef` (office/vehicle).
Carries the full inspector workflow state (`whatsappIntimated`,
`whatsappScreenshotUrl`, `arrivedAt`, `inspectionStartedAt`,
`inspectionCompletedAt`, `inspectionDurationMinutes`, `reportScreenshotUrl`) and
convenience getters: `hasArrived`, `inspectionStarted`, `inspectionCompleted`,
`reportUploaded`, `isFullyDone`, `nextStep` (a `BookingStep` enum driving the UI),
`shortAddress`, `fullAddress`, `vehicleTitle`.

### `lib/models/booking_query.dart` (new)
`BookingQuery` — id, message, adminReply, repliedAt, repliedByName,
inspectorName, createdAt, `isAnswered`.

### `lib/models/attendance_record.dart` (updated)
Extended to match the one-row-per-day model **with check-out**:
- Added `locationLabel`, `checkOut` (from `checked_out_at`),
  `checkoutLatitude`, `checkoutLongitude`, `checkoutLocationLabel`,
  `workedMinutes`.
- Added `isOpen`, `isCheckedOut`, `hasCheckoutLocation`; `duration` now prefers
  the server's `workedMinutes`.
- Parsing aligned to spec keys (`attendance_date`, `checked_in_at`,
  `checked_out_at`); dropped the never-sent `start_time`/`end_time` fallbacks.
- **Backwards compatible**: `AdminAttendanceScreen` still reads `checkIn`,
  `checkOut`, `duration` unchanged.

---

## 3. API layer — `lib/services/api_services.dart`

New endpoint constants: `inspectorBookingsEndPoint = '/inspector/bookings'`,
`inspectorAttendanceEndPoint = '/inspector/attendance'`,
`deviceTokenEndPoint = '/inspector/device-tokens'` (**assumed — see §7**).

### Inspector bookings (spec §1–9)
| Method | Endpoint |
|---|---|
| `getInspectorBookings({filter, page, perPage})` | `GET /inspector/bookings` |
| `getInspectorBookingDetail(id)` | `GET /inspector/bookings/{id}` |
| `uploadWhatsappIntimation(id, path)` | `POST .../whatsapp-intimation` (multipart, field `screenshot`) |
| `markArrived(id, {lat, lng, label})` | `POST .../mark-arrived` |
| `markInspectionStarted(id)` | `POST .../mark-inspection-started` |
| `markInspectionCompleted(id)` | `POST .../mark-inspection-completed` |
| `uploadReportScreenshot(id, path)` | `POST .../report-screenshot` (multipart) |
| `getBookingQueries(id)` | `GET .../queries` |
| `submitBookingQuery(id, message)` | `POST .../queries` |

Multipart uploads share a private `_uploadBookingScreenshot` helper (401 refresh +
retry once), mirroring the existing `uploadImage` pattern.

### Inspector attendance (spec §13–15)
| Method | Endpoint |
|---|---|
| `checkInAttendance({lat, lng, label})` | `POST /inspector/attendance/check-in` |
| `checkOutAttendance({lat, lng, label})` | `POST /inspector/attendance/check-out` |
| `getInspectorAttendance({month, page, perPage})` | `GET /inspector/attendance` |

Both punch calls return `{success, record, alreadyCheckedIn, message}`; a `422`
(already checked in/out, or no check-in yet) sets `alreadyCheckedIn: true` so the
UI can reload and show the true state.

### Device token (confirmed with backend)
- `registerDeviceToken(token, {platform, deviceId})` →
  `POST /notifications/register-token` with
  `{device_token, platform, device_id?}`. Upsert keyed on `device_token`
  (backend `updateOrCreate`), so re-registering reassigns the token to the
  current user and reactivates it.
- `unregisterDeviceToken(token)` → `DELETE /notifications/unregister-token`
  with `{device_token}`. Called on logout **before** the JWT is cleared.
Both best-effort, never throw. Available to any authenticated user (no role
restriction) — they sit in the `jwt.auth` + `check.status` group.

---

## 4. Notifications — `lib/services/notification_service.dart` (new)

Single entry point combining FCM (receipt + token) and `awesome_notifications`
(display + taps).

- `init()` — called from `main()` after `Firebase.initializeApp()`. Creates the
  notification channel/group, requests OS permission (both awesome + FCM),
  registers the FCM background handler, and wires foreground / opened-app /
  cold-start message handlers.
- `syncToken()` — fetches the FCM token, registers it with the backend, and
  keeps it fresh via `onTokenRefresh`. Called from `CarSpyHome.initState`
  (i.e. once the inspector is authenticated).
- `showFromRemoteMessage()` — renders any `RemoteMessage` through
  `awesome_notifications` (so foreground pushes are shown too). Runs in the
  background isolate as well; it deliberately does **not** call
  `Firebase.initializeApp` (only local display), avoiding the common background
  crash.
- **Tap routing** — the payload `type` maps to an in-app tab:
  - `inspection_assigned`, `inspections_today` → **Work Assigned** tab (index 3)
  - `attendance_check_in_reminder`, `attendance_check_out_reminder` →
    **Attendance** tab (index 2)

  Implemented with a `ValueNotifier<int?> requestedTab`; `CarSpyHome` listens and
  switches `_selectedIndex`. A `navigatorKey` is attached to `MaterialApp` for
  future deep-navigation needs.
- `showLocal(...)` — test helper to fire a local notification without the server.

`firebaseMessagingBackgroundHandler` is the required top-level
`@pragma('vm:entry-point')` background handler.

---

## 5. Screens

### Work Assigned — `lib/screens/work_assigned/work_assigned_screen.dart` (rewritten)
Was 100% mock data with Accept/Reject buttons that don't exist in the API. Now:
- Three filter tabs — **Today / Upcoming / Past** — each driving the `filter`
  query param, with pull-to-refresh and infinite-scroll pagination.
- Booking cards show vehicle, order id, address, date/time, a status badge, and a
  workflow progress bar (n/5 steps done).
- Tapping a card opens the detail workflow.

### Booking detail — `lib/screens/work_assigned/booking_detail_screen.dart` (new)
Drives the workflow **state machine** from the spec:
1. **WhatsApp intimation** — pick a screenshot (`image_picker`) → upload.
2. **Mark arrived** — captures GPS (`geolocator`) → `mark-arrived`.
3. **Start inspection** → `mark-inspection-started`.
4. **Complete inspection** → `mark-inspection-completed` (shows duration).
5. **Upload report screenshot** → `report-screenshot`.

Each step shows a timeline dot; only the *next* actionable step shows its button.
Also: open in Google Maps, call the customer, and a **Queries** section (thread +
a bottom sheet to submit a new query). Returns `true` on pop when anything
changed so the list refreshes.

### Inspector Attendance — `lib/screens/attendance/inspector_attendance_screen.dart` (rewritten)
Replaced the local, in-memory, multi-session + manual-add + live-timer model
(which didn't match the API) with the real single-daily-row model:
- Hero card reflects today's state: **Not checked in** → *Check In*;
  **open** → live elapsed timer + *Check Out*; **checked out** → worked total +
  "Day complete".
- Check-in/out capture GPS and call the API; `422` (already done) reloads state.
- Below: this month's history from `GET /inspector/attendance`, each row showing
  type (available/working), check-in/out times, worked duration, and location.
- Leaves remain reachable via the app-bar button (unchanged).

The `kInspectorAttendanceEnabled` flag in `attendance_screen.dart` is now `true`,
so inspectors see this screen (previously a "coming soon" placeholder).

---

## 6. Wiring & platform config

- `lib/main.dart` — `await NotificationService.init()` after Firebase init;
  `navigatorKey: NotificationService.navigatorKey` on `MaterialApp`.
- `lib/screens/home/car_spy/car_spy_home.dart` — `NotificationService.syncToken()`
  in `initState`, plus a `requestedTab` listener to honour notification taps;
  listener removed in a new `dispose()`.
- `android/app/src/main/AndroidManifest.xml` — added `POST_NOTIFICATIONS`,
  `WAKE_LOCK`, `VIBRATE` permissions.

---

## 7. Assumptions & manual steps

**Device-token endpoints (confirmed with backend).**

```
POST   /api/notifications/register-token
       { "device_token": "<fcm-token>", "platform": "android"|"ios", "device_id"?: "<id>" }
DELETE /api/notifications/unregister-token
       { "device_token": "<fcm-token>" }
```

Both are authenticated (`jwt.auth` + `check.status`, no role restriction).
Register uses `updateOrCreate` keyed on `device_token`. Wired in
`api_services.dart` (`registerDeviceToken` / `unregisterDeviceToken`);
unregister runs from `UserNotifier.clearUserData()` on logout.

**iOS push setup (Xcode / Firebase console):**
1. In Xcode, enable **Push Notifications** and **Background Modes → Remote
   notifications** capabilities on the Runner target.
2. Upload an **APNs auth key** to the Firebase project (Cloud Messaging settings).
3. `cd ios && pod install` after `flutter pub get`.

**Android:** `google-services.json` and the Gradle plugin are already in place;
no extra steps. `POST_NOTIFICATIONS` runtime permission is requested at launch.

**Not included (intentionally out of scope for this pass):**
- Leave requests still use the single-day `leave_date` form. The spec's newer
  date-range form (`from_date`/`to_date`, array response, `skipped`) was left as a
  follow-up to avoid changing the already-working leave screen.
- Admin `daily-summary` endpoint and admin attendance check-out columns in the
  admin screen (admin list still works; it reads the extended fields via the
  shared model).

---

## 8. Verification

- `flutter pub get` — resolved (5 dependencies changed).
- `flutter analyze lib/` — no new issues introduced; all reported items are
  pre-existing in untouched files (naming-convention infos, etc.).

Runtime testing (device/emulator) still recommended for: the FCM token round-trip
to the backend, foreground vs background notification display, tap routing, and
the full booking workflow against the live API.
