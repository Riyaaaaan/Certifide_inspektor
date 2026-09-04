// lib/services/api_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../models/inspection_history_model.dart';
import '../models/inspection_stats_model.dart';
import '../models/inspection_template_model.dart';
import '../models/inspector.dart';
import '../models/attendance_record.dart';
import '../models/inspector_leave.dart';
import '../models/leave_request.dart';
import '../models/pagination_data_model.dart';
import '../models/public_cars_models.dart';
import '../models/vehicle_model.dart';
import '../utils/exception_handler.dart';
import '../screens/auth/login_page.dart';
import 'local_storage_services.dart';
import 'reference_media_cache.dart';

/// Reports upload progress: bytes written so far and the total to write.
///
/// Fires once per streamed chunk, so callers that rebuild UI must throttle.
typedef UploadProgressCallback = void Function(int sent, int total);

/// A multipart request that reports bytes as they go out.
///
/// `http` has no progress hook, so the body stream returned by [finalize] is
/// passed through a counting transformer. Transforming rather than piping into
/// another request keeps the consumer in control of the pace: the file is read
/// only as fast as the socket drains it, which is what stops a 90 MB video
/// from being pulled into memory. Deferring to `super.finalize()` also keeps
/// the multipart content-type and its boundary, without which the server
/// cannot parse the body at all.
///
/// The count is bytes handed to the socket, not bytes acknowledged by the
/// server, so on a stalling link it can run ahead by roughly one send buffer.
/// That is a rounding error against a video, and it is the same figure any
/// progress-capable HTTP client reports.
@visibleForTesting
class ProgressMultipartRequest extends http.MultipartRequest {
  ProgressMultipartRequest(super.method, super.url, {this.onProgress});

  final UploadProgressCallback? onProgress;

  @override
  http.ByteStream finalize() {
    final body = super.finalize();
    final report = onProgress;
    if (report == null) return body;

    final total = contentLength;
    var sent = 0;
    return http.ByteStream(
      body.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            sink.add(chunk);
            sent += chunk.length;
            report(sent, total);
          },
        ),
      ),
    );
  }
}

/// Thrown inside [ApiService.uploadImage] when no auth token can be read while
/// (re)building a multipart upload request.
class _SessionExpired implements Exception {
  const _SessionExpired();
}

class ApiService {
  // static const String baseUrl = 'https://api.estelledarcy.com/api';
  static const String baseUrl = 'https://api.certifide.in/api';
  static const Duration _requestTimeout = Duration(seconds: 30);

  /// Media uploads get their own, far longer budget: an inspection video over
  /// mobile data legitimately runs for minutes, so [_requestTimeout] would
  /// abort healthy transfers. It still needs a ceiling — without one, a stalled
  /// socket leaves the submit spinner up forever with no way out.
  static const Duration _uploadTimeout = Duration(minutes: 10);

  /// Refuse anything above this locally rather than spending the whole upload
  /// to earn a rejection. Tracks the server's `max:1048576` rule (1 GB) on the
  /// upload endpoint, so the app never blocks a file the server would accept.
  ///
  /// This is the hard ceiling, not a target: see `maxRecordingDuration`, which
  /// keeps clips the app records itself far below it, because transfer
  /// reliability — not the server rule — is what actually fails first.
  static const int maxUploadBytes = 1048576 * 1024;

  static const _storage = FlutterSecureStorage();

  static const String loginEndpoint = '/auth/login';
  static const String registerEndpoint = '/auth/register';
  static const String refreshTokenEndpoint = '/auth/refresh';
  static const String profileEndPoint = '/auth/me';
  static const String getInspectorEndPoint = '/tokens/inspectors';
  static const String allocateTokensEndPoint = '/tokens/allocate';
  static const String sendDataEndPoint = '/inspections';
  static const String uploadImageEndPoint = '/inspection/upload-image';

  /// Dedicated video upload. Unlike [uploadImageEndPoint] this route sits
  /// inside the server's `jwt.auth` middleware group, so the bearer token is
  /// actually enforced. Takes the file under the field name `video` and
  /// answers with a `videoPath` key instead of `imagePath`.
  static const String uploadVideoEndPoint = '/dynamic-inspections/upload-video';

  /// Formats [uploadVideoEndPoint] accepts. Narrower than the legacy route's
  /// list (no 3gp), so anything outside it must keep using the old endpoint.
  static const Set<String> videoEndpointExtensions = {
    'mp4', 'avi', 'mov', 'wmv', 'flv', 'webm', 'mkv',
  };
  static const String getBalanceTokensEndPoint = '/tokens/balance';
  static const String getHistoryEndPoint = '/dynamic-inspections';
  static const String initialInspectionEndPoint = '/inspections/initial';
  static const String initializeInspectionEndPoint = '/inspections/initialize';
  static const String initializeDynamicInspectionEndPoint =
      '/dynamic-inspections/initialize';
  static const String getModelsEndpoint = '/admin/vehicles/models';
  static const String submitDynamicInspectionEndPoint = '/dynamic-inspections';
  static const String newCarsEndPoint = '/cars/new';
  static const String userCarsEndPoint = '/cars/old';
  static const String carFiltersEndpoint = '/cars/filters';
  static const String vehicleDetailsEndPoint = '/ulip/vehicle-details';
  static const String getDynamicMyHistoryEndPoint =
      '/dynamic-inspections/my-history';
  static const String inspectionStatsEndPoint = '/dynamic-inspections/stats';
  static const String adminLeavesEndPoint = '/admin/leaves';
  static const String adminAttendanceEndPoint = '/admin/attendance';
  static const String inspectorLeavesEndPoint = '/inspector/leaves';

