import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/media_url.dart';

/// Progress of an in-flight [ReferenceMediaCache.prefetch] run, surfaced via
/// [ReferenceMediaCache.progress] so the UI can show a caching progress bar.
class ReferenceCacheProgress {
  final int done;
  final int total;

  const ReferenceCacheProgress({required this.done, required this.total});

  bool get isComplete => done >= total;
  double get fraction => total == 0 ? 1.0 : done / total;
}

/// On-disk cache for admin reference media (guide images) so they remain
/// visible to the inspector after the device drops offline.
///
/// Files live under [getApplicationSupportDirectory] (NOT the temp dir, which
/// iOS purges between launches) in a `reference_media_cache/` folder. The
/// filename is a deterministic hash of the normalised URL, so disk existence
/// alone answers "is this cached?" — no index DB needed.
///
/// The cache is keyed by URL, NOT by inspection, so a reference image shared by
/// many inspections is downloaded once and reused — it stays on disk when a new
/// inspection starts. [prefetch] revalidates cached files with the server using
/// stored ETag / Last-Modified validators, so an image is re-downloaded ONLY
/// when its content actually changed (a 304 keeps the existing copy).
class ReferenceMediaCache {
  ReferenceMediaCache._();

  static const _folder = 'reference_media_cache';

  /// Max images fetched concurrently — bounded so a large inspection doesn't
  /// open dozens of sockets at once, while still being far faster than serial.
  static const _maxConcurrent = 5;

  static Directory? _dir;
  static bool _running = false;

  /// In-flight downloads keyed by URL. Ensures a given image is fetched only
  /// once at a time — without this, opening a field while [prefetch] is running
  /// triggers a SECOND concurrent download of the same URL (the widget's own
  /// warm), and both writers race on the same temp file, producing a corrupt
  /// image that fails to decode. Concurrent callers share the one future.
  static final Map<String, Future<bool>> _inflight = {};

  /// Monotonic counter for unique temp filenames (belt-and-suspenders against
  /// any temp-file collision).
  static int _tmpCounter = 0;

  /// Live progress of the current prefetch (null when idle / nothing to cache).
  /// The inspection screen listens to this to render a caching progress bar.
  static final ValueNotifier<ReferenceCacheProgress?> progress =
      ValueNotifier<ReferenceCacheProgress?>(null);

