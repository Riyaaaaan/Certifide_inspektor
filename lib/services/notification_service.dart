import 'dart:developer';
import 'dart:io';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'api_services.dart';

/// FCM background isolate handler. Must be a top-level / static function
/// annotated with `@pragma('vm:entry-point')`. For data-only messages we render
/// the notification ourselves via awesome_notifications; "notification" messages
/// are drawn by the OS automatically.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // A full Firebase.initializeApp() isn't required just to display a local
  // notification, and awesome_notifications runs fine in the background isolate.
  await NotificationService.showFromRemoteMessage(message);
}

/// Centralises push (FCM) + local display (awesome_notifications).
///
/// Responsibilities:
/// - create the notification channel and request OS permission,
/// - fetch/refresh the FCM token and register it with the backend,
/// - display foreground + background messages through awesome_notifications,
/// - route notification taps to the right in-app tab via [requestedTab].
class NotificationService {
  NotificationService._();

  static const String _channelKey = 'certifide_inspektor_channel';
  static const String _channelGroupKey = 'certifide_inspektor_group';

  /// Status-bar icon: a white-on-transparent silhouette of the Certifide
  /// magnifier mark (res/drawable-*/res_notification.png, 24dp at every
  /// density). Android masks this by alpha and tints it with the channel
  /// colour, so it must stay monochrome — a full-colour bitmap here renders
  /// as a solid white blob. Kept in sync with the
  /// `default_notification_icon` manifest meta-data, which covers the
  /// OS-drawn tray path.
  static const String _smallIcon = 'resource://drawable/res_notification';

  /// The full-colour logo mark shown as the notification's large icon
  /// (res/drawable-nodpi/res_certifide_logo.png).
  static const String _largeIcon = 'resource://drawable/res_certifide_logo';

  /// Certifide brand teal, matching `@color/notification_accent`. Tints the
  /// small icon and the notification header.
  static const Color _brandColor = Color(0xFF3DA0AE);

  /// Attach to [MaterialApp.navigatorKey] so taps can navigate.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// A tab index the home should switch to (set on notification tap). The
  /// CarSpy home screen listens to this. Bottom-nav order:
  /// 0 HOME · 1 REPORTS · 2 ATTENDANCE · 3 WORK ASSIGNED.
  static final ValueNotifier<int?> requestedTab = ValueNotifier<int?>(null);

  /// Bumped whenever a push arrives that changes the inspector's assigned work.
  /// The Work Assigned screen watches this and refetches, so a newly assigned
  /// job appears without waiting for a pull-to-refresh.
  ///
  /// Only bumped on the UI isolate. A push handled while the app is
  /// backgrounded runs in [firebaseMessagingBackgroundHandler]'s own isolate,
  /// where this object is a different instance that nothing is listening to —
  /// that case is covered by the tap path below and by the screen's
  /// refresh-on-resume.
  static final ValueNotifier<int> assignmentsRevision = ValueNotifier<int>(0);

  /// Payload `type`s that mean the assigned-work list may have changed.
  static const Set<String> _assignmentTypes = {
    'inspection_assigned',
    'inspections_today',
  };

  static const int _tabAttendance = 2;
  static const int _tabWorkAssigned = 3;

  static bool _initialized = false;

  // ─────────────────────────────── Setup ────────────────────────────────