  static Future<Map<String, dynamic>> createInitialInspection(
      Map<String, dynamic> vehicleData) async {
    try {
      if (kDebugMode) log('Creating initial inspection with data: $vehicleData');

      final response = await http.post(
        Uri.parse('$baseUrl$initialInspectionEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode(vehicleData),
      ).timeout(_requestTimeout);

      log('Initial inspection response status: ${response.statusCode}');
      if (kDebugMode) log('Initial inspection response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);

        if (responseData['status'] == 'success' &&
            responseData['data'] != null) {
          log('Initial inspection created successfully. ID: ${responseData['data']['inspection_id']}');

          return {
            'success': true,
            'data': responseData['data'],
            'message': responseData['message'] ??
                'Initial inspection created successfully',
          };
        } else {
          return {
            'success': false,
            'message': responseData['message'] ??
                'Failed to create initial inspection',
          };
        }
      } else {
        return {
          'success': false,
          'message': _handleError(response),
        };
      }
    } catch (e) {
      log('Error creating initial inspection: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static Future<Map<String, dynamic>> initializeInspection({
    required int vehicleBrandId,
    required int vehicleModelId,
    String? year,
    String? variant,
    String? colour,
    String? transmission,
    String? regNo,
  }) async {
    try {
      log('Initializing inspection for brand_id: $vehicleBrandId, model_id: $vehicleModelId');

      final body = <String, dynamic>{
        'vehicle_brand_id': vehicleBrandId,
        'vehicle_model_id': vehicleModelId,
        if (year != null && year.isNotEmpty) 'year': year,
        if (variant != null && variant.isNotEmpty) 'variant': variant,
        if (colour != null && colour.isNotEmpty) 'color': colour,
        if (transmission != null && transmission.isNotEmpty)
          'transmission': transmission,
        if (regNo != null && regNo.isNotEmpty) 'registration_number': regNo,
      };

      final response = await http.post(
        Uri.parse('$baseUrl$initializeDynamicInspectionEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode(body),
      ).timeout(_requestTimeout);

      log('Initialize inspection response status: ${response.statusCode}');
      if (kDebugMode) log('Initialize inspection response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);

        if (responseData['status'] == 'success' &&
            responseData['data'] != null) {
          final data = responseData['data'];

          // Parse the inspection template structure
          InspectionInitializationResponse? inspectionResponse;
          try {
            inspectionResponse =
                InspectionInitializationResponse.fromJson(data);
          } catch (e) {
            log('Error parsing inspection template: $e');
          }

          // Warm the offline cache for reference images now, while we are
          // definitely online, so guides stay visible if the inspector drops
          // offline mid-inspection. Fire-and-forget — never blocks the flow.
          if (inspectionResponse != null) {
            unawaited(ReferenceMediaCache.prefetch(
                inspectionResponse.referenceImageUrls));
          }

          log('Inspection initialized successfully');

          return {
            'success': true,
            'data': inspectionResponse ?? data,
            'inspection_id': data['inspection_id'] ?? data['inspectionId'] ?? data['id'],
            'message': responseData['message'] ??
                'Inspection initialized successfully',
          };
        } else {
          return {
            'success': false,
            'message':
                responseData['message'] ?? 'Failed to initialize inspection',
          };
        }
      } else {
        return {
          'success': false,
          'message': _handleError(response),
        };
      }
    } catch (e) {
      log('Error initializing inspection: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static String _handleError(http.Response response) {
    try {
      final errorData = json.decode(response.body);
      if (errorData['message'] != null) {
        return errorData['message'];
      } else if (errorData['error'] != null) {
        return errorData['error'];
      }
      return 'An error occurred (${response.statusCode})';
    } catch (e) {
      return 'An error occurred (${response.statusCode})';
    }
  }

  static Future<void> handleUnauthorizedResponse(
    BuildContext context, {
    VoidCallback? onStateReset,
  }) async {
    await _storage.deleteAll();
    onStateReset?.call();
    if (context.mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginPage()),
        (route) => false,
      );
    }
  }

  static Future<Map<String, String>> _getHeaders(
      {bool requiresAuth = true}) async {
    Map<String, String> headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (requiresAuth) {
      final token = await _storage.read(key: 'jwt_token');
      if (token != null) {
        // Check if token is expired
        if (await isTokenExpired(token)) {
          // Try to refresh token
          final refreshResult = await refreshToken();
          if (!refreshResult['success']) {
            // If refresh fails, clear storage and return to login
            await _storage.deleteAll();
            throw UnauthorizedException('Token expired');
          }
          // Get new token after refresh
          final newToken = await _storage.read(key: 'jwt_token');
          if (newToken == null) {
            await _storage.deleteAll();
            throw UnauthorizedException('Token missing after refresh');
          }
          headers['Authorization'] = 'Bearer $newToken';
        } else {
          headers['Authorization'] = 'Bearer $token';
        }
      }
    }

    return headers;
  }

  static Future<String?> getUserId() async {
    final userData = await _storage.read(key: 'user_data');
    if (userData != null) {
      try {
        final user = json.decode(userData);
        return user['id']?.toString();
      } catch (e) {
        log('getUserId: malformed user_data in storage — $e');
      }
    }
    return null;
  }

  static Future<Map<String, dynamic>> login(
      String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl$loginEndpoint'),
        headers: await _getHeaders(requiresAuth: false),
        body: json.encode({
          'email': email,
          'password': password,
        }),
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);

        if (responseData['status'] == 'success' &&
            responseData['data'] != null &&
            responseData['data']['access_token'] != null &&
            responseData['data']['user'] != null) {
          await _storage.write(
            key: 'jwt_token',
            value: responseData['data']['access_token'],
          );
          await _storage.write(
            key: 'user_data',
            value: json.encode(responseData['data']['user']),
          );

          // CRITICAL FIX: Convert "status":"success" to "success":true for login screen
          return {
            'success': true, // This is what login screen expects!
            'data': responseData['data'],
            'message': responseData['message'] ?? 'Login successful',
          };
        } else {
          return {
            'success': false,
            'message': 'Invalid response data structure',
          };
        }
      } else {
        return {
          'success': false,
          'message': _handleError(response),
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required String passwordConfirmation,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl$registerEndpoint'),
        headers: await _getHeaders(requiresAuth: false),
        body: json.encode({
          'name': name,
          'email': email,
          'password': password,
          'password_confirmation': passwordConfirmation,
        }),
      ).timeout(_requestTimeout);

      final responseData = json.decode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        // Remove token storage and user data storage
        return {
          'success': true,
          'data': responseData,
          'message': responseData['message'] ?? 'Registration successful',
        };
      } else {
        return {
          'success': false,
          'message': responseData['message'] ?? 'Registration failed',
          'errors': responseData['errors'],
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static Future<Map<String, dynamic>> refreshToken() async {
    try {
      // Get the current token
      final currentToken = await _storage.read(key: 'jwt_token');

      if (currentToken == null) {
        return {
          'success': false,
          'message': 'No token found',
        };
      }

      // Build headers manually — do NOT call _getHeaders(requiresAuth: true) here.
      // _getHeaders checks expiry and calls refreshToken() again, causing infinite recursion.
      // The refresh endpoint needs the current (possibly expired) token to identify the session.
      final headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $currentToken',
      };

      final response = await http.post(
        Uri.parse('$baseUrl$refreshTokenEndpoint'),
        headers: headers,
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);

        // Store the new access token
        if (responseData['data'] != null &&
            responseData['data']['access_token'] != null) {
          await _storage.write(
            key: 'jwt_token',
            value: responseData['data']['access_token'],
          );

          return {
            'success': true,
            'data': responseData,
            'message': 'Token refreshed successfully',
          };
        }
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static Future<bool> isTokenValid() async {
    try {
      final token = await _storage.read(key: 'jwt_token');
      if (token == null) return false;

      final response = await http.get(
        Uri.parse('$baseUrl$profileEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      return response.statusCode == 200;
    } catch (e) {
      log('Error checking token validity: $e');
      return false;
    }
  }

  static Future<bool> isTokenExpired(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return Future.value(true);

      final payload = json
          .decode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final exp = payload['exp'];
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      return Future.value(exp < now);
    } catch (e) {
      return Future.value(true);
    }
  }

  static Future<Map<String, dynamic>> getProfile(
    BuildContext context, {
    VoidCallback? onStateReset,
  }) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl$profileEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        if (responseData['data'] != null &&
            responseData['data']['user'] != null) {
          await _storage.write(
            key: 'user_data',
            value: json.encode(responseData['data']['user']),
          );
        }
        return {
          'success': true,
          'data': responseData['data'],
          'message': 'Profile retrieved successfully',
        };
      } else if (response.statusCode == 401) {
        await handleUnauthorizedResponse(context, onStateReset: onStateReset);
        return {
          'success': false,
          'message': 'Unauthorized access',
        };
      } else {
        return {
          'success': false,
          'message': _handleError(response),
        };
      }
    } on UnauthorizedException {
      await handleUnauthorizedResponse(context, onStateReset: onStateReset);
      return {
        'success': false,
        'message': 'Session expired',
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static Future<Map<String, dynamic>> getInspectors() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl$getInspectorEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);

        final rawData = responseData['data'];
        if (responseData['status'] == 'success' && rawData is List) {
          List<Inspector> inspectors = rawData
              .map((inspectorData) => Inspector.fromJson(inspectorData))
              .toList();

          return {
            'success': true,
            'data': inspectors,
            'message': 'Inspectors retrieved successfully',
          };
        }
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static Future<Map<String, dynamic>> allocateTokens({
    required String userId,
    required String tokens,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl$allocateTokensEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode({
          'user_id': userId,
          'tokens': tokens,
        }),
      ).timeout(_requestTimeout);

      final responseData = json.decode(response.body);

      if (response.statusCode == 200) {
        return {
          'success': true,
          'data': responseData['data'],
          'message': responseData['message'] ?? 'Tokens allocated successfully',
        };
      } else {
        return {
          'success': false,
          'message': responseData['message'] ?? 'Token allocation failed',
          'errors': responseData['errors'],
        };
      }
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  //submit inspection

  static Future<Map<String, dynamic>> sendInspectionData(
      Map<String, dynamic> inspectionData,
      {int? inspectionId}) async {
    try {
      final endpoint = inspectionId != null
          ? '$sendDataEndPoint/$inspectionId'
          : sendDataEndPoint;

      log('Sending inspection data to: $baseUrl$endpoint');
      if (kDebugMode) log('Inspection data: $inspectionData');

      final response = await http.put(
        Uri.parse('$baseUrl$endpoint'),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode(inspectionData),
      ).timeout(_requestTimeout);

      log('Inspection submission response status: ${response.statusCode}');
      if (kDebugMode) log('Inspection submission response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);
        log('Inspection submitted successfully');

        return {
          'success': true,
          'data': responseData['data'],
          'message':
              responseData['message'] ?? 'Inspection data sent successfully',
        };
      } else {
        if (kDebugMode) log('Error response: ${response.body}');
        return {
          'success': false,
          'message': _handleError(response),
        };
      }
    } catch (e) {
      log('Error sending inspection data: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Uploads a single media file (image / video / audio / file) to the shared
  /// upload endpoint and returns `{success, url, path, message}`.
  ///
  /// Works for every media type — the endpoint keys media by [section] +
  /// [itemId] (+ optional [inspectionId]). On a 401 it refreshes the token and
  /// retries the upload ONCE so a token expiry mid-sync doesn't silently drop a
  /// queued upload. [mediaType] is accepted for logging/diagnostics.
  static Future<Map<String, dynamic>> uploadImage(
    String imagePath, {
    int? inspectionId,
    required String section,
    required String itemId,
    String fieldName = 'image',
    String? mediaType,
    UploadProgressCallback? onProgress,
  }) async {
    try {
      log('Uploading media (${mediaType ?? fieldName})');
      log('Section: $section, ItemId: $itemId');

      // Re-base any stale absolute path (captured under a previous iOS sandbox
      // container) or relative path onto the current documents directory so
      // offline-queued media still uploads after an app relaunch.
      imagePath = LocalStorageService.resolveMediaPath(imagePath);

      final file = File(imagePath);
      if (!await file.exists()) {
        log('File does not exist: $imagePath');
        return {
          'success': false,
          'message': 'File not found',
        };
      }

      // Stat the file instead of reading it. A full-resolution inspection video
      // is hundreds of MB; buffering it here (readAsBytes) got the app
      // OOM-killed mid-upload and the media silently never arrived.
      final fileLength = await file.length();
      final fileName = imagePath.split('/').last;

      log('File name: $fileName, size: $fileLength bytes');

      if (fileLength > maxUploadBytes) {
        final mb = (fileLength / (1024 * 1024)).toStringAsFixed(1);
        log('File exceeds upload limit: $mb MB');
        return {
          'success': false,
          'message': 'File is too large to upload ($mb MB). '
              'Please recapture a shorter clip.',
        };
      }

      // Prefer the dedicated, authenticated video endpoint. The legacy
      // /inspection/upload-image route sits OUTSIDE the jwt.auth middleware
      // group, so the server never checks the token this app already sends.
      //
      // Only when the request actually satisfies that endpoint's stricter
      // contract, which the legacy one no longer enforces: it requires a
      // non-empty section and itemId, and accepts a narrower format list.
      // Falling back keeps an odd file uploading instead of hard-failing it.
      final useVideoEndpoint = usesVideoEndpoint(
        mediaType: mediaType,
        section: section,
        itemId: itemId,
        fileName: fileName,
      );

      final endpoint =
          useVideoEndpoint ? uploadVideoEndPoint : uploadImageEndPoint;
      final uploadField = useVideoEndpoint ? 'video' : fieldName;
      if (useVideoEndpoint) log('Routing video to $uploadVideoEndPoint');

      final token = await _storage.read(key: 'jwt_token');
      if (token == null) {
        return {
          'success': false,
          'message': 'Authentication required',
        };
      }

      if (await isTokenExpired(token)) {
        final refreshResult = await refreshToken();
        if (!refreshResult['success']) {
          await _storage.deleteAll();
          return {
            'success': false,
            'message': 'Session expired. Please login again.',
          };
        }
      }

      // Builds and sends a fresh multipart request with the current token.
      // Defined as a closure so we can re-issue it after a 401 refresh.
      Future<({int status, String body})> send() async {
        final authToken = await _storage.read(key: 'jwt_token');
        if (authToken == null) {
          throw const _SessionExpired();
        }
        final request = ProgressMultipartRequest(
          'POST',
          Uri.parse('$baseUrl$endpoint'),
          onProgress: onProgress,
        );
        request.headers['Authorization'] = 'Bearer $authToken';
        request.headers['Accept'] = 'application/json';
        // Streams from disk at constant memory. Built fresh on every attempt
        // because a stream, unlike a byte list, cannot be replayed on retry.
        request.files.add(
          await http.MultipartFile.fromPath(uploadField, imagePath,
              filename: fileName),
        );
        request.fields['section'] = section;
        request.fields['itemId'] = itemId;
        if (inspectionId != null) {
          request.fields['inspection_id'] = inspectionId.toString();
        }
        // Own the client so the connection is released on every exit path,
        // including a timeout mid-transfer. BaseRequest.send() closes its own
        // client only once the response body has been read, which never
        // happens when the send itself times out.
        final client = http.Client();
        try {
          final response = await client.send(request).timeout(_uploadTimeout);
          final body =
              await response.stream.bytesToString().timeout(_uploadTimeout);
          return (status: response.statusCode, body: body);
        } finally {
          client.close();
        }
      }

      log('Upload request fields: section=$section, itemId=$itemId, inspectionId=$inspectionId');

      ({int status, String body}) result;
      try {
        result = await send();
        // Refresh + retry ONCE on auth failure.
        if (result.status == 401) {
          final refreshResult = await refreshToken();
          if (!refreshResult['success']) {
            await _storage.deleteAll();
            return {
              'success': false,
              'message': 'Session expired. Please login again.',
            };
          }
          result = await send();
        }
      } on _SessionExpired {
        return {
          'success': false,
          'message': 'Session expired. Please login again.',
        };
      }

      log('Upload response status: ${result.status}');
      log('Upload response body: ${result.body}');

      if (result.status == 200 || result.status == 201) {
        final responseData = json.decode(result.body);

        // Server returns imagePath for all media types on this endpoint;
        // honour any media-path key the backend might use.
        final mediaPath = responseData['imagePath'] ??
            responseData['videoPath'] ??
            responseData['audioPath'] ??
            responseData['filePath'] ??
            responseData['url'] ??
            responseData['path'];

        // Treat as success when a media path is present, even if the backend
        // omits/renames the `status` flag.
        final bool ok = mediaPath != null &&
            (responseData['status'] == null ||
                responseData['status'] == 'success' ||
                responseData['success'] == true);

        if (ok) {
          // Prefer the `url` half of {url, path}. Fall back to `path` (or to a
          // bare string response) ONLY through absoluteMediaUrl: a relative
          // path stored here is dropped by the http-only filter when the
          // inspection is submitted, so the upload would succeed and the media
          // would then silently vanish from the report.
          final String? rawUrl = mediaPath is Map
              ? (mediaPath['url'] ?? mediaPath['path'])?.toString()
              : mediaPath.toString();
          final String? url = absoluteMediaUrl(rawUrl);
          final String? path =
              mediaPath is Map ? mediaPath['path']?.toString() : null;
          if (rawUrl != url) {
            log('Upload returned a relative media path; resolved to $url');
          }
          log('Upload successful. URL: $url');
          return {
            'success': true,
            'url': url,
            'path': path,
            'message': responseData['message'] ?? 'Uploaded successfully',
          };
        } else {
          return {
            'success': false,
            'message': responseData['message'] ?? 'Failed to upload',
          };
        }
      } else if (result.status == 401) {
        await _storage.deleteAll();
        return {
          'success': false,
          'message': 'Session expired. Please login again.',
        };
      } else {
        log('Error response: ${result.body}');
        return {
          'success': false,
          'message': _handleErrorFromString(result.body, result.status),
        };
      }
    } on TimeoutException {
      log('Media upload timed out after $_uploadTimeout');
      return {
        'success': false,
        'message': 'The upload timed out. Check your connection and try again.',
      };
    } catch (e) {
      log('Error uploading media: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static String _handleErrorFromString(String responseBody, int statusCode) {
    try {
      final errorData = json.decode(responseBody);
      // A 422 carries the useful detail in `errors`, keyed by field; `message`
      // is only ever the generic "Validation failed". Prefer the specifics.
      final errors = errorData['errors'];
      if (errors is Map && errors.isNotEmpty) {
        final detail = errors.values
            .expand((v) => v is List ? v : [v])
            .map((v) => v.toString())
            .where((v) => v.isNotEmpty)
            .join(' ');
        if (detail.isNotEmpty) return detail;
      }
      if (errorData['message'] != null) {
        return errorData['message'];
      } else if (errorData['error'] != null) {
        return errorData['error'];
      }
      return uploadStatusMessage(statusCode);
    } catch (e) {
      // A rejection from the web server rather than the app returns an HTML
      // error page, so there is no JSON message to surface. Translate the
      // status instead of showing a bare code the inspector can't act on.
      return uploadStatusMessage(statusCode);
    }
  }

  /// Whether this upload should go to the authenticated [uploadVideoEndPoint]
  /// rather than the unauthenticated legacy route.
  ///
  /// That endpoint enforces a stricter contract than the legacy one, which now
  /// accepts a null section/itemId: it requires BOTH to be non-empty and takes
  /// a narrower format list. Anything failing those conditions keeps using the
  /// legacy route, so a request that would 422 there uploads instead of being
  /// hard-rejected — availability first, since the legacy path still works.
  static bool usesVideoEndpoint({
    required String? mediaType,
    required String section,
    required String itemId,
    required String fileName,
  }) {
    if (mediaType != 'video') return false;
    if (section.trim().isEmpty || itemId.trim().isEmpty) return false;
    final extension =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    return videoEndpointExtensions.contains(extension);
  }

  /// Turns whatever the upload endpoint returned into an absolute URL.
  ///
  /// The server normally returns `{url, path}` and the `url` half is already
  /// absolute. But a bare `inspections/...` string — from the `path` half, an
  /// older build, or a plain-string response — is NOT usable downstream: the
  /// submission body is built with an http-only filter, so a relative value is
  /// stripped and the media disappears from the report even though the upload
  /// succeeded. Resolving it against the API origin keeps that from happening.
  ///
  /// Returns null for null/empty input so callers still treat it as a failure.
  static String? absoluteMediaUrl(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    // baseUrl carries the `/api` suffix; media is served from the host root.
    final origin = Uri.parse(baseUrl).origin;
    return '$origin/${value.replaceFirst(RegExp(r'^/+'), '')}';
  }

  /// Plain-language text for the upload failures that arrive without a usable
  /// JSON body.
  static String uploadStatusMessage(int statusCode) {
    switch (statusCode) {
      case 413:
        return 'File is too large for the server to accept. '
            'Please recapture a shorter clip.';
      case 408:
      case 504:
        return 'The upload timed out. Check your connection and try again.';
      case 502:
      case 503:
        return 'The server is temporarily unavailable. Please try again.';
      default:
        return 'An error occurred ($statusCode)';
    }
  }

  static Future<Map<String, dynamic>> getTokenBalance(String userId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl$getBalanceTokensEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);

        if (responseData['status'] == 'success' &&
            responseData['data'] != null) {
          return {
            'success': true,
            'data': {
              'available_tokens': responseData['data']['available_tokens'],
              'used_tokens': responseData['data']['used_tokens'],
            },
            'message': 'Token balance retrieved successfully',
          };
        }
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  // To be used in HistoryPage and ApprovalsPage
  static Future<Map<String, dynamic>> getInspectionHistory(BuildContext context,
      {int page = 1}) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl$getHistoryEndPoint?page=$page'),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);
      log('getInspectionHistory status: ${response.statusCode}');
      log('getInspectionHistory body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;

        if (responseData['status'] == 'success') {
          final data = (responseData['data'] as Map).cast<String, dynamic>();
          final rawList = data['inspections'] ?? data['data'] ?? [];
          if (rawList is! List) {
            return {'success': false, 'message': 'Unexpected response shape'};
          }
          final inspections = rawList
              .map((item) => InspectionHistory.fromJson(item))
              .toList();
          final pagination = _extractPagination(responseData, data);

          return {
            'success': true,
            'inspections': inspections,
            'pagination': pagination,
            'message': 'History retrieved successfully',
          };
        }
      } else if (response.statusCode == 401) {
        await handleUnauthorizedResponse(context);
        return {
          'success': false,
          'message': 'Unauthorized access',
        };
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } on UnauthorizedException {
      await handleUnauthorizedResponse(context);
      return {
        'success': false,
        'message': 'Session expired. Please login again.',
      };
    } catch (e) {
      log('getInspectionHistory error: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Extracts pagination metadata from a response that may nest it in several
  /// shapes: a `pagination`/`meta` object (under `data` or top-level), or
  /// Laravel-style sibling keys (`current_page`, `last_page`, ...).
  static PaginationData _extractPagination(
      Map<String, dynamic> responseData, Map<String, dynamic> data) {
    for (final candidate in [
      data['pagination'],
      data['meta'],
      responseData['pagination'],
      responseData['meta'],
    ]) {
      if (candidate is Map<String, dynamic> &&
          (candidate['last_page'] != null || candidate['current_page'] != null)) {
        return PaginationData.fromJson(candidate);
      }
    }
    // Fall back to flat sibling keys (raw paginator serialized under `data`).
    return PaginationData(
      currentPage: data['current_page'] ?? responseData['current_page'] ?? 1,
      lastPage: data['last_page'] ?? responseData['last_page'] ?? 1,
      perPage: data['per_page'] ?? responseData['per_page'] ?? 10,
      total: data['total'] ?? responseData['total'] ?? 0,
    );
  }

  static Future<Map<String, dynamic>> getDynamicInspectionMyHistory(
      BuildContext context,
      {int page = 1, String? status}) async {
    final params = <String, String>{'page': '$page', 'sort': 'latest'};
    if (status != null && status.isNotEmpty) params['status'] = status;
    final url = Uri.parse('$baseUrl$getDynamicMyHistoryEndPoint')
        .replace(queryParameters: params)
        .toString();
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: await _getHeaders(requiresAuth: true),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;

        if (responseData['status'] == 'success') {
          final data = (responseData['data'] as Map).cast<String, dynamic>();
          final rawList = data['inspections'] ?? data['data'] ?? [];
          if (rawList is! List) {
            return {'success': false, 'message': 'Unexpected response shape'};
          }
          final inspections = rawList
              .map((item) => InspectionHistory.fromJson(item))
              .toList();
          final pagination = _extractPagination(responseData, data);

          return {
            'success': true,
            'inspections': inspections,
            'pagination': pagination,
            'message': 'History retrieved successfully',
          };
        }
      } else if (response.statusCode == 401) {
        await handleUnauthorizedResponse(context);
        return {
          'success': false,
          'message': 'Unauthorized access',
        };
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } on UnauthorizedException {
      await handleUnauthorizedResponse(context);
      return {
        'success': false,
        'message': 'Session expired. Please login again.',
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

// In api_services.dart
  static Future<Map<String, dynamic>> approveInspection(
      String inspectionId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/inspections/$inspectionId/approve-api'),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        return responseData;
      } else {
        return {
          'status': 'error',
          'message':
              'Failed to approve inspection. Status: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {
        'status': 'error',
        'message': 'Failed to approve inspection: ${e.toString()}',
      };
    }
  }

  /// Normalises the various success/failure response shapes the submit + submit-
  /// by-id endpoints can return into `{success, data, message}`.
  static Map<String, dynamic> _parseSubmitResponse(http.Response response) {
    if (response.statusCode == 200 || response.statusCode == 201) {
      Map<String, dynamic> responseData;
      try {
        responseData = Map<String, dynamic>.from(
            json.decode(response.body) as Map<dynamic, dynamic>);
      } catch (parseError) {
        log('Error parsing submit response JSON: $parseError');
        return {
          'success': false,
          'message':
              'Invalid response from server (${response.statusCode}). Check logs.',
        };
      }

      // Accept multiple response shapes from backend
      Map<String, dynamic>? data =
          responseData['data'] as Map<String, dynamic>?;
      final bool hasWrappedData = (responseData['status'] == 'success' ||
              responseData['success'] == true) &&
          data != null;
      final bool hasRootData = data == null &&
          (responseData['inspection_id'] != null ||
              responseData['redirect_url'] != null);
      if (hasRootData) {
        data = {
          'inspection_id': responseData['inspection_id'],
          'redirect_url': responseData['redirect_url'] ?? '',
          'uuid': responseData['uuid'] ?? '',
        };
      }

      if (hasWrappedData || hasRootData) {
        return {
          'success': true,
          'data': data ?? responseData,
          'message':
              responseData['message'] ?? 'Inspection submitted successfully',
        };
      }

      return {
        'success': false,
        'message': responseData['message'] ?? 'Failed to submit inspection',
      };
    }
    return {
      'success': false,
      'message': _handleError(response),
    };
  }

  /// Legacy all-at-once create: POST /dynamic-inspections. Used only when there
  /// is no server inspection id yet (the draft was never initialized). When an
  /// id exists, prefer [submitInspectionById] so the existing draft is finalised
  /// instead of a duplicate inspection being created.
  static Future<Map<String, dynamic>> submitInspection(
      Map<String, dynamic> body) async {
    try {
      log('Submitting dynamic inspection to: $baseUrl$submitDynamicInspectionEndPoint');
      if (kDebugMode) log('Submission body: $body');

      final response = await http.post(
        Uri.parse('$baseUrl$submitDynamicInspectionEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode(body),
      ).timeout(_requestTimeout);

      log('Submit inspection response status: ${response.statusCode}');
      if (kDebugMode) log('Submit inspection response body: ${response.body}');

      return _parseSubmitResponse(response);
    } on UnauthorizedException {
      rethrow;
    } catch (e) {
      log('Error submitting inspection: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Finalises an existing draft: POST /dynamic-inspections/{id}/submit.
  /// Sets processing_status = "completed". The data may already be on the server
  /// (saved per-field via save-step); [body] is sent anyway so any field not yet
  /// save-stepped (e.g. edited offline) is persisted in the same call. Idempotent
  /// on an already-completed (un-approved) inspection.
  static Future<Map<String, dynamic>> submitInspectionById(
    int inspectionId,
    Map<String, dynamic> body,
  ) async {
    try {
      final url = '$baseUrl/dynamic-inspections/$inspectionId/submit';
      log('Finalising inspection $inspectionId at: $url');
      if (kDebugMode) log('Submission body: $body');

      final response = await http.post(
        Uri.parse(url),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode(body),
      ).timeout(_requestTimeout);

      log('Submit-by-id response status: ${response.statusCode}');
      if (kDebugMode) log('Submit-by-id response body: ${response.body}');

      return _parseSubmitResponse(response);
    } on UnauthorizedException {
      rethrow;
    } catch (e) {
      log('Error finalising inspection $inspectionId: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Saves one section to the server so the resume API can return it pre-filled.
  /// POST /api/dynamic-inspections/{id}/save-step
  static Future<Map<String, dynamic>> saveInspectionStep(
    int inspectionId, {
    required String section,
    required List<Map<String, dynamic>> items,
  }) async {
    try {
      final url = '$baseUrl/dynamic-inspections/$inspectionId/save-step';
      log('Saving step for inspection $inspectionId, section: $section');

      final response = await http.post(
        Uri.parse(url),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode({'section': section, 'items': items}),
      ).timeout(_requestTimeout);

      log('save-step response status: ${response.statusCode}');
      log('save-step response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);
        return {
          'success': true,
          'data': responseData['data'],
          'saved_sections': responseData['data']?['saved_sections'],
          'message': responseData['message'] ?? 'Section saved',
        };
      }
      return {'success': false, 'message': _handleError(response)};
    } catch (e) {
      log('Error saving inspection step: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  static Future<Map<String, dynamic>> updateDynamicInspection(
    int inspectionId,
    Map<String, dynamic> data,
  ) async {
    try {
      final response = await http.put(
        Uri.parse('$baseUrl$submitDynamicInspectionEndPoint/$inspectionId'),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode(data),
      ).timeout(_requestTimeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);
        return {
          'success': true,
          'data': responseData['data'],
          'message': responseData['message'] ?? 'Updated successfully',
        };
      }
      return {'success': false, 'message': _handleError(response)};
    } catch (e) {
      log('Error updating dynamic inspection: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  static Future<Map<String, dynamic>> getModels() async {
    try {
      log('Fetching vehicle models from: $baseUrl$getModelsEndpoint');

      final response = await http.get(
        Uri.parse('$baseUrl$getModelsEndpoint'),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      log('Get models response status: ${response.statusCode}');
      log('Get models response body: ${response.body}');

      if (response.statusCode == 200) {
        final responseBody = response.body;
        dynamic responseData;

        // Try to parse the response
        try {
          responseData = json.decode(responseBody);
        } catch (e) {
          log('Error parsing JSON: $e');
          return {
            'success': false,
            'message': 'Invalid response format',
          };
        }

        // Handle both wrapped and unwrapped responses
        List<dynamic> dataList;
        if (responseData is List) {
          // Direct array response
          dataList = responseData;
        } else if (responseData is Map<String, dynamic>) {
          // Wrapped response with status/data
          if (responseData['status'] == 'success' &&
              responseData['data'] != null) {
            dataList = responseData['data'] as List;
          } else {
            return {
              'success': false,
              'message': responseData['message'] ?? 'Failed to fetch models',
            };
          }
        } else {
          return {
            'success': false,
            'message': 'Unexpected response format',
          };
        }

        // Parse models
        List<VehicleModel> models = [];
        for (var item in dataList) {
          try {
            if (item is Map<String, dynamic> || item is Map<dynamic, dynamic>) {
              models.add(VehicleModel.fromJson(item));
            }
          } catch (e) {
            log('Error parsing model item: $e');
            // Continue with other items
          }
        }

        if (models.isEmpty) {
          return {
            'success': false,
            'message': 'No models found',
          };
        }

        // Extract unique brands from the models
        List<VehicleBrand> brands = [];
        final brandMap = <int, VehicleBrand>{};

        for (var model in models) {
          if (!brandMap.containsKey(model.brand.id)) {
            brandMap[model.brand.id] = model.brand;
            brands.add(model.brand);
          }
        }

        // Sort brands alphabetically
        brands.sort((a, b) => a.name.compareTo(b.name));

        log('Fetched ${models.length} models and ${brands.length} brands');

        return {
          'success': true,
          'data': models,
          'brands': brands,
          'message': 'Models retrieved successfully',
        };
      } else {
        return {
          'success': false,
          'message': _handleError(response),
        };
      }
    } catch (e) {
      log('Error fetching models: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Public metadata for filter UIs (`type`: `new` | `old`).
  static Future<Map<String, dynamic>> getCarFilters({String? type}) async {
    try {
      final params = <String, String>{};
      if (type != null && type.isNotEmpty) {
        params['type'] = type;
      }
      final uri = Uri.parse('$baseUrl$carFiltersEndpoint')
          .replace(queryParameters: params.isEmpty ? null : params);

      log('GET car filters: $uri');

      final response = await http.get(
        uri,
        headers: await _getHeaders(requiresAuth: false),
      ).timeout(_requestTimeout);

      log('Car filters status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final data = CarFiltersData.fromJson(responseData);
        return {
          'success': true,
          'data': data,
          'message': 'OK',
        };
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } catch (e) {
      log('Error fetching car filters: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Paginated published new car listings (`GET /api/cars/new`).
  static Future<Map<String, dynamic>> getNewCars({
    int page = 1,
    int perPage = 15,
    String sort = 'newest',
    int? brandId,
    int? vehicleModelId,
    int? categoryId,
    String? priceMin,
    String? priceMax,
    int? yearMin,
    int? yearMax,
    String? transmission,
    String? fuelType,
    String? bodyType,
    int? seatingCapacity,
    int? engineCapacityMin,
    int? engineCapacityMax,
    String? search,
  }) async {
    try {
      final q = <String, String>{
        'page': '$page',
        'per_page': '$perPage',
        'sort': sort,
      };

      void add(String key, Object? value) {
        if (value == null) return;
        final s = value.toString();
        if (s.isEmpty) return;
        q[key] = s;
      }

      add('brand_id', brandId);
      add('vehicle_model_id', vehicleModelId);
      add('category_id', categoryId);
      add('price_min', priceMin);
      add('price_max', priceMax);
      add('year_min', yearMin);
      add('year_max', yearMax);
      add('transmission', transmission);
      add('fuel_type', fuelType);
      add('body_type', bodyType);
      add('seating_capacity', seatingCapacity);
      add('engine_capacity_min', engineCapacityMin);
      add('engine_capacity_max', engineCapacityMax);
      add('search', search);

      final uri =
          Uri.parse('$baseUrl$newCarsEndPoint').replace(queryParameters: q);

      log('GET new cars: $uri');

      final response = await http.get(
        uri,
        headers: await _getHeaders(requiresAuth: false),
      ).timeout(_requestTimeout);

      log('New cars status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final result = NewCarsResult.fromJson(responseData);
        return {
          'success': true,
          'cars': result.cars,
          'meta': result.meta,
          'message': 'OK',
        };
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } catch (e) {
      log('Error fetching new cars: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Paginated published used car listings (`GET /api/cars/old`).
  /// Same query contract as [getNewCars].
  static Future<Map<String, dynamic>> getUsedCars({
    int page = 1,
    int perPage = 15,
    String sort = 'newest',
    int? brandId,
    int? vehicleModelId,
    int? categoryId,
    String? priceMin,
    String? priceMax,
    int? yearMin,
    int? yearMax,
    String? transmission,
    String? fuelType,
    String? bodyType,
    int? seatingCapacity,
    int? engineCapacityMin,
    int? engineCapacityMax,
    String? search,
  }) async {
    try {
      final q = <String, String>{
        'page': '$page',
        'per_page': '$perPage',
        'sort': sort,
      };

      void add(String key, Object? value) {
        if (value == null) return;
        final s = value.toString();
        if (s.isEmpty) return;
        q[key] = s;
      }

      add('brand_id', brandId);
      add('vehicle_model_id', vehicleModelId);
      add('category_id', categoryId);
      add('price_min', priceMin);
      add('price_max', priceMax);
      add('year_min', yearMin);
      add('year_max', yearMax);
      add('transmission', transmission);
      add('fuel_type', fuelType);
      add('body_type', bodyType);
      add('seating_capacity', seatingCapacity);
      add('engine_capacity_min', engineCapacityMin);
      add('engine_capacity_max', engineCapacityMax);
      add('search', search);

      final uri =
          Uri.parse('$baseUrl$userCarsEndPoint').replace(queryParameters: q);

      log('GET used cars: $uri');

      final response = await http.get(
        uri,
        headers: await _getHeaders(requiresAuth: false),
      ).timeout(_requestTimeout);

      log('Used cars status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final result = NewCarsResult.fromJson(responseData);
        return {
          'success': true,
          'cars': result.cars,
          'meta': result.meta,
          'message': 'OK',
        };
      }

      return {
        'success': false,
        'message': _handleError(response),
      };
    } catch (e) {
      log('Error fetching used cars: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  static Future<Map<String, dynamic>> getInspectionStats({
    String period = 'daily',
    String? from,
    String? to,
    String? status,
    int? userId,
  }) async {
    try {
      final params = <String, String>{'period': period};
      if (from != null) params['from'] = from;
      if (to != null) params['to'] = to;
      if (status != null) params['status'] = status;
      if (userId != null) params['user_id'] = userId.toString();

      final uri = Uri.parse('$baseUrl$inspectionStatsEndPoint')
          .replace(queryParameters: params);

      final response = await http.get(
        uri,
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData =
            json.decode(response.body) as Map<String, dynamic>;
        if (responseData['status'] == 'success') {
          return {
            'success': true,
            'data': InspectionStats.fromJson(responseData),
          };
        }
      } else if (response.statusCode == 401) {
        return {'success': false, 'message': 'Unauthorized'};
      }

      return {'success': false, 'message': _handleError(response)};
    } catch (e) {
      log('getInspectionStats error: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  /// Pulls a vehicle brand/model id out of a server payload, tolerating both a
  /// flat `<idKey>` field and a nested `<objKey>: {id, name}` object.
  static int? _extractVehicleId(
      Map<String, dynamic> data, String idKey, String objKey) {
    final flat = data[idKey];
    if (flat != null) {
      return flat is int ? flat : int.tryParse(flat.toString());
    }
    final obj = data[objKey];
    if (obj is Map && obj['id'] != null) {
      final id = obj['id'];
      return id is int ? id : int.tryParse(id.toString());
    }
    return null;
  }

  static Future<Map<String, dynamic>> resumeInspection(int inspectionId) async {
    try {
      final url = '$baseUrl/dynamic-inspections/$inspectionId/resume';
      log('Resuming inspection $inspectionId from: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: await _getHeaders(requiresAuth: true),
      ).timeout(_requestTimeout);

      log('Resume inspection response status: ${response.statusCode}');
      log('Resume inspection response body: ${response.body}');

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);

        if (responseData['status'] == 'success' && responseData['data'] != null) {
          final data = responseData['data'];

          InspectionInitializationResponse? inspectionResponse;
          try {
            inspectionResponse = InspectionInitializationResponse.fromJson(data);
          } catch (e) {
            log('Error parsing resume template: $e');
          }

          // Warm the offline cache for reference images (see initializeInspection).
          if (inspectionResponse != null) {
            unawaited(ReferenceMediaCache.prefetch(
                inspectionResponse.referenceImageUrls));
          }

          return {
            'success': true,
            'data': inspectionResponse ?? data,
            'inspection_id': data['inspection_id'],
            // Brand/model IDs are required by the submit body but are dropped by
            // InspectionInitializationResponse (it only keeps names). Surface
            // them here so the resume flow can rebuild a complete vehicle map.
            'vehicle_brand_id':
                _extractVehicleId(data, 'vehicle_brand_id', 'vehicle_brand'),
            'vehicle_model_id':
                _extractVehicleId(data, 'vehicle_model_id', 'vehicle_model'),
            'processing_status': data['processing_status'],
            'saved_sections': data['saved_sections'],
            'message': 'Inspection resumed successfully',
          };
        }

        return {
          'success': false,
          'message': responseData['message'] ?? 'Failed to resume inspection',
        };
      } else if (response.statusCode == 403) {
        return {'success': false, 'message': 'You do not own this inspection.'};
      } else if (response.statusCode == 404) {
        return {'success': false, 'message': 'Inspection not found.'};
      }

      return {'success': false, 'message': _handleError(response)};
    } catch (e) {
      log('Error resuming inspection: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  static Future<Map<String, dynamic>> getVehicleDetails({
    required String vehicleNumber,
  }) async {
    try {
      log('Fetching vehicle details for: $vehicleNumber');

      final response = await http.post(
        Uri.parse('$baseUrl$vehicleDetailsEndPoint'),
        headers: await _getHeaders(requiresAuth: true),
        body: json.encode({
          'vehiclenumber': vehicleNumber,
        }),
      ).timeout(_requestTimeout);

      log('Vehicle details response status: ${response.statusCode}');
      log('Vehicle details response body: ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);

        if (responseData['status'] == 'success' &&
            responseData['data'] != null) {
          log('Vehicle details fetched successfully for: $vehicleNumber');

          return {
            'success': true,
            'data': responseData['data'],
            'message': responseData['message'] ??
                'Vehicle details fetched successfully',
          };
        } else {
          return {
            'success': false,
            'message':
                responseData['message'] ?? 'Failed to fetch vehicle details',
          };
        }
      } else {
        return {
          'success': false,
          'message': _handleError(response),
        };
      }
    } catch (e) {
      log('Error fetching vehicle details: $e');
      return {
        'success': false,
        'message': 'Network error: ${e.toString()}',
      };
    }
  }

  // ───────────────────────────── Admin: Leaves ────────────────────────────

  /// `GET /api/admin/leaves` — list all leave requests with optional filters.
  /// Returns `{success, leaves: List<LeaveRequest>, pagination, message}`.
  static Future<Map<String, dynamic>> getAdminLeaves({
    int page = 1,
    int? inspectorId,
    String? status,
    DateTime? date,
    int perPage = 20,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'per_page': '$perPage',
    };
    if (inspectorId != null) params['inspector_id'] = '$inspectorId';
    if (status != null && status.isNotEmpty) params['status'] = status;
    if (date != null) params['date'] = _ymd(date);

    final uri = Uri.parse('$baseUrl$adminLeavesEndPoint')
        .replace(queryParameters: params);
    try {
      final response = await http
          .get(uri, headers: await _getHeaders(requiresAuth: true))
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final rawList = _extractList(responseData, 'leaves');
        final leaves = rawList
            .whereType<Map>()
            .map((e) => LeaveRequest.fromJson(e.cast<String, dynamic>()))
            .toList();
        return {
          'success': true,
          'leaves': leaves,
          'pagination': _extractPagination(
              responseData, _dataMap(responseData)),
          'message': 'Leaves retrieved successfully',
        };
      }
      return {'success': false, 'message': _handleError(response)};
    } on UnauthorizedException {
      return {'success': false, 'message': 'Session expired. Please login again.'};
    } catch (e) {
      log('getAdminLeaves error: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  /// `POST /api/admin/leaves/{id}/approve`. The response may carry a
  /// `conflicting_bookings` array of order IDs to reassign.
  static Future<Map<String, dynamic>> approveLeave(
    int leaveId, {
    String? adminNote,
  }) =>
      _decideLeave(leaveId, 'approve', adminNote);

  /// `POST /api/admin/leaves/{id}/reject`.
  static Future<Map<String, dynamic>> rejectLeave(
    int leaveId, {
    String? adminNote,
  }) =>
      _decideLeave(leaveId, 'reject', adminNote);

  static Future<Map<String, dynamic>> _decideLeave(
    int leaveId,
    String action,
    String? adminNote,
  ) async {
    final uri = Uri.parse('$baseUrl$adminLeavesEndPoint/$leaveId/$action');
    try {
      final response = await http
          .post(
            uri,
            headers: await _getHeaders(requiresAuth: true),
            body: json.encode({
              if (adminNote != null && adminNote.trim().isNotEmpty)
                'admin_note': adminNote.trim(),
            }),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final conflicts =
            AttendanceParse.toStringList(responseData['conflicting_bookings']);
        return {
          'success': true,
          'conflicting_bookings': conflicts,
          'message': responseData['message'] ??
              'Leave request ${action}d successfully.',
        };
      }
      return {'success': false, 'message': _handleError(response)};
    } on UnauthorizedException {
      return {'success': false, 'message': 'Session expired. Please login again.'};
    } catch (e) {
      log('_decideLeave($action) error: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  // ──────────────────────────── Admin: Attendance ─────────────────────────

  /// `GET /api/admin/attendance` — list all attendance records with filters.
  /// Returns `{success, records: List<AttendanceRecord>, pagination, message}`.
  static Future<Map<String, dynamic>> getAdminAttendance({
    int page = 1,
    int? inspectorId,
    DateTime? date,
    String? month, // 'YYYY-MM'
    String? type, // 'available' | 'working'
    int perPage = 30,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'per_page': '$perPage',
    };
    if (inspectorId != null) params['inspector_id'] = '$inspectorId';
    if (date != null) params['date'] = _ymd(date);
    if (month != null && month.isNotEmpty) params['month'] = month;
    if (type != null && type.isNotEmpty) params['type'] = type;

    final uri = Uri.parse('$baseUrl$adminAttendanceEndPoint')
        .replace(queryParameters: params);
    try {
      final response = await http
          .get(uri, headers: await _getHeaders(requiresAuth: true))
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final rawList = _extractList(responseData, 'attendance');
        final records = rawList
            .whereType<Map>()
            .map((e) => AttendanceRecord.fromJson(e.cast<String, dynamic>()))
            .toList();
        return {
          'success': true,
          'records': records,
          'pagination': _extractPagination(
              responseData, _dataMap(responseData)),
          'message': 'Attendance retrieved successfully',
        };
      }
      return {'success': false, 'message': _handleError(response)};
    } on UnauthorizedException {
      return {'success': false, 'message': 'Session expired. Please login again.'};
    } catch (e) {
      log('getAdminAttendance error: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  // ─────────────────────────── Inspector: Leaves ──────────────────────────

  /// `GET /api/inspector/leaves` — the signed-in inspector's own requests.
  /// Returns `{success, leaves: List<InspectorLeave>, pagination, message}`.
  static Future<Map<String, dynamic>> getInspectorLeaves({
    int page = 1,
    String? status,
    int perPage = 15,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'per_page': '$perPage',
    };
    if (status != null && status.isNotEmpty) params['status'] = status;

    final uri = Uri.parse('$baseUrl$inspectorLeavesEndPoint')
        .replace(queryParameters: params);
    try {
      final response = await http
          .get(uri, headers: await _getHeaders(requiresAuth: true))
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final rawList = _extractList(responseData, 'leaves');
        final leaves = rawList
            .whereType<Map>()
            .map((e) => InspectorLeave.fromJson(e.cast<String, dynamic>()))
            .toList();
        return {
          'success': true,
          'leaves': leaves,
          'pagination':
              _extractPagination(responseData, _dataMap(responseData)),
          'message': 'Leaves retrieved successfully',
        };
      }
      return {'success': false, 'message': _handleError(response)};
    } on UnauthorizedException {
      return {'success': false, 'message': 'Session expired. Please login again.'};
    } catch (e) {
      log('getInspectorLeaves error: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  /// `POST /api/inspector/leaves` — request leave for a single day.
  /// On success returns `{success, leave, warning, message}`; `warning` is a
  /// non-null string when the inspector has bookings to be reassigned that day.
  static Future<Map<String, dynamic>> requestLeave({
    required DateTime leaveDate,
    String? reason,
  }) async {
    final uri = Uri.parse('$baseUrl$inspectorLeavesEndPoint');
    try {
      final response = await http
          .post(
            uri,
            headers: await _getHeaders(requiresAuth: true),
            body: json.encode({
              'leave_date': _ymd(leaveDate),
              if (reason != null && reason.trim().isNotEmpty)
                'reason': reason.trim(),
            }),
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final data = responseData['data'];
        return {
          'success': true,
          'leave': data is Map
              ? InspectorLeave.fromJson(data.cast<String, dynamic>())
              : null,
          'warning': responseData['warning']?.toString(),
          'message':
              responseData['message']?.toString() ?? 'Leave request submitted.',
        };
      }
      return {'success': false, 'message': _handleError(response)};
    } on UnauthorizedException {
      return {'success': false, 'message': 'Session expired. Please login again.'};
    } catch (e) {
      log('requestLeave error: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  /// `DELETE /api/inspector/leaves/{id}` — cancel a still-pending request.
  static Future<Map<String, dynamic>> cancelLeave(int leaveId) async {
    final uri = Uri.parse('$baseUrl$inspectorLeavesEndPoint/$leaveId');
    try {
      final response = await http
          .delete(uri, headers: await _getHeaders(requiresAuth: true))
          .timeout(_requestTimeout);

      if (response.statusCode == 200 || response.statusCode == 204) {
        String message = 'Leave request cancelled.';
        if (response.body.isNotEmpty) {
          try {
            final body = json.decode(response.body);
            if (body is Map && body['message'] != null) {
              message = body['message'].toString();
            }
          } catch (_) {}
        }
        return {'success': true, 'message': message};
      }
      return {'success': false, 'message': _handleError(response)};
    } on UnauthorizedException {
      return {'success': false, 'message': 'Session expired. Please login again.'};
    } catch (e) {
      log('cancelLeave error: $e');
      return {'success': false, 'message': 'Network error: ${e.toString()}'};
    }
  }

  /// Formats a [DateTime] as the `YYYY-MM-DD` the API expects for `date` params.
  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Returns the map under `data`, or the top-level map if `data` isn't a map.
  static Map<String, dynamic> _dataMap(Map<String, dynamic> responseData) {
    final data = responseData['data'];
    if (data is Map) return data.cast<String, dynamic>();
    return responseData;
  }

  /// Pulls a list out of a response that may put it at the top level, under
  /// `data` directly (paginated `data: [...]`), or under `data.<key>`.
  static List<dynamic> _extractList(
      Map<String, dynamic> responseData, String key) {
    final data = responseData['data'];
    if (data is List) return data;
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      for (final candidate in [m[key], m['data'], m['items']]) {
        if (candidate is List) return candidate;
      }
    }
    if (responseData[key] is List) return responseData[key] as List;
    return const [];
  }
}