  static Future<Directory> _cacheDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_folder');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  /// Deterministic filename for [rawUrl] using FNV-1a (64-bit). Stable across
  /// launches and platforms, so a previously-cached URL always maps to the
  /// same file. No `crypto` dependency required.
  static String _keyFor(String rawUrl) {
    final norm = mediaUri(rawUrl).toString();
    var hash = 0xcbf29ce484222325;
    for (final unit in norm.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// Sidecar file holding the HTTP validators (ETag / Last-Modified) for a
  /// cached image, used to revalidate it cheaply on the next prefetch.
  static File _metaFile(File file) => File('${file.path}.meta');

  /// Returns the on-disk [File] for [rawUrl] only if it has been cached and
  /// still exists; otherwise null so callers fall back to the network. Never
  /// hits the network — safe to call while offline.
  static Future<File?> cachedFile(String rawUrl) async {
    if (rawUrl.isEmpty) return null;
    try {
      final file = File('${(await _cacheDir()).path}/${_keyFor(rawUrl)}');
      return file.existsSync() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// Ensures [rawUrl] is cached on disk. Writes atomically (temp + rename) so an
  /// interrupted download never leaves a truncated, corrupt image.
  ///
  /// When [revalidate] is true and the file is already cached, a conditional
  /// GET (If-None-Match / If-Modified-Since) is sent: a `304 Not Modified` keeps
  /// the existing file, a `200` replaces it. So the image is re-downloaded ONLY
  /// when it actually changed. When [revalidate] is false, an existing file is
  /// returned immediately with no network call.
  ///
  /// Returns true if the image is on disk after the call. Concurrent calls for
  /// the same URL share a single download (see [_inflight]).
  static Future<bool> warm(String rawUrl,
      {bool revalidate = false, http.Client? client}) {
    if (rawUrl.isEmpty) return Future.value(false);
    final existing = _inflight[rawUrl];
    if (existing != null) return existing;
    // NOTE: the cleanup MUST be a block body, not `() => _inflight.remove(...)`.
    // `Map.remove` returns the removed value (this very future), and
    // `Future.whenComplete` waits on any Future its callback returns — so the
    // arrow form makes `future` wait on itself and never completes, wedging the
    // prefetch pool after exactly `_maxConcurrent` items.
    final future = _warm(rawUrl, revalidate: revalidate, client: client)
        .whenComplete(() {
      _inflight.remove(rawUrl);
    });
    _inflight[rawUrl] = future;
    return future;
  }

  static Future<bool> _warm(String rawUrl,
      {bool revalidate = false, http.Client? client}) async {
    if (rawUrl.isEmpty) return false;

    final File file;
    final bool exists;
    try {
      file = File('${(await _cacheDir()).path}/${_keyFor(rawUrl)}');
      exists = file.existsSync();
    } catch (_) {
      return false;
    }

    // Fast path: already cached and we're not asked to check for changes.
    if (exists && !revalidate) {
      debugPrint('[ReferenceMediaCache] hit (already cached): $rawUrl');
      return true;
    }

    try {
      final headers = <String, String>{};
      if (exists) {
        final meta = await _readMeta(file);
        final etag = meta?['etag'];
        final lastMod = meta?['lastModified'];
        if (etag != null) headers['If-None-Match'] = etag;
        if (lastMod != null) headers['If-Modified-Since'] = lastMod;
      }

      // Use the caller-supplied client when given (prefetch shares ONE client
      // across all images so its keep-alive pool reuses a handful of sockets);
      // fall back to the top-level helper for one-off widget warms.
      final getter = client?.get ?? http.get;
      final response = await getter(mediaUri(rawUrl), headers: headers)
          .timeout(const Duration(seconds: 30));

      // Server confirms our copy is current — keep it.
      if (response.statusCode == 304) {
        debugPrint('[ReferenceMediaCache] unchanged (304): $rawUrl');
        return true;
      }

      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        debugPrint('[ReferenceMediaCache] skip: HTTP ${response.statusCode}, '
            '${response.bodyBytes.length}B for $rawUrl');
        return exists; // keep any stale copy we already had
      }

      final tmp = File('${file.path}.${_tmpCounter++}.tmp');
      await tmp.writeAsBytes(response.bodyBytes, flush: true);
      await tmp.rename(file.path);
      await _writeMeta(file, rawUrl, response.headers);

      debugPrint('[ReferenceMediaCache] ${exists ? 'updated' : 'cached'} '
          '${response.bodyBytes.length}B -> ${file.path.split('/').last} '
          '<- $rawUrl');
      return true;
    } catch (e) {
      if (_isOffline(e)) {
        debugPrint('[ReferenceMediaCache] offline, kept cached=$exists: $rawUrl');
      } else {
        debugPrint('[ReferenceMediaCache] warm FAILED for $rawUrl: $e');
      }
      // Offline (or error) during revalidation: the existing file is untouched,
      // so it's still usable — count it as cached.
      return exists;
    }
  }

  /// Warms every URL in [urls] (deduped, empties skipped) with up to
  /// [_maxConcurrent] downloads in flight at once, revalidating already-cached
  /// files so only changed images re-download. Updates [progress] as it goes.
  ///
  /// This caches ALL reference images up front — the inspector does NOT need to
  /// open each field; navigating offline later finds every image on disk. Cached
  /// images persist across inspections (keyed by URL), so a new inspection that
  /// reuses an image gets an instant hit.
  ///
  /// [revalidate] controls whether already-cached files are checked against the
  /// server. Pass true on first fetch (initialize) to pick up the latest guide
  /// images; pass false when re-entering an existing draft so cached files are
  /// trusted as-is and only missing ones download — otherwise every draft resume
  /// re-downloads the whole set when the server omits ETag/Last-Modified.
  static Future<void> prefetch(Iterable<String> urls,
      {bool revalidate = true}) async {
    final unique = <String>{};
    for (final url in urls) {
      if (url.isNotEmpty) unique.add(url);
    }
    if (unique.isEmpty) {
      debugPrint('[ReferenceMediaCache] prefetch: no reference images to cache');
      return;
    }
    if (_running) {
      debugPrint('[ReferenceMediaCache] prefetch already running — skipping');
      return;
    }
    _running = true;

    final list = unique.toList();
    debugPrint('[ReferenceMediaCache] prefetch START — ${list.length} image(s), '
        'up to $_maxConcurrent at a time');
    progress.value = ReferenceCacheProgress(done: 0, total: list.length);

    var cached = 0;
    var failed = 0;
    var completed = 0;
    var next = 0;

    // ONE client for the whole run instead of the top-level `http.get`, which
    // spins up (and must tear down) a fresh HttpClient per request. A shared
    // client reuses a small keep-alive connection pool across all 190 images —
    // far less socket churn against the host.
    final client = http.Client();

    // Worker pool: each worker pulls the next index until the list is drained.
    // Dart's single-threaded event loop makes `next++` and the counter updates
    // atomic between awaits, so no locking is needed.
    //
    // Every item is wrapped in its own try/catch: a single failing URL (a file
    // I/O error, a malformed source, anything `warm` doesn't already swallow)
    // must NOT escape the worker. If it did, `Future.wait` would reject on the
    // first error and stop awaiting the other workers — leaving `progress` at a
    // partial, never-complete count, so the caching bar would spin forever.
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= list.length) break;
        try {
          if (await warm(list[i], revalidate: revalidate, client: client)) {
            cached++;
          } else {
            failed++;
          }
        } catch (e) {
          failed++;
          debugPrint('[ReferenceMediaCache] item FAILED ${list[i]}: $e');
        }
        completed++;
        progress.value =
            ReferenceCacheProgress(done: completed, total: list.length);
      }
    }

    try {
      final workerCount =
          list.length < _maxConcurrent ? list.length : _maxConcurrent;
      // Overall backstop: even if something wedges a worker, the whole run
      // cannot outlast this deadline, so the bar is guaranteed to clear.
      await Future.wait([for (var i = 0; i < workerCount; i++) worker()])
          .timeout(const Duration(minutes: 5));
    } on TimeoutException {
      debugPrint('[ReferenceMediaCache] prefetch TIMED OUT at '
          '$completed/${list.length} — clearing bar');
    } finally {
      _running = false;
      client.close();
      // Clear progress unconditionally so the caching bar always disappears once
      // the run ends, regardless of how many items succeeded or failed.
      progress.value = null;
      debugPrint('[ReferenceMediaCache] prefetch DONE — $cached cached, '
          '$failed failed of ${list.length}');
    }
  }

