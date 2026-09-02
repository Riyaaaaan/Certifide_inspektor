import 'dart:io' show InternetAddress, SocketException;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:http/http.dart' as http;

class ConnectivityChecker {
  /// Test-only override for [canReachServer]. When set, the DNS lookup is
  /// skipped and this value is returned.
  ///
  /// Every offline/online branch in the sync and submit paths funnels through
  /// [canReachServer]; without a seam a test either performs a real DNS lookup
  /// or cannot reach those branches at all. Mirrors
  /// `LocalStorageService.debugDocsDirPath`. Always null in production.
  static bool? debugReachableOverride;

  /// Fast reachability probe for our own backend.
  ///
  /// A single DNS lookup of the API host fails in milliseconds when the device
  /// is offline (instead of waiting out the request timeout) and — unlike a
  /// Google ping — actually confirms our server's host can be resolved.
  static Future<bool> canReachServer({
    String host = 'api.certifide.in',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final override = debugReachableOverride;
    if (override != null) return override;
    try {
      final result =
          await InternetAddress.lookup(host).timeout(timeout);
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> hasInternetConnection() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      return false;
    }
    final internetChecker = InternetConnectionChecker.createInstance();
    final hasBasicConnection = await internetChecker.hasConnection;

    if (hasBasicConnection) {
      return true;
    }
    try {
      final response = await http
          .get(Uri.parse('https://www.google.com'))
          .timeout(const Duration(seconds: 3));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