  /// One-time init. Call after `Firebase.initializeApp()` in `main()`.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await AwesomeNotifications().initialize(
      _smallIcon,
      [
        NotificationChannel(
          channelGroupKey: _channelGroupKey,
          channelKey: _channelKey,
          channelName: 'Certifide Inspektor',
          channelDescription:
              'Inspection assignments, daily jobs and attendance reminders',
          // Per-channel default, used for any notification on this channel
          // that doesn't name an icon of its own.
          icon: _smallIcon,
          defaultColor: _brandColor,
          ledColor: _brandColor,
          importance: NotificationImportance.High,
          channelShowBadge: true,
          playSound: true,
          enableVibration: true,
        ),
      ],
      channelGroups: [
        NotificationChannelGroup(
          channelGroupKey: _channelGroupKey,
          channelGroupName: 'Certifide Inspektor',
        ),
      ],
      debug: false,
    );

    // awesome_notifications tap/action listeners.
    await AwesomeNotifications().setListeners(
      onActionReceivedMethod: _onActionReceived,
    );

    // Register the FCM background handler before any async gaps.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _requestPermissions();
    _wireForegroundHandlers();
  }

  /// Whether the OS currently allows this app to post notifications. When this
  /// is false every FCM tray message and every local notification is dropped
  /// silently by the OS (Android reports the channel importance as NONE), so
  /// nothing the app does downstream matters until it flips to true.
  static Future<bool> isAllowed() =>
      AwesomeNotifications().isNotificationAllowed();

  /// Ask for notification permission if it isn't already granted, and return the
  /// resulting allowed state. Safe to call repeatedly — a no-op once granted.
  /// Called both at startup and again once the inspector reaches the home shell
  /// (where a resumed Activity is guaranteed), so a prompt dismissed during the
  /// cold-launch transition still gets a second, reliable chance.
  static Future<bool> ensurePermission() async {
    try {
      var allowed = await AwesomeNotifications().isNotificationAllowed();
      if (!allowed) {
        allowed =
            await AwesomeNotifications().requestPermissionToSendNotifications();
      }
      log('notifications allowed: $allowed', name: 'notifications');
      return allowed;
    } catch (e) {
      log('awesome permission error: $e', name: 'notifications');
      return false;
    }
  }

  static Future<void> _requestPermissions() async {
    await ensurePermission();
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      // iOS: show notifications while the app is foregrounded too.
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e) {
      log('fcm permission error: $e', name: 'notifications');
    }
  }

  static void _wireForegroundHandlers() {
    // App in foreground → render via awesome_notifications so it looks the same
    // as a background push (FCM otherwise stays silent in the foreground).
    FirebaseMessaging.onMessage.listen(showFromRemoteMessage);

    // App opened from a background (tray) tap on an FCM "notification" message.
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      _routeByType(m.data['type']?.toString());
    });

    // App launched cold from a notification tap.
    FirebaseMessaging.instance.getInitialMessage().then((m) {
      if (m != null) _routeByType(m.data['type']?.toString());
    });
  }

  // ──────────────────────────── Token handling ──────────────────────────

  /// Fetch the current FCM token and register it with the backend. Call once
  /// the user is authenticated. Also keeps registration fresh on token refresh.
  static Future<void> syncToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      log('FCM token: $token', name: 'notifications');
      if (token != null) await _register(token);
    } catch (e) {
      log('getToken error: $e', name: 'notifications');
    }
    FirebaseMessaging.instance.onTokenRefresh.listen(_register);
  }

  static Future<void> _register(String token) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    final ok = await ApiService.registerDeviceToken(token, platform: platform);
    log('device token registered: $ok', name: 'notifications');
  }

  /// Unregister this device's token from the backend. Call on logout — **before**
  /// the JWT is cleared, since the DELETE is authenticated. Best-effort.
  static Future<void> unregisterToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await ApiService.unregisterDeviceToken(token);
    } catch (e) {
      log('unregisterToken error: $e', name: 'notifications');
    }
  }

  // ─────────────────────────────── Display ──────────────────────────────

  /// Renders an [RemoteMessage] as a local notification. Safe to call from the
  /// background isolate. Carries the payload's `type` through so a later tap can
  /// route correctly.
  static Future<void> showFromRemoteMessage(RemoteMessage message) async {
    final notif = message.notification;
    final data = message.data;

    final title = notif?.title ?? data['title']?.toString() ?? 'Certifide';
    final body = notif?.body ?? data['body']?.toString() ?? '';

    // Stable-ish id from the message id; falls back to a bounded hash.
    final id = (message.messageId?.hashCode ?? body.hashCode) & 0x7fffffff;

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: id,
          channelKey: _channelKey,
          title: title,
          body: body,
          notificationLayout: NotificationLayout.Default,
          // Brand the notification itself: monochrome mark in the status bar
          // and header, full-colour mark as the large icon on the right.
          icon: _smallIcon,
          largeIcon: _largeIcon,
          color: _brandColor,
          payload: data.map((k, v) => MapEntry(k, v.toString())),
        ),
      );
    } catch (e) {
      log('createNotification error: $e', name: 'notifications');
    }

    _signalAssignmentChange(data['type']?.toString());
  }

  /// Tell listeners the assigned-work list is stale. Cheap and idempotent —
  /// firing twice for one push (arrival then tap) just costs one extra fetch.
  static void _signalAssignmentChange(String? type) {
    if (type == null || !_assignmentTypes.contains(type)) return;
    assignmentsRevision.value++;
  }

  // ──────────────────────────────── Taps ────────────────────────────────

  @pragma('vm:entry-point')
  static Future<void> _onActionReceived(ReceivedAction action) async {
    _routeByType(action.payload?['type']);
  }

  /// Maps an FCM payload `type` to the tab the user should land on.
  ///
  /// Called from every tap path — foreground action, background-tray tap
  /// ([FirebaseMessaging.onMessageOpenedApp]) and cold start
  /// ([FirebaseMessaging.getInitialMessage]) — so routing must work regardless
  /// of the current screen or app state.
  static void _routeByType(String? type) {
    _signalAssignmentChange(type);

    final int? tab;
    switch (type) {
      case 'inspection_assigned':
      case 'inspections_today':
        tab = _tabWorkAssigned;
        break;
      case 'attendance_check_in_reminder':
      case 'attendance_check_out_reminder':
        tab = _tabAttendance;
        break;
      default:
        tab = null;
    }
    if (tab == null) return;

    // Source of truth: the home shell reads this on init (cold start) and via a
    // listener while it is alive.
    requestedTab.value = tab;

    // If the app is already running and the user is somewhere deeper in the
    // stack (an inspection, profile, etc.), pop back to the home shell so the
    // tab switch is actually visible. No-op at cold start, when the navigator
    // isn't mounted yet — the home shell will consume [requestedTab] on init.
    final nav = navigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.popUntil((route) => route.isFirst);
    }
  }

  /// Consume a pending tab request (returns and clears it).
  static int? takePendingTab() {
    final v = requestedTab.value;
    requestedTab.value = null;
    return v;
  }
}
