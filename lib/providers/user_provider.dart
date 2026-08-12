import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../constants/hive_constants.dart';
import '../data/inspection_storage_model.dart';
import '../models/user_state.dart';
import '../services/api_services.dart';
import '../services/local_cache_service.dart';
import '../services/notification_service.dart';

part 'user_provider.g.dart';

@Riverpod(keepAlive: true)
class UserNotifier extends _$UserNotifier {
  static const String _userDataKey = 'user_data';
  static const String _tokenKey = 'jwt_token';

  final _storage = const FlutterSecureStorage();

  @override
  UserState build() => const UserState(isLoading: true);

  Future<void> initializeAuth(BuildContext context) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final token = await _storage.read(key: _tokenKey);

      if (token != null) {
        state = state.copyWith(token: token);

        // Restore the cached profile up-front so a valid session survives even
        // when the device is offline and the network calls below fail. Without
        // this, an offline launch leaves userData null and the AuthWrapper
        // kicks the user back to the login page.
        final cachedData = await _storage.read(key: _userDataKey);
        if (cachedData != null) {
          state = state.copyWith(
            userData: json.decode(cachedData) as Map<String, dynamic>,
          );
        }

        if (await _isTokenExpired(token)) {
          final refreshResult = await ApiService.refreshToken();
          if (!refreshResult['success']) {
            // Only force a logout when the server actually rejected us. If the
            // refresh failed because we're offline, keep the cached session so
            // the user stays on their page instead of being sent to login.
            if (_isNetworkFailure(refreshResult['message']) &&
                cachedData != null) {
              return;
            }
            await clearUserData();
            state = state.copyWith(
              isLoading: false,
              error: 'Session expired',
            );
            return;
          }
        }

        if (!context.mounted) return;
        final result = await ApiService.getProfile(
          context,
          onStateReset: clearUserData,
        );
        if (result['success']) {
          final userData = result['data']['user'] as Map<String, dynamic>;
          await _storage.write(
            key: _userDataKey,
            value: json.encode(userData),
          );
          state = state.copyWith(userData: userData);
        } else if (cachedData == null) {
          // Keep the cached profile we restored above when the refresh fails
          // (e.g. offline); only surface an error if we had nothing cached.
          state = state.copyWith(error: result['message'] as String?);
        }
      }
    } catch (e) {
      state = state.copyWith(error: 'Failed to initialize: ${e.toString()}');
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> loadUserData() async {
    try {
      final storedData = await _storage.read(key: _userDataKey);
      if (storedData != null) {
        state = state.copyWith(
          userData: json.decode(storedData) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      // Silent failure — user data simply stays null
    }
  }

  Future<void> clearUserData() async {
    // Unregister the FCM token first — the DELETE is authenticated, so it must
    // run before the JWT is wiped below. Best-effort; never blocks logout.
    await NotificationService.unregisterToken();
    try {
      await _storage.deleteAll();

      final inspectionBox = Hive.isBoxOpen(HiveConstants.INSPECTION_BOX)
          ? Hive.box<InspectionStorageModel>(HiveConstants.INSPECTION_BOX)
          : await Hive.openBox<InspectionStorageModel>(HiveConstants.INSPECTION_BOX);
      final historyBox = Hive.isBoxOpen(HiveConstants.INSPECTION_HISTORY_BOX)
          ? Hive.box<InspectionStorageModel>(HiveConstants.INSPECTION_HISTORY_BOX)
          : await Hive.openBox<InspectionStorageModel>(HiveConstants.INSPECTION_HISTORY_BOX);
      await inspectionBox.clear();
      await historyBox.clear();

      // Drop the offline read-cache (stats, report lists) so the next user
      // never sees the previous account's cached dashboard/reports.
      await LocalCacheService.clear();
    } catch (e) {
      log('logout: failed to clear Hive boxes — $e');
    }

    state = const UserState(isLoading: false);
  }

  Future<String?> getToken() async {
    if (state.token != null) return state.token;
    final token = await _storage.read(key: _tokenKey);
    if (token != null) state = state.copyWith(token: token);
    return token;
  }

  Future<void> setUserData(
    Map<String, dynamic> data,
    String token,
  ) async {
    await _storage.write(key: _userDataKey, value: json.encode(data));
    await _storage.write(key: _tokenKey, value: token);
    state = state.copyWith(userData: data, token: token, isLoading: false);
  }

  /// Whether an API result message describes a connectivity failure rather
  /// than a real auth rejection. The API service wraps offline/timeout errors
  /// as "Network error: ...".
  bool _isNetworkFailure(Object? message) {
    final text = message?.toString() ?? '';
    return text.startsWith('Network error:') ||
        text.contains('SocketException') ||
        text.contains('TimeoutException') ||
        text.contains('HandshakeException') ||
        text.contains('Failed host lookup');
  }

  Future<bool> _isTokenExpired(String token) async {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;

      final payload = json.decode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );

      final exp = payload['exp'] as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return exp < now;
    } catch (_) {
      return true;
    }
  }
}