  static Future<Map<String, String>?> _readMeta(File file) async {
    try {
      final meta = _metaFile(file);
      if (!meta.existsSync()) return null;
      final decoded = json.decode(await meta.readAsString());
      if (decoded is! Map) return null;
      return {
        for (final entry in decoded.entries)
          if (entry.value != null) entry.key.toString(): entry.value.toString(),
      };
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeMeta(
    File file,
    String url,
    Map<String, String> responseHeaders,
  ) async {
    try {
      final etag = responseHeaders['etag'];
      final lastMod = responseHeaders['last-modified'];
      final meta = _metaFile(file);
      if (etag == null && lastMod == null) {
        // Server gave us no validators — drop any stale meta so we don't send
        // outdated conditional headers next time.
        if (meta.existsSync()) await meta.delete();
        return;
      }
      await meta.writeAsString(
        json.encode({
          'url': url,
          if (etag != null) 'etag': etag,
          if (lastMod != null) 'lastModified': lastMod,
        }),
        flush: true,
      );
    } catch (_) {
      // Meta is an optimisation; failing to write it just means a full
      // re-download next revalidation instead of a 304.
    }
  }

  static bool _isOffline(Object e) {
    if (e is SocketException || e is TimeoutException) return true;
    final s = e.toString();
    return s.contains('Failed host lookup') ||
        s.contains('Connection closed') ||
        s.contains('Connection reset') ||
        s.contains('ClientException');
  }
}
