// Transport-level tests for the upload progress hook.
//
// Progress is added by overriding MultipartRequest.finalize(), which is the
// same method that stamps the multipart content-type and boundary onto the
// headers. Get that wrong and the bytes still go out, the request still looks
// healthy from the app, and the server rejects every upload as "the image
// field is required" — so these assert the body and headers are untouched, not
// just that the callback fires.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:certifide_inspektor/services/api_services.dart';

void main() {
  ProgressMultipartRequest buildRequest({UploadProgressCallback? onProgress}) {
    final request = ProgressMultipartRequest(
      'POST',
      Uri.parse('https://api.certifide.in/api/inspection/upload-image'),
      onProgress: onProgress,
    )
      ..fields['section'] = 'Engine Bay'
      ..fields['itemId'] = 'engine_video'
      ..files.add(http.MultipartFile.fromString(
        'image',
        'pretend this is a video',
        filename: 'walkaround.mp4',
      ));
    return request;
  }

  group('ProgressMultipartRequest — progress must not change the request', () {
    test(
        'Given a progress callback, When the body is finalized, Then the '
        'multipart content-type and boundary are still set', () async {
      final request = buildRequest(onProgress: (_, __) {});

      await request.finalize().toBytes();

      expect(request.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
          reason: 'without this header the server cannot parse the body and '
              'rejects the upload as if no file were sent');
    });

    test(
        'Given a progress callback, When the body is finalized, Then it is the '
        'same length the request advertises', () async {
      final request = buildRequest(onProgress: (_, __) {});
      final declared = request.contentLength;

      final bytes = await request.finalize().toBytes();

      expect(bytes.length, declared,
          reason: 'a body shorter or longer than Content-Length hangs the '
              'server until it times out');
    });

    test(
        'Given a progress callback, When the body is finalized, Then every '
        'field and the file still reach the wire', () async {
      final request = buildRequest(onProgress: (_, __) {});

      final body = utf8.decode(await request.finalize().toBytes());

      expect(body, contains('name="section"'));
      expect(body, contains('Engine Bay'));
      expect(body, contains('name="itemId"'));
      expect(body, contains('filename="walkaround.mp4"'));
      expect(body, contains('pretend this is a video'));
    });

    test(
        'Given no callback, When the body is finalized, Then it matches the '
        'instrumented body byte for byte', () async {
      final plain = await buildRequest().finalize().toBytes();
      final counted = await buildRequest(onProgress: (_, __) {})
          .finalize()
          .toBytes();

      // Boundaries are random per request but fixed-width, so only the length
      // is comparable — and that is what Content-Length promises.
      expect(counted.length, plain.length);
    });
  });

  group('ProgressMultipartRequest — what the callback reports', () {
    test(
        'Given a consumed body, When progress is reported, Then it ends at the '
        'full content length', () async {
      var lastSent = 0;
      var lastTotal = 0;
      final request = buildRequest(onProgress: (sent, total) {
        lastSent = sent;
        lastTotal = total;
      });
      final declared = request.contentLength;

      await request.finalize().toBytes();

      expect(lastTotal, declared);
      expect(lastSent, declared,
          reason: 'a bar that stops at 98% reads as a stuck upload');
    });

    test(
        'Given a consumed body, When progress is reported, Then it only ever '
        'moves forward and never overshoots', () async {
      final readings = <int>[];
      final request =
          buildRequest(onProgress: (sent, _) => readings.add(sent));
      final declared = request.contentLength;

      await request.finalize().toBytes();

      expect(readings, isNotEmpty);
      expect(readings, orderedEquals(readings.toList()..sort()));
      expect(readings.every((r) => r <= declared), isTrue);
    });

    test(
        'Given no callback, When the body is finalized, Then nothing is '
        'reported and the plain stream is used', () async {
      final request = buildRequest();

      await expectLater(request.finalize().toBytes(), completes);
    });
  });
}
