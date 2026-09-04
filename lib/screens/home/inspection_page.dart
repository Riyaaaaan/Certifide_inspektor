// lib/screens/home/inspection_page.dart

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../../constants/hive_constants.dart';
import '../../data/inspection_storage_model.dart';
import '../../services/reference_media_cache.dart';
import '../../models/inspection_item.dart';
import '../../models/inspection_state.dart';
import '../../utils/upload_display.dart';
import '../../models/inspection_template_model.dart';
import '../../models/pending_media.dart';
import '../../providers/inspection_provider.dart';
import '../../providers/inspection_session_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_services.dart';
import '../../services/local_storage_services.dart';
import '../../services/reports_cache_service.dart';
import '../../utils/connectivity_checker.dart';
import '../../widgets/inspection_field_info_sheet.dart';
import '../../widgets/section_camera_card.dart';
import '../../widgets/section_video_camera_card.dart';
import '../main_screen.dart';
import 'inspection_page/components/inspection_flag_issues_sheet.dart';
import 'inspection_page/components/inspection_file_review.dart';
import 'inspection_page/components/inspection_image_review.dart';
import 'inspection_page/components/inspection_video_review.dart';
import 'inspection_page/components/inspection_reference_fullscreen.dart';
import 'inspection_page/components/inspection_sections_drawer.dart';
import 'inspection_page/components/inspection_video_player.dart';
import 'inspection_success_page.dart';

// Top-level function required by compute() — runs in a separate isolate.
// Receives plain-data input, returns the serialized template + copied maps.
Map<String, dynamic> _buildStoragePayload(Map<String, dynamic> input) {
  final itemValues = Map<String, String>.from(
      (input['itemValues'] as Map? ?? {})
          .map((k, v) => MapEntry(k.toString(), v.toString())));
  final itemImages = Map<String, String?>.from(
      (input['itemImages'] as Map? ?? {})
          .map((k, v) => MapEntry(k.toString(), v as String?)));
  final itemVideos = Map<String, String?>.from(
      (input['itemVideos'] as Map? ?? {})
          .map((k, v) => MapEntry(k.toString(), v as String?)));
  final itemAudios = Map<String, String?>.from(
      (input['itemAudios'] as Map? ?? {})
          .map((k, v) => MapEntry(k.toString(), v as String?)));
  final itemFiles = Map<String, String?>.from((input['itemFiles'] as Map? ?? {})
      .map((k, v) => MapEntry(k.toString(), v as String?)));
  final itemRemarks = Map<String, String>.from(
      (input['itemRemarks'] as Map? ?? {})
          .map((k, v) => MapEntry(k.toString(), v.toString())));
  final textFieldValues = Map<String, String>.from(
      (input['textFieldValues'] as Map? ?? {})
          .map((k, v) => MapEntry(k.toString(), v.toString())));
  final rawMultiImages = input['multiImages'] as Map?;
  final multiImages = rawMultiImages == null
      ? null
      : Map<String, List<String>>.from(rawMultiImages.map((k, v) => MapEntry(
          k.toString(), (v as List).map((e) => e.toString()).toList())));
  final rawFlaggedIssues = input['itemFlaggedIssues'] as Map?;
  final itemFlaggedIssues = rawFlaggedIssues == null
      ? <String, List<String>>{}
      : Map<String, List<String>>.from(rawFlaggedIssues.map((k, v) => MapEntry(
          k.toString(), (v as List).map((e) => e.toString()).toList())));
  return {
    'itemValues': itemValues,
    'itemImages': itemImages,
    'itemVideos': itemVideos,
    'itemAudios': itemAudios,
    'itemFiles': itemFiles,
    'itemRemarks': itemRemarks,
    'textFieldValues': textFieldValues,
    'multiImages': multiImages,
    'itemFlaggedIssues': itemFlaggedIssues,
    'vehicleDetails': input['vehicleDetails'],
    'inspectionTemplate': input['inspectionTemplate'],
    'currentSection': input['currentSection'],
    'inspectionId': input['inspectionId'],
  };
}

/// One field whose media could not be uploaded, paired with the reason the
/// server or the network gave.
///
/// The reason is what makes the failure sheet actionable: "too large" needs a
/// shorter recapture, "timed out" needs a better connection, and a validation
/// message needs a bug report. Reporting only the field name left the inspector
/// retrying the same doomed submit.
class MediaUploadFailure {
  final String field;
  final String reason;

  const MediaUploadFailure(this.field, this.reason);
}

class InspectionScreen extends ConsumerStatefulWidget {
  final bool isNewInspection;
  final Map<String, dynamic>? vehicleDetails;
  final int? inspectionId;
  final InspectionInitializationResponse? inspectionTemplate;

  const InspectionScreen({
    super.key,
    this.isNewInspection = false,
    this.vehicleDetails,
    this.inspectionId,
    this.inspectionTemplate,
  });

  @override
  ConsumerState<InspectionScreen> createState() => _InspectionScreenState();
}

/// Holds the transient camera-overlay flags as [ValueNotifier]s so that
/// toggling them (flash, start/stop recording, pause/resume) rebuilds only the
/// camera overlay via a [ListenableBuilder] instead of `setState`-ing the whole
/// inspection screen. Audio recording is intentionally excluded — it changes
/// which capture widget is built, so it still needs a full rebuild.
class _CaptureUiState {
  final ValueNotifier<bool> flashOn = ValueNotifier(false);
  final ValueNotifier<bool> isVideoRecording = ValueNotifier(false);
  final ValueNotifier<bool> isVideoPaused = ValueNotifier(false);

  late final Listenable listenable =
      Listenable.merge([flashOn, isVideoRecording, isVideoPaused]);

  void dispose() {
    flashOn.dispose();
    isVideoRecording.dispose();
    isVideoPaused.dispose();
  }
}

class _InspectionScreenState extends ConsumerState<InspectionScreen>
    with WidgetsBindingObserver {
  // Survives navigation — keyed by "${brandId}_${modelId}"
  static final Map<String, InspectionInitializationResponse> _templateCache =
      {};

  // Set true on successful submit so dispose() doesn't snapshot a dead session.
  bool _sessionCompleted = false;

  Timer? _saveDebouncer;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _scrollController = ScrollController();
  int _currentSection = 0;
  int _currentItemIndex = 0;
  Map<String, String?> itemImages = {};
  Map<String, String?> itemVideos = {};
  Map<String, int> itemVideoRotations = {};
  Map<String, String?> itemAudios = {};
  Map<String, String?> itemFiles = {};
  Map<String, String> itemRemarks = {};
  Map<String, String> itemValues = {};
  Map<String, List<String>?> itemMultiImages = {};
  Map<String, TextEditingController> remarksControllers = {};
  Map<String, TextEditingController> numberRemarkControllers = {};
  Map<String, TextEditingController> textFieldControllers = {};
  Map<String, dynamic>? vehicleDetails;
  bool _isSubmitting = false;
  // ValueNotifier so upload spinners rebuild only their own widget (via
  // ValueListenableBuilder), not the whole screen, on add/remove.
  final ValueNotifier<Set<String>> _uploadingImages = ValueNotifier(<String>{});

  /// Byte progress for the field currently uploading, keyed by uniqueId. Kept
  /// in a ValueNotifier rather than setState so a video streaming for two
  /// minutes repaints one badge instead of the whole form.
  final ValueNotifier<Map<String, MediaFileProgress>> _uploadProgress =
      ValueNotifier(const {});

  /// Last published sample per field, for deriving a rate and for throttling.
  final Map<String, ({DateTime at, int sent})> _uploadSamples = {};

  static const Duration _uploadProgressFrame = Duration(milliseconds: 400);
  final Set<String> _uploadingMultiImagePaths = {};
  String? _verifyingRegNoUniqueId;
  final Map<String, String> _regNoVerifyMessage = {};
  final Map<String, bool> _regNoVerifyIsError = {};
  Map<String, List<String>> itemFlaggedIssues = {};
  XFile? _pendingCapturedXFile;
  String? _pendingCapturedUniqueId;
  bool _isReviewingCapture = false;
  XFile? _pendingCapturedVideoFile;
  String? _pendingCapturedVideoUniqueId;
  bool _isReviewingVideo = false;
  String? _pendingCapturedAudioPath;
  String? _pendingCapturedAudioUniqueId;
  bool _isReviewingAudio = false;
  String? _pendingCapturedFilePath;
  String? _pendingCapturedFileUniqueId;
  String? _pendingCapturedFileName;
  String? _pendingCapturedFileExtension;
  bool _isReviewingFile = false;
  String _currentCaptureMode = 'PHOTO';
  // Bound to SectionCameraCard when showControls:false; resets on item change.
  VoidCallback? _triggerPhotoCapture;
  VoidCallback? _triggerEnlarge;
  VoidCallback? _triggerFlashToggle;
  VoidCallback? _triggerVideoToggle;
  VoidCallback? _triggerVideoPauseResume;
  // Transient camera-overlay flags (flash on, recording, paused). Held as
  // ValueNotifiers so toggling them rebuilds only the camera overlay (via a
  // ListenableBuilder), not the whole inspection screen.
  final _CaptureUiState _captureUi = _CaptureUiState();
  AudioRecorder? _audioRecorder;
  bool _isRecordingAudio = false;
  Timer? _audioTimer;
  // ValueNotifier so the per-second timer tick only rebuilds the duration
  // label (via ValueListenableBuilder), not the entire screen tree.
  final ValueNotifier<Duration> _audioElapsed = ValueNotifier(Duration.zero);
  // ValueNotifier so toggling the flag-issue highlight rebuilds only that
  // button (via ValueListenableBuilder), not the whole screen.
  final ValueNotifier<bool> _highlightFlagIssues = ValueNotifier(false);
  // Holds the uniqueId of a missing required field to highlight in red after
  // the user is sent back to it from the "required fields" sheet. Cleared once
  // they fill it in or navigate away.
  final ValueNotifier<String?> _highlightMissingFieldId =
      ValueNotifier<String?>(null);

  // Section slugs whose fields changed since the last server save. Edits mark
  // their section dirty (instead of POSTing each field); the whole section is
  // save-stepped on leaving it (and as part of submit). Keeps requests batched
  // per section rather than one-per-field. See [_flushDirtySectionsToServer].
  final Set<String> _dirtySectionNames = {};
  bool _isFlushingSections = false;

  // Dynamic inspection template from API
  InspectionInitializationResponse? _inspectionTemplate;
  bool _useDynamicTemplate = false;
  bool _isLoadingTemplate = true; // Track if template is still loading

  /// Server inspection id: from route, Hive snapshot, or refetch when resuming.
  int? _sessionInspectionId;

  int? get _effectiveInspectionId =>
      _sessionInspectionId ?? widget.inspectionId;

  /// Folder label used for user-visible media storage: "yyyy-MM-dd_HH-mm-ss_{id}".
  /// Computed once, then cached in vehicleDetails so resumed inspections reuse
  /// the same folder instead of creating a new one.
  String? _inspectionFolderLabel;

  String get _folderLabelForStorage {
    if (_inspectionFolderLabel != null) return _inspectionFolderLabel!;

    // Restored from Hive / snapshot — reuse the previously created label.
    final stored = vehicleDetails?['_folderLabel'];
    if (stored is String && stored.isNotEmpty) {
      _inspectionFolderLabel = stored;
      return _inspectionFolderLabel!;
    }

    final id = _effectiveInspectionId;
    final now = DateTime.now();
    final ts = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}-'
        '${now.minute.toString().padLeft(2, '0')}-'
        '${now.second.toString().padLeft(2, '0')}';
    _inspectionFolderLabel = id != null ? '${ts}_$id' : ts;

    // Persist so the same label survives app resume.
    vehicleDetails ??= {};
    vehicleDetails!['_folderLabel'] = _inspectionFolderLabel;

    return _inspectionFolderLabel!;
  }

  int get _totalFields =>
      _sections.fold(0, (sum, s) => sum + (s['items'] as List).length);

  int get _processedFields {
    int count = 0;
    for (int i = 0; i < _currentSection; i++) {
      count += (_sections[i]['items'] as List).length;
    }
    return count + _currentItemIndex;
  }

  int get _progressPercent {
    if (_totalFields == 0) return 0;
    return ((_processedFields / _totalFields) * 100).round();
  }

  static const String INSPECTION_BOX = HiveConstants.INSPECTION_BOX;
  Box<InspectionStorageModel>? _inspectionBox;

  // Memoized result of [_buildSections] plus the inputs it was built from.
  // The template object is always replaced wholesale (never mutated in place),
  // so identity of the template + the dynamic flag is a sufficient cache key.
  List<Map<String, dynamic>>? _cachedSections;
  InspectionInitializationResponse? _cachedSectionsTemplate;
  bool? _cachedSectionsUseDynamic;

  // Get sections - either from dynamic template or default.
  // Memoized: the heavy sort/deep-copy/map runs once per template, not on
  // every read (this getter is read 5+ times per setState).
  List<Map<String, dynamic>> get _sections {
    if (_cachedSections != null &&
        identical(_cachedSectionsTemplate, _inspectionTemplate) &&
        _cachedSectionsUseDynamic == _useDynamicTemplate) {
      return _cachedSections!;
    }
    final sections = _buildSections();
    _cachedSections = sections;
    _cachedSectionsTemplate = _inspectionTemplate;
    _cachedSectionsUseDynamic = _useDynamicTemplate;
    return sections;
  }

  List<Map<String, dynamic>> _buildSections() {
    if (_useDynamicTemplate && _inspectionTemplate != null) {
      final sections = _inspectionTemplate!.structure.sections;
      // Sort sections by order
      sections.sort((a, b) => a.order.compareTo(b.order));
      return sections.map((section) {
        // Sort fields by order
        final sortedFields = List<InspectionField>.from(section.fields);
        sortedFields.sort((a, b) => a.order.compareTo(b.order));

        return {
          'title': section.title,
          'name': section.name,
          'id': section.id,
          'order': section.order,
          'items': sortedFields.map((field) {
            return _createDynamicItem(field);
          }).toList(),
        };
      }).toList();
    }
    // return _defaultSections;
    return [];
  }

  // Create a dynamic item from API field
  dynamic _createDynamicItem(InspectionField field) {
    final fieldType = field.fieldType.toLowerCase();

    // Check if this is an image field type or has hasImage flag
    final isImageField = fieldType == 'image' || field.hasImage;
    // Multi-image when explicitly flagged OR when it's a text+image field
    // (summary-style fields: write text and attach multiple photos).
    final useMultiImage =
        field.hasMultipleImages || (fieldType == 'text' && field.hasImage);

    return {
      'id': field.fieldId,
      'title': field.title,
      'fieldId': field.fieldId,
      'fieldType': fieldType,
      'isRequired': field.isRequired,
      'hasRemarks': field.hasRemarks,
      'hasImage': useMultiImage ? false : isImageField,
      'hasVideo': field.hasVideo,
      'hasFile': field.hasFile,
      'allowMultiImage': useMultiImage,
      'useTextField':
          fieldType == 'text' || fieldType == 'date' || useMultiImage,
      'options': field.options
          .map((opt) => {
                'id': opt.id,
                'value': opt.value,
                'label': opt.label,
                'colorName': opt.colorName,
                'colorCode': opt.colorCode,
                'order': opt.order,
              })
          .toList(),
      'order': field.order,
      'metadata': field.metadata,
      'referenceMedia': field.referenceMedia
          .map((m) => {
                'id': m.id,
                'mediaType': m.mediaType,
                'filePath': m.filePath,
                'url': m.url,
                'description': m.description,
                'order': m.order,
              })
          .toList(),
      if (field.initialValue != null) 'initialValue': field.initialValue,
      if (field.initialRemarks != null) 'initialRemarks': field.initialRemarks,
      if (field.initialImage != null) 'initialImage': field.initialImage,
      if (field.initialMultiImages != null)
        'initialMultiImages': field.initialMultiImages,
      if (field.initialVideo != null) 'initialVideo': field.initialVideo,
      if (field.initialAudio != null) 'initialAudio': field.initialAudio,
      if (field.initialFile != null) 'initialFile': field.initialFile,
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initHive();

      if (!mounted) return;

      _sessionInspectionId = widget.inspectionId;

      // Set vehicle details from widget
      vehicleDetails = widget.vehicleDetails;

      // The reports/pending "Resume" path passes isNew:true with the server
      // inspection id. If the local working copy (CURRENT_INSPECTION_KEY) belongs
      // to THIS same inspection, it holds field values + images entered offline
      // that the server template does not carry — so resume from it instead of
      // wiping it. Only a genuinely new inspection (no matching local record)
      // takes the fresh-start path that clears the key.
      // Prefer the durable per-inspection slot so resuming a specific
      // inspection works even when CURRENT holds a different one (e.g. an
      // offline resume from the reports list). Fall back to CURRENT for data
      // saved before per-id keys existed.
      // Prefer the durable per-inspection slot; fall back to the shared CURRENT
      // slot for data saved before per-id keys existed (or when the id stored at
      // initialize differs from the id the resume passes).
      final perIdStored = widget.inspectionId != null
          ? _inspectionBox
              ?.get(HiveConstants.inspectionKey(widget.inspectionId!))
          : null;
      final currentStored =
          _inspectionBox?.get(HiveConstants.CURRENT_INSPECTION_KEY);

      // A resume must NOT hinge on the stored inspectionId equalling the resume
      // id. The per-id slot is only written once the server id is known, so when
      // a new inspection was started without one surfacing (inspectionId stored
      // as null), no per-id slot exists and CURRENT holds the only copy. The old
      // gate required CURRENT.inspectionId == widget.inspectionId, which a null
      // id never satisfies — so it fell through to the fresh-start branch that
      // DELETES the working copy, wiping every entered value, remark and image.
      //
      // Resume from CURRENT when it plausibly belongs to this inspection — its
      // stored id is null (never stamped) or matches — and carries real data. A
      // genuinely new inspection has CURRENT cleared before launch, so it still
      // takes the fresh path; a different unfinished draft (CURRENT.inspectionId
      // set to another id) is never loaded here.
      bool hasSavedData(InspectionStorageModel? m) =>
          m != null &&
          !m.isCompleted &&
          m.status != 'submitted' &&
          (m.itemValues.isNotEmpty ||
              m.itemImages.isNotEmpty ||
              m.itemRemarks.isNotEmpty ||
              m.itemVideos.isNotEmpty ||
              m.itemAudios.isNotEmpty ||
              m.itemFiles.isNotEmpty ||
              (m.multiImages?.isNotEmpty ?? false) ||
              m.textFieldValues.isNotEmpty);
      final currentBelongsHere = currentStored != null &&
          (currentStored.inspectionId == null ||
              currentStored.inspectionId == widget.inspectionId);
      final resumesLocalCopy = widget.isNewInspection &&
          widget.inspectionId != null &&
          (perIdStored != null ||
              (currentBelongsHere && hasSavedData(currentStored)));

      if (widget.isNewInspection && !resumesLocalCopy) {
        // Fresh start — discard any leftover session from a previous run.
        ref.read(inspectionSessionProvider.notifier).clearSession();
        await _inspectionBox?.delete(HiveConstants.CURRENT_INSPECTION_KEY);
        if (!mounted) return;
        // Load the API template (with sections, fields, and options) for new inspections.
        if (widget.inspectionTemplate != null) {
          _inspectionTemplate = widget.inspectionTemplate;
          _useDynamicTemplate = true;
        }
        _initializeValues();
        _prefillVehicleDetails();
        _initializeControllers();
        // Re-attach any offline-captured media from the durable upload queue.
        // The reports-resume path arrives here (isNew:true) after deleting the
        // CURRENT key, so without this, photos/videos taken offline and not yet
        // uploaded would be missing from the rebuilt form.
        await _rehydratePendingMediaFromQueue();
        // Persist the just-initialized inspection (the API template plus the
        // vehicle details returned by initialize — regno/make/model/etc.)
        // immediately. Previously this lived only in memory until the first
        // field edit, so going offline and resuming showed empty fields.
        await _saveDataLocally();
      } else if (resumesLocalCopy) {
        // Resume the SAME inspection: keep the locally-saved values + images.
        // The server template (from /resume) provides the up-to-date structure;
        // _loadDataFromStorage layers the offline-entered answers + media on top.
        ref.read(inspectionSessionProvider.notifier).clearSession();
        if (widget.inspectionTemplate != null) {
          _inspectionTemplate = widget.inspectionTemplate;
          _useDynamicTemplate = true;
        } else {
          await _loadTemplateFromStorage();
        }
        await _fetchInspectionTemplateIfMissing();
        await _loadDataFromStorage();
        await _rehydratePendingMediaFromQueue();
        if (mounted) {
          _prefillVehicleDetails();
          _initializeControllers();
          await _saveDataLocally();
        }
      } else {
        // Resume path: prefer in-memory snapshot over Hive to avoid I/O.
        final snap = ref.read(inspectionSessionProvider);
        if (snap != null) {
          _restoreFromSnapshot(snap);
        } else {
          // If continuing a previous inspection, load template from storage first
          await _loadTemplateFromStorage();
          _sessionInspectionId ??= _inspectionBox
              ?.get(HiveConstants.CURRENT_INSPECTION_KEY)
              ?.inspectionId;

          // Check if we have a dynamic inspection template from API
          if (widget.inspectionTemplate != null) {
            _inspectionTemplate = widget.inspectionTemplate;
            _useDynamicTemplate = true;
          } else if (_inspectionTemplate == null &&
              vehicleDetails != null &&
              vehicleDetails!.containsKey('inspectionTemplate')) {
            final templateData = vehicleDetails!['inspectionTemplate'];
            if (templateData != null) {
              if (templateData is InspectionInitializationResponse) {
                _inspectionTemplate = templateData;
              } else {
                try {
                  _inspectionTemplate =
                      InspectionInitializationResponse.fromJson(
                    templateData is Map<String, dynamic>
                        ? templateData
                        : templateData as Map<String, dynamic>,
                  );
                } catch (e) {
                  log('Error parsing inspection template: $e');
                }
              }
              _useDynamicTemplate = _inspectionTemplate != null;
            }
          }

          // Hive may lack template JSON (older saves / failed serialization). Refetch.
          final hadTemplate = _inspectionTemplate != null;
          await _fetchInspectionTemplateIfMissing();
          final templateWasRefetched =
              !hadTemplate && _inspectionTemplate != null;

          await _loadDataFromStorage();
          // Only re-save when a new template was fetched so future offline resumes
          // find template + answers together in Hive.
          if (templateWasRefetched && mounted) {
            await _saveDataLocally();
          }
        }

        // Re-apply the vehicle-detail prefill (regno/make/model…) on resume so
        // those fields render even when offline prevented refetching the server
        // template, or the stored record predates the prefill. It only fills
        // empty fields, so already-entered values are never overwritten.
        if (mounted) {
          _prefillVehicleDetails();
          _initializeControllers();
        }

        // Safety net: if the CURRENT key lost media (e.g. a hard kill before it
        // was written, or a stale record), re-attach it from the durable upload
        // queue. Fills only empty fields, so restored media is never doubled.
        if (mounted && await _rehydratePendingMediaFromQueue() && mounted) {
          await _saveDataLocally();
        }
      }

      // Resume only: push any still-local media for this inspection to the
      // server now, instead of waiting for a connectivity flip or the Pending
      // tab. _commitPendingMediaToQueue queues just the un-uploaded local files
      // (already-uploaded http URLs are skipped); the provider then uploads them
      // and replays each field's save-step so the server keeps the media even if
      // the app is stopped again. The queue keeps the local files, so the open
      // form still displays them. Online-gated, fire-and-forget.
      final isFreshStart = widget.isNewInspection && !resumesLocalCopy;
      if (!isFreshStart && _effectiveInspectionId != null) {
        unawaited(Future(() async {
          try {
            if (!await ConnectivityChecker.canReachServer()) return;
            await _commitPendingMediaToQueue();
            if (!mounted) return;
            await ref.read(inspectionProvider.notifier).refreshMediaQueue();
          } catch (e) {
            log('Resume media upload trigger failed: $e');
          }
        }));
      }

      // Request camera + mic permissions while the loading screen is still
      // shown so the camera card renders with permissions already resolved.
      await _requestInspectionPermissions();

      if (mounted) {
        setState(() {
          _isLoadingTemplate = false;
        });
      }
    });
  }

  Future<void> _initHive() async {
    try {
      if (Hive.isBoxOpen(INSPECTION_BOX)) {
        _inspectionBox = Hive.box<InspectionStorageModel>(INSPECTION_BOX);
      } else {
        _inspectionBox =
            await Hive.openBox<InspectionStorageModel>(INSPECTION_BOX);
      }
    } catch (e) {
      log('Error initializing Hive: $e');
      await Hive.deleteBoxFromDisk(INSPECTION_BOX);
      _inspectionBox =
          await Hive.openBox<InspectionStorageModel>(INSPECTION_BOX);
    }
  }

  /// Persists the live inspection to Hive under CURRENT_INSPECTION_KEY.
  ///
  /// [useIsolate] runs the heavy map-copy + template toJson off the main thread
  /// (the default for routine autosaves, to avoid jank). Pass `false` for the
  /// app-lifecycle flush: a force-close gives only a short window, and spawning
  /// an isolate adds round-trip latency that can cost the last save. Building on
  /// the main thread reaches `box.put` sooner so the data is more likely to land.
  Future<void> _saveDataLocally({bool useIsolate = true}) async {
    if (_inspectionBox == null) {
      await _initHive();
    }

    try {
      // Collect controller values on the main thread before spawning isolate.
      final remarksSnapshot = Map<String, String>.fromEntries(
        remarksControllers.entries.map((e) => MapEntry(e.key, e.value.text)),
      );
      final textFieldSnapshot = Map<String, String>.fromEntries(
        textFieldControllers.entries.map((e) => MapEntry(e.key, e.value.text)),
      );
      final multiImagesSnapshot = <String, List<String>>{};
      itemMultiImages.forEach((key, images) {
        if (images != null && images.isNotEmpty) {
          multiImagesSnapshot[key] = images;
        }
      });

      final input = {
        'itemValues': itemValues,
        'itemImages': itemImages,
        'itemVideos': itemVideos,
        'itemAudios': itemAudios,
        'itemFiles': itemFiles,
        'itemRemarks': remarksSnapshot,
        'textFieldValues': textFieldSnapshot,
        'multiImages': multiImagesSnapshot,
        'itemFlaggedIssues': Map<String, List<String>>.from(itemFlaggedIssues),
        'vehicleDetails': vehicleDetails,
        'inspectionTemplate': _inspectionTemplate?.toJson(),
        'currentSection': _currentSection,
        'inspectionId': _effectiveInspectionId,
      };

      // Heavy map-copy + toJson work; off the main thread by default.
      final payload = useIsolate
          ? await compute(_buildStoragePayload, input)
          : _buildStoragePayload(input);

      final storageModel = InspectionStorageModel.fromMap(payload);

      // Active working copy (single slot, used by the home screen to offer
      // "resume" and by the active inspection screen).
      await _inspectionBox?.put(
        HiveConstants.CURRENT_INSPECTION_KEY,
        storageModel,
      );

      // Durable per-inspection copy so this inspection's structure + answers
      // survive offline even after another inspection is started (which only
      // overwrites CURRENT). copyWith() detaches a fresh instance — a single
      // HiveObject cannot live under two keys at once. See [_readStored].
      final id = _effectiveInspectionId;
      if (id != null) {
        await _inspectionBox?.put(
          HiveConstants.inspectionKey(id),
          storageModel.copyWith(),
        );
      }

      log('Data saved locally');
    } catch (e) {
      log('Error saving data: $e');
    }
  }

  Future<void> _completeInspection() async {
    try {
      if (!(_inspectionBox?.isOpen ?? false)) {
        await _initHive();
      }

      final currentData = _readStored();
      if (currentData != null) {
        final completedInspection = InspectionStorageModel(
          itemValues: Map<String, String>.from(currentData.itemValues),
          itemImages: Map<String, String?>.from(currentData.itemImages),
          itemVideos: Map<String, String?>.from(currentData.itemVideos),
          itemAudios: Map<String, String?>.from(currentData.itemAudios),
          itemFiles: Map<String, String?>.from(currentData.itemFiles),
          itemRemarks: Map<String, String>.from(currentData.itemRemarks),
          currentSection: currentData.currentSection,
          textFieldValues:
              Map<String, String>.from(currentData.textFieldValues),
          multiImages: currentData.typedMultiImages,
          isCompleted: true,
          timestamp: DateTime.now(),
          status: 'submitted',
        );

        final historyBox = Hive.isBoxOpen(HiveConstants.INSPECTION_HISTORY_BOX)
            ? Hive.box<InspectionStorageModel>(
                HiveConstants.INSPECTION_HISTORY_BOX)
            : await Hive.openBox<InspectionStorageModel>(
                HiveConstants.INSPECTION_HISTORY_BOX);

        await historyBox.add(completedInspection);
        await _inspectionBox?.delete(HiveConstants.CURRENT_INSPECTION_KEY);
        // Drop the durable per-inspection copy too — it's submitted now.
        final id = _effectiveInspectionId;
        if (id != null) {
          await _inspectionBox?.delete(HiveConstants.inspectionKey(id));
        }
      }
    } catch (e) {
      log('Error completing inspection: $e');
      rethrow;
    }
  }

  /// Builds the items list for a section in save-step format.
  /// Builds the save-step item list for a section.
  ///
  /// When [httpOnly] is true, any media still holding a local (non-http) path is
  /// emitted as null instead of the raw path. The final server submit uses this
  /// so a local path is never POSTed as imagePath — otherwise the server stores
  /// an unresolvable path and the field shows empty on resume, clobbering any
  /// URL an earlier per-field save / upload-queue had already persisted.
  /// Defaults to false so the offline-save and upload-queue descriptors keep the
  /// local paths they still need to upload later.
  List<Map<String, dynamic>> _buildSectionItems(
    Map<String, dynamic> section, {
    bool httpOnly = false,
  }) {
    final items = <Map<String, dynamic>>[];
    for (var item in section['items'] as List<dynamic>) {
      final uniqueId = _getItemUniqueId(item);
      final fieldId = _getItemFieldId(item);
      final title = _getItemTitle(item);

      String value = itemValues[uniqueId] ?? '';
      if (value == 'flagged' && (itemFlaggedIssues[uniqueId] ?? []).isEmpty) {
        value = '';
      } else if (value == 'flagged') {
        final selectedLabel = itemFlaggedIssues[uniqueId]!.first;
        String? optionValue;
        if (item is Map) {
          final opts = item['options'] as List?;
          if (opts != null) {
            for (final opt in opts) {
              final lbl = opt['label']?.toString() ?? '';
              final val = opt['value']?.toString() ?? '';
              final label = lbl.isNotEmpty ? lbl : val;
              if (label == selectedLabel) {
                optionValue = val.isNotEmpty ? val : label;
                break;
              }
            }
          }
        }
        value = optionValue ?? selectedLabel;
      }

      final remarks = itemRemarks[uniqueId];
      final imagePath =
          httpOnly ? _httpOrNull(itemImages[uniqueId]) : itemImages[uniqueId];
      final multiImages = httpOnly
          ? _allHttpOrNull(itemMultiImages[uniqueId])
          : itemMultiImages[uniqueId];
      final videoPath =
          httpOnly ? _httpOrNull(itemVideos[uniqueId]) : itemVideos[uniqueId];
      final audioPath =
          httpOnly ? _httpOrNull(itemAudios[uniqueId]) : itemAudios[uniqueId];
      final filePayload = itemFiles[uniqueId];
      String? filePath;
      if (filePayload != null) {
        try {
          final decoded = json.decode(filePayload) as Map<String, dynamic>;
          filePath = decoded['filePath'] as String?;
        } catch (_) {
          filePath = filePayload;
        }
      }
      if (httpOnly) filePath = _httpOrNull(filePath);

      items.add({
        'id': uniqueId,
        // Server field id, kept alongside the unique key so an offline record
        // can tag its media uploads with the same itemId the online path uses
        // when it is retried later (uniqueId != fieldId for templated items).
        'fieldId': fieldId,
        'title': title,
        'value': value,
        'remarks': (remarks != null && remarks.isNotEmpty) ? remarks : null,
        'imagePath': imagePath,
        'multiImages': multiImages,
        'videoPath': videoPath,
        'audioPath': audioPath,
        'filePath': filePath,
      });
    }
    return items;
  }

  /// Checks whether a section has any filled data worth saving.
  bool _sectionHasData(Map<String, dynamic> section) {
    for (var item in section['items'] as List<dynamic>) {
      final uniqueId = _getItemUniqueId(item);
      final value = (itemValues[uniqueId] ?? '').trim();
      if (value.isNotEmpty && value != 'N/A') return true;
      if ((itemRemarks[uniqueId] ?? '').isNotEmpty) return true;
      if (itemImages[uniqueId] != null) return true;
      if ((itemMultiImages[uniqueId] ?? []).isNotEmpty) return true;
      if (itemVideos[uniqueId] != null) return true;
      if (itemAudios[uniqueId] != null) return true;
      if (itemFiles[uniqueId] != null) return true;
    }
    return false;
  }

  /// The server section slug for a built section map (its `name`, falling back
  /// to a slugified title). This is the value sent as `section` in save-step.
  String _sectionSlug(Map<String, dynamic> section) =>
      (section['name'] as String?) ??
      (section['title'] as String).toLowerCase().replaceAll(' ', '_');

  /// Marks the section that owns [uniqueId] dirty so it is save-stepped (as a
  /// whole section) the next time the user leaves it, or on submit.
  ///
  /// Replaces the old per-field instant POST: instead of one save-step request
  /// per field edit, edits accumulate and the entire section is sent once on
  /// navigation. Kept under the original name so every call site (every value /
  /// option / remark / media change) still simply "saves the field".
  void _saveFieldToServer(dynamic item, String uniqueId) {
    if (_effectiveInspectionId == null) return;
    for (final sec in _sections) {
      for (final si in sec['items'] as List<dynamic>) {
        if (_getItemUniqueId(si) == uniqueId) {
          _dirtySectionNames.add(_sectionSlug(sec));
          return;
        }
      }
    }
  }

  /// Fire-and-forget: save-step every dirty section to the server (online only),
  /// clearing each from the dirty set on success. Called when leaving a section.
  /// Only already-uploaded media (http URLs) is sent; still-local paths are left
  /// for the offline media queue to upload and replay. See [_commitPendingMediaToQueue].
  void _flushDirtySectionsToServer() {
    final inspectionId = _effectiveInspectionId;
    if (inspectionId == null) return;
    if (_dirtySectionNames.isEmpty || _isFlushingSections) return;
    _isFlushingSections = true;

    // Snapshot the dirty slugs and resolve them to sections up front.
    final dirty = Set<String>.from(_dirtySectionNames);
    final pending = <String, List<Map<String, dynamic>>>{};
    for (final section in _sections) {
      final slug = _sectionSlug(section);
      if (!dirty.contains(slug)) continue;
      pending[slug] = _buildSectionItems(section, httpOnly: true);
    }

    unawaited(Future(() async {
      try {
        if (!await ConnectivityChecker.canReachServer()) return;
        for (final entry in pending.entries) {
          if (entry.value.isEmpty) {
            _dirtySectionNames.remove(entry.key);
            continue;
          }
          final r = await ApiService.saveInspectionStep(
            inspectionId,
            section: entry.key,
            items: entry.value,
          );
          if (r['success'] != false) _dirtySectionNames.remove(entry.key);
        }
      } catch (e) {
        log('Section flush save-step error: $e');
      } finally {
        _isFlushingSections = false;
      }
    }));
  }

  /// Awaitable, used by submit: save-step every section that has data so the
  /// server holds the complete inspection before it is finalised with an empty
  /// body. Returns the titles of any sections whose save failed, so the caller
  /// can block submission rather than finalise an incomplete record. Only
  /// http-URL media is sent (caller uploads remaining local media first).
  Future<List<String>> _saveAllSectionsToServer(int inspectionId) async {
    final failed = <String>[];
    for (final section in _sections) {
      if (!_sectionHasData(section)) continue;
      final items = _buildSectionItems(section, httpOnly: true);
      if (items.isEmpty) continue;
      try {
        final r = await ApiService.saveInspectionStep(
          inspectionId,
          section: _sectionSlug(section),
          items: items,
        );
        if (r['success'] == false) {
          failed.add(section['title']?.toString() ?? _sectionSlug(section));
        } else {
          _dirtySectionNames.remove(_sectionSlug(section));
        }
      } catch (e) {
        log('Submit save-step error (${_sectionSlug(section)}): $e');
        failed.add(section['title']?.toString() ?? _sectionSlug(section));
      }
    }
    return failed;
  }

  /// Returns this inspection's server id, initializing a draft on demand when
  /// none exists yet. Normally the id is already set (initialize runs when the
  /// flow starts); this only fires for the rare submit-without-id case. Returns
  /// null when offline or brand/model are unknown, so the caller can fall back
  /// to the offline-save path. Caches the new id in [_sessionInspectionId].
  Future<int?> _ensureServerInspectionId() async {
    final existing = _effectiveInspectionId;
    if (existing != null) return existing;

    final vd = vehicleDetails;
    int? asInt(dynamic v) => v is int ? v : int.tryParse(v?.toString() ?? '');
    String? str(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    final brandId = asInt(vd?['brand_id']);
    final modelId = asInt(vd?['model_id']);
    if (brandId == null || modelId == null) return null;
    if (!await ConnectivityChecker.canReachServer()) return null;

    try {
      final result = await ApiService.initializeInspection(
        vehicleBrandId: brandId,
        vehicleModelId: modelId,
        year: str(vd?['year']),
        variant: str(vd?['variant']),
        colour: str(vd?['color']),
        transmission: str(vd?['transmission']),
        regNo: str(vd?['regno']),
      );
      if (result['success'] == true) {
        final id = asInt(result['inspection_id']);
        if (id != null) {
          _sessionInspectionId = id;
          return id;
        }
      } else {
        log('Ensure server id: initialize failed — ${result['message']}');
      }
    } catch (e) {
      log('Ensure server id: initialize exception — $e');
    }
    return null;
  }

  void _autoSave() {
    if (_saveDebouncer?.isActive ?? false) _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(milliseconds: 500), () async {
      if (mounted) {
        try {
          await _saveDataLocally();
        } catch (e) {
          log('Error in auto save: $e');
        }
      }
    });
  }

  Future<void> _flushPendingAutoSave() async {
    if (_saveDebouncer?.isActive ?? false) {
      _saveDebouncer?.cancel();
    }

    try {
      // Build on the main thread: this runs on app-pause/force-close where the
      // process may die before an isolate round-trip completes.
      await _saveDataLocally(useIsolate: false);
    } catch (e) {
      log('Error flushing auto save: $e');
    }
  }

  // --- Offline media upload queue --------------------------------------------

  /// Returns [v] only when it is an already-uploaded http URL, else null.
  String? _httpOrNull(String? v) =>
      (v != null && v.startsWith('http')) ? v : null;

  /// Returns the list only when EVERY entry is an http URL (fully uploaded);
  /// otherwise null, so a partial multi-image set is never pushed mid-upload.
  List<String>? _allHttpOrNull(List<String>? v) {
    if (v == null || v.isEmpty) return null;
    if (v.any((e) => !e.startsWith('http'))) return null;
    return v;
  }

  bool _isLocalMediaPath(String? v) =>
      v != null && v.isNotEmpty && !v.startsWith('http');

  String? _filePathFromPayload(String? payload) {
    if (payload == null) return null;
    try {
      return (json.decode(payload) as Map<String, dynamic>)['filePath']
          as String?;
    } catch (_) {
      return payload;
    }
  }

  /// Minimal vehicle info for displaying the queued inspection in the reports
  /// "Awaiting Upload" section.
  Map<String, dynamic> _buildQueueVehicleInfo() {
    final v = vehicleDetails ?? const {};
    final make = (v['make'] ?? v['brand'] ?? '').toString();
    final model = (v['model'] ?? '').toString();
    return {
      'registration_number':
          (v['registrationNumber'] ?? v['registration_number'] ?? '')
              .toString(),
      'make_model': [make, model].where((s) => s.isNotEmpty).join(' '),
      'variant': (v['variant'] ?? '').toString(),
      'manufacturing_year':
          (v['year'] ?? v['manufacturing_year'] ?? '').toString(),
    };
  }

  /// Persists every still-local media item (any type) into the offline upload
  /// queue so an upload interrupted by closing the inspection survives an app
  /// restart and auto-syncs when the device is back online. Pure Hive write —
  /// safe to call from dispose() without touching `ref`.
  Future<void> _commitPendingMediaToQueue() async {
    final serverId = _effectiveInspectionId;
    if (serverId == null) return; // need a server id to upload + save-step

    final pendingMedia = <String, PendingMedia>{};
    final saveStepItems = <String, dynamic>{};
    // Media-less fields edited offline (values/options/remarks). Without this,
    // an inspection initialized online then filled offline loses every answer
    // that has no attached media, because nothing queues it for upload.
    final answerStepItems = <String, dynamic>{};

    for (final section in _sections) {
      final sectionTitle = (section['title'] as String?) ?? '';
      final sectionSlug = (section['name'] as String?) ??
          sectionTitle.toLowerCase().replaceAll(' ', '_');

      // Reuse the canonical save-step item builder for snapshots.
      final builtItems = <String, Map<String, dynamic>>{
        for (final it in _buildSectionItems(section)) it['id'].toString(): it,
      };

      for (final item in section['items'] as List<dynamic>) {
        final uniqueId = _getItemUniqueId(item);
        final fieldId = _getItemFieldId(item);
        bool hasPending = false;

        PendingMedia entry(String localPath, String mediaType) => PendingMedia(
              localPath: localPath,
              section: sectionTitle,
              itemId: fieldId,
              mediaType: mediaType,
              fieldKey: uniqueId,
            );

        final img = itemImages[uniqueId];
        if (_isLocalMediaPath(img)) {
          pendingMedia['image_$uniqueId'] = entry(img!, 'image');
          hasPending = true;
        }
        final vid = itemVideos[uniqueId];
        if (_isLocalMediaPath(vid)) {
          pendingMedia['video_$uniqueId'] = entry(vid!, 'video');
          hasPending = true;
        }
        final aud = itemAudios[uniqueId];
        if (_isLocalMediaPath(aud)) {
          pendingMedia['audio_$uniqueId'] = entry(aud!, 'audio');
          hasPending = true;
        }
        final filePath = _filePathFromPayload(itemFiles[uniqueId]);
        if (_isLocalMediaPath(filePath)) {
          pendingMedia['file_$uniqueId'] = entry(filePath!, 'file');
          hasPending = true;
        }
        final multi = itemMultiImages[uniqueId];
        if (multi != null) {
          for (var i = 0; i < multi.length; i++) {
            if (_isLocalMediaPath(multi[i])) {
              pendingMedia['multi_${uniqueId}_$i'] =
                  entry(multi[i], 'multiImage');
              hasPending = true;
            }
          }
        }

        if (hasPending) {
          saveStepItems[uniqueId] = {
            'section': sectionSlug,
            'item': builtItems[uniqueId] ?? {'id': uniqueId},
          };
        } else {
          // No local media on this field — queue its answer/option/remark so an
          // offline-edited value isn't lost. Media-bearing fields already carry
          // their value inside the save-step item replayed after upload.
          final value = (itemValues[uniqueId] ?? '').trim();
          final remark = (itemRemarks[uniqueId] ?? '').trim();
          final hasAnswer =
              (value.isNotEmpty && value != 'N/A') || remark.isNotEmpty;
          if (hasAnswer) {
            answerStepItems[uniqueId] = {
              'section': sectionSlug,
              'item': builtItems[uniqueId] ?? {'id': uniqueId},
            };
          }
        }
      }
    }

    try {
      await LocalStorageService.upsertMediaQueue(
        serverInspectionId: serverId,
        vehicleInfo: _buildQueueVehicleInfo(),
        pendingMedia: pendingMedia,
        saveStepItems: saveStepItems,
        answerStepItems: answerStepItems,
      );
    } catch (e) {
      log('Error committing pending media to queue: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // didChangeAppLifecycleState is void — we can't await here.
      // Hive keeps data in memory, so the write succeeds even if the OS
      // suspends the process before the disk flush completes.
      unawaited(_flushPendingAutoSave());
      // Queue still-local media so a backgrounded/killed app doesn't lose the
      // upload intent; it auto-syncs on the next reconnect.
      if (!_sessionCompleted) unawaited(_commitPendingMediaToQueue());
    }
  }

  /// Requests camera and microphone permissions while the loading screen is
  /// shown so the camera card never races with a permission dialog.
  Future<void> _requestInspectionPermissions() async {
    final camStatus = await Permission.camera.status;
    if (!camStatus.isGranted &&
        !camStatus.isPermanentlyDenied &&
        !camStatus.isRestricted) {
      await Permission.camera.request();
    }
    if (!mounted) return;
    final micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted &&
        !micStatus.isPermanentlyDenied &&
        !micStatus.isRestricted) {
      await Permission.microphone.request();
    }
  }

  IconData _getSectionIcon(String sectionTitle) {
    final title =
        sectionTitle.toLowerCase().replaceAll(' ', '_').replaceAll('-', '_');

    // Handle API section names (like documents, body_panel, dataset1, etc.)
    switch (title) {
      case 'documents':
        return Icons.description;
      case 'body_panel':
        return Icons.directions_car;
      case 'flood_affected':
        return Icons.water_damage;
      case 'dataset1':
      case 'data_set_1':
        return Icons.analytics;
      case 'dataset2':
      case 'data_set_2':
        return Icons.analytics;
      case 'battery':
        return Icons.battery_full;
      case 'coolant':
        return Icons.opacity;
      case 'under_hood':
        return Icons.car_repair;
      case 'brake_fluid':
        return Icons.speed;
      case 'tire':
        return Icons.tire_repair;
      case 'exterior':
        return Icons.directions_car_filled;
      case 'a_c':
        return Icons.ac_unit;
      case 'interior':
        return Icons.airline_seat_recline_normal;
      case 'dicky':
        return Icons.luggage;
      case 'test_drive':
        return Icons.drive_eta;
      case 'after_warmup':
        return Icons.local_fire_department;
      // Fallback to original titles
      case 'body panel':
        return Icons.directions_car;
      case 'flood affected signs':
        return Icons.water_damage;
      case 'data set - i':
      case 'data set - ii':
        return Icons.analytics;
      case 'under hood':
        return Icons.car_repair;
      case 'brake fluid':
        return Icons.speed;
      case 'a/c':
        return Icons.ac_unit;
      case 'test drive':
        return Icons.drive_eta;
      case 'after warmup':
        return Icons.local_fire_department;
      case 'summary / remarks':
        return Icons.summarize;
      default:
        return Icons.checklist;
    }
  }

  String _getPlaceholderText(String itemTitle, String sectionTitle) {
    final title = itemTitle.toLowerCase();

    if (title.contains('registration') ||
        title.contains('number') ||
        title.contains('plate')) {
      return 'e.g. MH12AB1234';
    }
    if (title.contains('chassis') || title.contains('vin')) {
      return 'e.g. MA1234567890123456';
    }
    if (title.contains('engine number')) {
      return 'e.g. G4FC123456';
    }

    return 'Enter details...';
  }

  /// Resolves the stored copy for this inspection, preferring the durable
  /// per-inspection slot (which survives another inspection being started) and
  /// falling back to the single active CURRENT slot for legacy data saved
  /// before per-id keys existed.
  InspectionStorageModel? _readStored() {
    final id = _effectiveInspectionId;
    if (id != null) {
      final perId = _inspectionBox?.get(HiveConstants.inspectionKey(id));
      if (perId != null) return perId;
    }
    return _inspectionBox?.get(HiveConstants.CURRENT_INSPECTION_KEY);
  }

  // Load template and vehicle details from storage before building sections
  Future<void> _loadTemplateFromStorage() async {
    try {
      final storedData = _readStored();

      if (storedData != null) {
        // Load vehicle details if not already set
        if (vehicleDetails == null && storedData.typedVehicleDetails != null) {
          vehicleDetails = storedData.typedVehicleDetails;
        }

        // Load inspection template if not already set
        if (_inspectionTemplate == null &&
            storedData.typedInspectionTemplate != null) {
          try {
            _inspectionTemplate = InspectionInitializationResponse.fromJson(
              storedData.typedInspectionTemplate!,
            );
            _useDynamicTemplate = true;
          } catch (e) {
            log('Error parsing stored inspection template: $e');
          }
        }
      }
    } catch (e) {
      log('Error loading template from storage: $e');
    }
  }

  /// When continuing an inspection, [Hive] may not contain serialized template
  /// (legacy data or first save before template was in memory). Re-initialize
  /// from API using stored [vehicleDetails] brand/model.
  Future<void> _fetchInspectionTemplateIfMissing() async {
    if (_inspectionTemplate != null) {
      _useDynamicTemplate = true;
      return;
    }

    final vd = vehicleDetails;
    if (vd == null) {
      log('Resume: no vehicle details — cannot refetch inspection template');
      return;
    }

    final brandRaw = vd['brand_id'];
    final modelRaw = vd['model_id'];
    final brandId =
        brandRaw is int ? brandRaw : int.tryParse(brandRaw?.toString() ?? '');
    final modelId =
        modelRaw is int ? modelRaw : int.tryParse(modelRaw?.toString() ?? '');

    if (brandId == null || modelId == null) {
      log('Resume: missing brand_id/model_id — cannot refetch template');
      return;
    }

    final cacheKey = '${brandId}_$modelId';
    final cached = _templateCache[cacheKey];
    if (cached != null) {
      _inspectionTemplate = cached;
      _useDynamicTemplate = true;
      return;
    }

    final online = await ConnectivityChecker.canReachServer();
    if (!online) {
      log('Resume: offline — cannot refetch inspection template');
      return;
    }

    // If this inspection already exists on the server, RESUME it (a read-only
    // GET) rather than initialize. Calling initialize here would mint a fresh
    // server-side inspection on every continue, duplicating the record.
    if (_sessionInspectionId != null) {
      try {
        final result = await ApiService.resumeInspection(_sessionInspectionId!);
        if (!mounted) return;

        if (result['success'] == true) {
          final data = result['data'];
          InspectionInitializationResponse? parsed;
          if (data is InspectionInitializationResponse) {
            parsed = data;
          } else if (data is Map<String, dynamic>) {
            try {
              parsed = InspectionInitializationResponse.fromJson(data);
            } catch (e) {
              log('Error parsing resumed inspection template: $e');
            }
          }
          if (parsed != null) {
            _templateCache[cacheKey] = parsed;
            _inspectionTemplate = parsed;
            _useDynamicTemplate = true;
          }
        } else {
          log('resumeInspection on resume failed: ${result['message']}');
        }
      } catch (e, st) {
        log('resumeInspection exception on resume: $e', stackTrace: st);
      }
      // Never fall through to initialize when we have a server id — doing so
      // would create a duplicate inspection.
      return;
    }

    try {
      final result = await ApiService.initializeInspection(
        vehicleBrandId: brandId,
        vehicleModelId: modelId,
      );

      if (!mounted) return;

      if (result['success'] == true) {
        final data = result['data'];
        InspectionInitializationResponse? parsed;
        if (data is InspectionInitializationResponse) {
          parsed = data;
        } else if (data is Map<String, dynamic>) {
          try {
            parsed = InspectionInitializationResponse.fromJson(data);
          } catch (e) {
            log('Error parsing refetched inspection template: $e');
          }
        }

        if (parsed != null) {
          _templateCache[cacheKey] = parsed;
          _inspectionTemplate = parsed;
          _useDynamicTemplate = true;
        }

        final apiId = result['inspection_id'];
        if (_sessionInspectionId == null && apiId != null) {
          _sessionInspectionId =
              apiId is int ? apiId : int.tryParse(apiId.toString());
        }
      } else {
        log('initializeInspection on resume failed: ${result['message']}');
      }
    } catch (e, st) {
      log('initializeInspection exception on resume: $e', stackTrace: st);
    }
  }

  void _restoreFromSnapshot(InspectionSessionSnapshot snap) {
    _inspectionTemplate = snap.inspectionTemplate;
    _useDynamicTemplate = snap.useDynamicTemplate;
    _sessionInspectionId = snap.sessionInspectionId;
    vehicleDetails ??= snap.vehicleDetails;
    setState(() {
      itemValues = Map.from(snap.itemValues);
      itemImages = Map.from(snap.itemImages);
      itemVideos = Map.from(snap.itemVideos);
      itemAudios = Map.from(snap.itemAudios);
      itemFiles = Map.from(snap.itemFiles);
      itemRemarks = Map.from(snap.itemRemarks);
      itemMultiImages = Map.from(snap.itemMultiImages);
      itemFlaggedIssues = Map.from(snap.itemFlaggedIssues);
      _currentSection = snap.currentSection;
      _currentItemIndex = snap.currentItemIndex;
    });
    _initializeControllers();
  }

  Future<void> _loadDataFromStorage() async {
    try {
      final storedData = _readStored();

      if (storedData != null) {
        setState(() {
          itemValues = storedData.typedItemValues;
          itemImages = storedData.typedItemImages;
          itemVideos = storedData.typedItemVideos;
          itemAudios = storedData.typedItemAudios;
          itemFiles = storedData.typedItemFiles;
          itemRemarks = storedData.typedItemRemarks;
          _currentSection = storedData.currentSection;
          itemMultiImages = storedData.typedMultiImages;
          itemFlaggedIssues = storedData.typedItemFlaggedIssues;
          // Restore any server-saved answers / already-uploaded media URLs the
          // local copy is missing, so resuming never drops uploaded data.
          _mergeServerInitialData();
        });
        _initializeControllers();
      } else {
        _initializeValues();
        _initializeControllers();
      }
    } catch (e) {
      log('Error loading data: $e');
      _initializeValues();
      _initializeControllers();
    }
  }

  /// Re-links offline-captured media from the durable upload queue
  /// (mediaq_<serverId>) back into the field maps on resume.
  ///
  /// Why this is needed: media captured while offline is persisted in two
  /// places — the CURRENT_INSPECTION_KEY (used to render the screen) and the
  /// upload queue (used to send it to the server). The reports-resume path
  /// (isNew:true) DELETES the CURRENT key and rebuilds the form purely from the
  /// server template, which carries no `initialImage`/`initialVideo` for media
  /// that was never uploaded. The files and their queue entries still exist on
  /// disk, but the form has no reference to them, so offline photos/videos
  /// vanish from the UI after a restart. This re-attaches them.
  ///
  /// Only fills fields the server (or a prior local restore) left empty, so it
  /// never clobbers server-provided or already-restored media. Entries stay in
  /// the queue, so they still upload on reconnect. Returns true if anything was
  /// restored. setState-only — the caller persists.
  Future<bool> _rehydratePendingMediaFromQueue() async {
    final serverId = _effectiveInspectionId;
    if (serverId == null) return false;
    try {
      final container = await LocalStorageService.getMediaQueueById(
        LocalStorageService.mediaQueueId(serverId),
      );
      final pending = container?.pendingMedia;
      if (pending == null || pending.isEmpty) return false;

      final multiByField = <String, List<String>>{};
      var changed = false;

      for (final entry in pending.values) {
        final fieldKey = entry.fieldKey;
        if (fieldKey.isEmpty) continue;
        // Prefer the uploaded URL when one exists, else the local file path.
        final path =
            (entry.isUploaded && (entry.uploadedUrl?.isNotEmpty ?? false))
                ? entry.uploadedUrl!
                : entry.localPath;

        switch (entry.mediaType) {
          case 'image':
            if ((itemImages[fieldKey] ?? '').isEmpty) {
              itemImages[fieldKey] = path;
              changed = true;
            }
            break;
          case 'video':
            if ((itemVideos[fieldKey] ?? '').isEmpty) {
              itemVideos[fieldKey] = path;
              changed = true;
            }
            break;
          case 'audio':
            if ((itemAudios[fieldKey] ?? '').isEmpty) {
              itemAudios[fieldKey] = path;
              changed = true;
            }
            break;
          case 'file':
            if ((itemFiles[fieldKey] ?? '').isEmpty) {
              itemFiles[fieldKey] = path;
              changed = true;
            }
            break;
          case 'multiImage':
            (multiByField[fieldKey] ??= <String>[]).add(path);
            break;
        }
      }

      // Multi-images only restore into a field the server/local restore left
      // empty, so a partially-synced set isn't duplicated.
      multiByField.forEach((fieldKey, paths) {
        final existing = itemMultiImages[fieldKey];
        if ((existing == null || existing.isEmpty) && paths.isNotEmpty) {
          itemMultiImages[fieldKey] = paths;
          changed = true;
        }
      });

      if (changed && mounted) setState(() {});
      return changed;
    } catch (e) {
      log('Error rehydrating pending media from queue: $e');
      return false;
    }
  }

  Future<void> _cleanupCurrentInspection() async {
    try {
      _sessionCompleted = true;
      ref.read(inspectionSessionProvider.notifier).clearSession();

      if (_inspectionBox?.isOpen ?? false) {
        await _inspectionBox?.delete(HiveConstants.CURRENT_INSPECTION_KEY);
        // Drop the durable per-inspection copy too — inspection is finished.
        final id = _effectiveInspectionId;
        if (id != null) {
          await _inspectionBox?.delete(HiveConstants.inspectionKey(id));
        }
      }

      if (mounted) {
        setState(() {
          itemValues.clear();
          itemImages.clear();
          itemVideos.clear();
          itemAudios.clear();
          itemFiles.clear();
          itemRemarks.clear();
        });
      }
    } catch (e) {
      log('Error cleaning up current inspection: $e');
    }
  }

  void _initializeControllers() {
    _cleanupControllers();
    remarksControllers.clear();
    textFieldControllers.clear();
    numberRemarkControllers.clear();

    for (var section in _sections) {
      final items = section['items'] as List<dynamic>;
      for (var item in items) {
        final uniqueId = _getItemUniqueId(item);

        if (_itemHasRemarks(item)) {
          remarksControllers[uniqueId] = TextEditingController(
            text: itemRemarks[uniqueId] ?? '',
          );
          remarksControllers[uniqueId]?.addListener(() {
            itemRemarks[uniqueId] = remarksControllers[uniqueId]?.text ?? '';
          });
        }

        if (_itemUsesTextField(item)) {
          textFieldControllers[uniqueId] = TextEditingController(
            text: itemValues[uniqueId] ?? '',
          );
          textFieldControllers[uniqueId]?.addListener(() {
            itemValues[uniqueId] = textFieldControllers[uniqueId]?.text ?? '';
          });
        }
      }
    }
  }

  void _initializeValues() {
    itemValues = {};
    itemRemarks = {};
    itemMultiImages = {};
    itemVideos = {};
    itemAudios = {};
    itemFiles = {};

    for (var section in _sections) {
      final items = section['items'] as List<dynamic>;
      for (var item in items) {
        final uniqueId = _getItemUniqueId(item);

        // Default values — will be overwritten by initial_* if present.
        if (_itemUsesTextField(item)) {
          itemValues[uniqueId] = '';
        } else if (_itemHasOptions(item)) {
          itemValues[uniqueId] = 'N/A';
        }

        if (_itemHasRemarks(item)) {
          itemRemarks[uniqueId] = '';
        }

        // Prefill from server-provided initial_* values (resume / initialize).
        if (item is Map) {
          final iv = item['initialValue'];
          if (iv != null && iv.toString().isNotEmpty) {
            itemValues[uniqueId] = iv.toString();
          }
          final ir = item['initialRemarks'];
          if (ir != null && ir.toString().isNotEmpty) {
            itemRemarks[uniqueId] = ir.toString();
          }
          final img = item['initialImage'];
          if (img != null && img.toString().isNotEmpty) {
            itemImages[uniqueId] = img.toString();
          }
          final multi = item['initialMultiImages'];
          if (multi is List && multi.isNotEmpty) {
            itemMultiImages[uniqueId] = multi.map((e) => e.toString()).toList();
          }
          final vid = item['initialVideo'];
          if (vid != null && vid.toString().isNotEmpty) {
            itemVideos[uniqueId] = vid.toString();
          }
          final aud = item['initialAudio'];
          if (aud != null && aud.toString().isNotEmpty) {
            itemAudios[uniqueId] = aud.toString();
          }
          final fil = item['initialFile'];
          if (fil != null && fil.toString().isNotEmpty) {
            itemFiles[uniqueId] = fil.toString();
          }
        }
      }
    }
  }

  /// Overlays the server's `initial_*` data (previously-saved answers and
  /// already-uploaded media URLs returned by /resume) onto the loaded local
  /// maps, filling ONLY the fields the local working copy is missing.
  ///
  /// On resume the local Hive copy is the primary source, but it can lag the
  /// server: media uploaded via the offline queue (or a save-step replayed on
  /// another device) lives on the server yet may be absent from the working
  /// copy that was last written. Without this merge that already-uploaded data
  /// silently disappears from the inspection on resume. Local edits are never
  /// overwritten — only empty/untouched fields are filled.
  void _mergeServerInitialData() {
    bool isBlank(String? v) => v == null || v.isEmpty;
    // 'N/A' is the untouched default for option fields — treat it as empty so a
    // previously-saved answer is restored.
    void fillValue(String uniqueId, String? v) {
      if (v == null || v.isEmpty) return;
      final cur = itemValues[uniqueId];
      if (cur == null || cur.isEmpty || cur == 'N/A') itemValues[uniqueId] = v;
    }

    final saved = _inspectionTemplate?.savedFields ?? const {};
    for (final section in _sections) {
      for (final item in section['items'] as List<dynamic>) {
        if (item is! Map) continue;
        final uniqueId = _getItemUniqueId(item);

        // Source 1: per-field initial_* on the template structure.
        fillValue(uniqueId, item['initialValue']?.toString());
        final ir = item['initialRemarks'];
        if (ir != null &&
            ir.toString().isNotEmpty &&
            isBlank(itemRemarks[uniqueId])) {
          itemRemarks[uniqueId] = ir.toString();
        }
        final img = item['initialImage'];
        if (img != null &&
            img.toString().isNotEmpty &&
            isBlank(itemImages[uniqueId])) {
          itemImages[uniqueId] = img.toString();
        }
        final multi = item['initialMultiImages'];
        if (multi is List &&
            multi.isNotEmpty &&
            (itemMultiImages[uniqueId]?.isEmpty ?? true)) {
          itemMultiImages[uniqueId] = multi.map((e) => e.toString()).toList();
        }
        final vid = item['initialVideo'];
        if (vid != null &&
            vid.toString().isNotEmpty &&
            isBlank(itemVideos[uniqueId])) {
          itemVideos[uniqueId] = vid.toString();
        }
        final aud = item['initialAudio'];
        if (aud != null &&
            aud.toString().isNotEmpty &&
            isBlank(itemAudios[uniqueId])) {
          itemAudios[uniqueId] = aud.toString();
        }
        final fil = item['initialFile'];
        if (fil != null &&
            fil.toString().isNotEmpty &&
            isBlank(itemFiles[uniqueId])) {
          itemFiles[uniqueId] = fil.toString();
        }

        // Source 2: the server's saved_sections payload, keyed by item id (the
        // value we send in save-step) with a fieldId fallback. Same
        // fill-only-when-empty rule, so it never overwrites the above or a
        // local edit — it only recovers data the template's initial_* omitted.
        final sv = saved[uniqueId] ?? saved[_getItemFieldId(item)];
        if (sv == null) continue;
        fillValue(uniqueId, sv['value'] as String?);
        final sr = sv['remarks'] as String?;
        if (sr != null && sr.isNotEmpty && isBlank(itemRemarks[uniqueId])) {
          itemRemarks[uniqueId] = sr;
        }
        final sImg = sv['image'] as String?;
        if (sImg != null && sImg.isNotEmpty && isBlank(itemImages[uniqueId])) {
          itemImages[uniqueId] = sImg;
        }
        final sMulti = sv['multiImages'];
        if (sMulti is List &&
            sMulti.isNotEmpty &&
            (itemMultiImages[uniqueId]?.isEmpty ?? true)) {
          itemMultiImages[uniqueId] = sMulti.map((e) => e.toString()).toList();
        }
        final sVid = sv['video'] as String?;
        if (sVid != null && sVid.isNotEmpty && isBlank(itemVideos[uniqueId])) {
          itemVideos[uniqueId] = sVid;
        }
        final sAud = sv['audio'] as String?;
        if (sAud != null && sAud.isNotEmpty && isBlank(itemAudios[uniqueId])) {
          itemAudios[uniqueId] = sAud;
        }
        final sFil = sv['file'] as String?;
        if (sFil != null && sFil.isNotEmpty && isBlank(itemFiles[uniqueId])) {
          itemFiles[uniqueId] = sFil;
        }
      }
    }
  }

  void _prefillVehicleDetails() {
    final vd = vehicleDetails;
    if (vd == null) return;

    // Build keyword → value lookup from vehicle details
    final lookup = <String, String>{};

    void add(List<String> keywords, String? value) {
      if (value == null || value.isEmpty) return;
      for (final k in keywords) {
        lookup[k] = value;
      }
    }

    add(['regno', 'registration', 'reg_no', 'regnumber'],
        vd['regno']?.toString());
    add(['make', 'brand'], vd['make']?.toString());
    add(['model'], vd['model']?.toString());
    add(['year'], vd['year']?.toString());
    add(['variant'], vd['variant']?.toString());
    add(['colour', 'color'], vd['color']?.toString());
    add(['transmission'], vd['transmission']?.toString());

    for (final section in _sections) {
      for (final item in section['items'] as List<dynamic>) {
        if (!_itemUsesTextField(item)) continue;

        final uniqueId = _getItemUniqueId(item);

        // Don't overwrite a value already set (e.g. resumed inspection)
        if ((itemValues[uniqueId] ?? '').isNotEmpty) continue;

        final fieldId = _getItemFieldId(item).toLowerCase();
        final title = _getItemTitle(item).toLowerCase();

        for (final entry in lookup.entries) {
          if (fieldId.contains(entry.key) || title.contains(entry.key)) {
            itemValues[uniqueId] = entry.value;
            break;
          }
        }
      }
    }
  }

  // Helper methods for handling both dynamic and regular items
  String _getItemUniqueId(dynamic item) {
    if (item is InspectionItem) {
      return item.uniqueId;
    } else if (item is Map) {
      return item['fieldId'] ?? item['id'] ?? '';
    }
    return '';
  }

  String _getItemTitle(dynamic item) {
    if (item is InspectionItem) {
      return item.title;
    } else if (item is Map) {
      return item['title'] ?? '';
    }
    return '';
  }

  bool _itemHasImage(dynamic item) {
    if (item is InspectionItem) {
      return item.allowImage;
    } else if (item is Map) {
      return item['hasImage'] ?? false;
    }
    return false;
  }

  bool _itemHasMultiImage(dynamic item) {
    if (item is InspectionItem) {
      return item.allowMultiImage;
    } else if (item is Map) {
      return item['allowMultiImage'] ?? false;
    }
    return false;
  }

  bool _itemUsesTextField(dynamic item) {
    if (item is InspectionItem) {
      return item.useTextField;
    } else if (item is Map) {
      return item['useTextField'] ?? false;
    }
    return false;
  }

  bool _itemHasRemarks(dynamic item) {
    if (item is InspectionItem) {
      return item.allowRemarks;
    } else if (item is Map) {
      return item['hasRemarks'] ?? false;
    }
    return false;
  }

  bool _itemIsRequired(dynamic item) {
    if (item is InspectionItem) {
      // InspectionItem doesn't have isRequired, default to false
      return false;
    } else if (item is Map) {
      return item['isRequired'] ?? false;
    }
    return false;
  }

  bool _itemHasVideo(dynamic item) {
    if (item is InspectionItem) {
      // InspectionItem doesn't have allowVideo, default to false
      return false;
    } else if (item is Map) {
      return item['hasVideo'] ?? false;
    }
    return false;
  }

  bool _itemHasFile(dynamic item) {
    if (item is InspectionItem) {
      // InspectionItem doesn't have allowFile, default to false
      return false;
    } else if (item is Map) {
      return item['hasFile'] ?? false;
    }
    return false;
  }

  String _defaultCaptureModeForItem(dynamic item) {
    final refMedia = _getItemReferenceMedia(item);
    if (refMedia.isNotEmpty) {
      final refType =
          (refMedia.first['mediaType'] as String? ?? '').toLowerCase();
      if (refType == 'image') return 'PHOTO';
      if (refType == 'video') return 'VIDEO';
    }
    if (_itemHasImage(item)) return 'PHOTO';
    if (_itemHasVideo(item)) return 'VIDEO';
    if (_itemHasFile(item)) return 'FILE';
    return 'PHOTO';
  }

  List<Map<String, dynamic>> _getItemReferenceMedia(dynamic item) {
    if (item is Map) {
      final media = item['referenceMedia'];
      if (media is List && media.isNotEmpty) {
        return media.cast<Map<String, dynamic>>();
      }
    }
    return [];
  }

  bool _itemHasOptions(dynamic item) {
    if (item is InspectionItem) {
      return item.options != null && item.options!.isNotEmpty;
    } else if (item is Map) {
      return item['options'] != null && (item['options'] as List).isNotEmpty;
    }
    return false;
  }

  String _getItemFieldId(dynamic item) {
    if (item is InspectionItem) {
      return item.id;
    } else if (item is Map) {
      return item['fieldId'] ?? item['id'] ?? '';
    }
    return '';
  }

  bool _isRegNoField(dynamic item) {
    final field = _getItemFieldId(item).toLowerCase();
    final uid = _getItemUniqueId(item).toLowerCase();
    return field == 'regno' || uid == 'regno';
  }

  bool _regNoResponseHasUsableData(dynamic data) {
    if (data is Map && data.isEmpty) return false;
    if (data is List && data.isEmpty) return false;
    return true;
  }

  Future<void> _verifyRegNo(String uniqueId) async {
    final raw = textFieldControllers[uniqueId]?.text.trim() ?? '';
    if (raw.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a registration number to verify'),
        ),
      );
      return;
    }

    setState(() => _verifyingRegNoUniqueId = uniqueId);

    final result = await ApiService.getVehicleDetails(vehicleNumber: raw);

    if (!mounted) return;

    final success = result['success'] == true;
    final data = result['data'];
    final message = (result['message'] ?? '').toString();

    setState(() {
      _verifyingRegNoUniqueId = null;
      if (success && data != null && _regNoResponseHasUsableData(data)) {
        final String display;
        if (data is Map || data is List) {
          display = const JsonEncoder.withIndent('  ').convert(data);
        } else {
          display = data.toString();
        }
        _regNoVerifyMessage[uniqueId] = display;
        _regNoVerifyIsError[uniqueId] = false;
      } else {
        _regNoVerifyMessage[uniqueId] = message.isNotEmpty
            ? message
            : 'Could not verify registration number';
        _regNoVerifyIsError[uniqueId] = true;
      }
    });
  }

  Widget _buildRegNoVerifyResultCard(String uniqueId) {
    final text = _regNoVerifyMessage[uniqueId];
    if (text == null || text.isEmpty) return const SizedBox.shrink();

    final isError = _regNoVerifyIsError[uniqueId] ?? false;
    final theme = Theme.of(context);
    final Color accent =
        isError ? theme.colorScheme.error : const Color(0xFF2E7D32);
    final Color bg = isError
        ? theme.colorScheme.errorContainer.withValues(alpha: 0.45)
        : theme.brightness == Brightness.dark
            ? accent.withValues(alpha: 0.14)
            : accent.withValues(alpha: 0.08);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: accent.withValues(alpha: 0.45),
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isError ? Icons.error_outline : Icons.verified_outlined,
                      size: 20,
                      color: accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isError
                            ? 'Verification failed'
                            : 'Verified — RC details',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.textTheme.bodyLarge?.color,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 20,
                        color: theme.iconTheme.color?.withValues(alpha: 0.65),
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      onPressed: () {
                        setState(() {
                          _regNoVerifyMessage.remove(uniqueId);
                          _regNoVerifyIsError.remove(uniqueId);
                        });
                      },
                      tooltip: 'Dismiss',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Scrollbar(
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        text,
                        style: theme.textTheme.bodySmall?.copyWith(
                          height: 1.4,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isImageFieldType(dynamic item) {
    if (item is Map) {
      return (item['fieldType'] as String?)?.toLowerCase() == 'image';
    }
    return false;
  }

  String _getItemFieldType(dynamic item) {
    if (item is Map) {
      return (item['fieldType'] as String?)?.toLowerCase() ?? 'text';
    }
    return 'text';
  }

  static IconData _fieldTypeIcon(dynamic item) {
    final type = item is Map
        ? (item['fieldType'] as String?)?.toLowerCase() ?? 'text'
        : 'text';
    switch (type) {
      case 'image':
        return Icons.image_outlined;
      case 'video':
        return Icons.videocam_outlined;
      case 'dropdown':
        return Icons.arrow_drop_down_circle_outlined;
      case 'file':
        return Icons.attach_file_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      default:
        return Icons.text_fields_outlined;
    }
  }

  static Color _fieldTypeColor(dynamic item) {
    final type = item is Map
        ? (item['fieldType'] as String?)?.toLowerCase() ?? 'text'
        : 'text';
    switch (type) {
      case 'image':
        return const Color(0xFF4D9EFF);
      case 'video':
        return const Color(0xFFA855F7);
      case 'dropdown':
        return const Color(0xFFF97316);
      case 'file':
        return const Color(0xFF22C55E);
      case 'audio':
        return const Color(0xFFEC4899);
      default:
        return Colors.grey;
    }
  }

  Widget _buildInspectionSection(String title, List<dynamic> items) {
    if (_currentItemIndex >= items.length) {
      _currentItemIndex = 0;
    }
    if (_currentItemIndex < 0) {
      _currentItemIndex = 0;
    }

    final item = items[_currentItemIndex];

    return _buildSingleItemContainer(item, title);
  }

  // Pure check (no side effects) for whether a required item still has an
  // unfilled value or missing required media. Used to drive the inline
  // missing-field highlight so it clears the moment the field is completed.
  bool _itemHasMissingRequired(dynamic item) {
    if (!_itemIsRequired(item)) return false;
    final uniqueId = _getItemUniqueId(item);

    if (_itemUsesTextField(item)) {
      if ((itemValues[uniqueId]?.trim() ?? '').isEmpty) return true;
    } else if (_itemHasOptions(item)) {
      final value = itemValues[uniqueId] ?? 'N/A';
      if (value == 'N/A' || value.isEmpty) return true;
    }

    if (_itemHasImage(item) &&
        (itemImages[uniqueId] == null || itemImages[uniqueId]!.isEmpty)) {
      return true;
    }
    if (_itemHasVideo(item) &&
        (itemVideos[uniqueId] == null || itemVideos[uniqueId]!.isEmpty)) {
      return true;
    }
    if (_itemHasFile(item) &&
        (itemFiles[uniqueId] == null || itemFiles[uniqueId]!.isEmpty)) {
      return true;
    }
    return false;
  }

  Widget _buildSingleItemContainer(dynamic item, String sectionTitle) {
    final uniqueId = _getItemUniqueId(item);
    final title = _getItemTitle(item);
    final allowImage = _itemHasImage(item);
    final isRequired = _itemIsRequired(item);
    final isMissingHighlight = _highlightMissingFieldId.value == uniqueId &&
        _itemHasMissingRequired(item);
    final referenceMedia = _getItemReferenceMedia(item);
    final flaggedIssues = itemFlaggedIssues[uniqueId] ?? [];
    final hasFlaggableOptions =
        _itemHasOptions(item) && !_itemHasImage(item) && !_itemHasVideo(item);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: isMissingHighlight
                ? const Color(0xFFDC2626).withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.07),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: isMissingHighlight
              ? const Color(0xFFDC2626)
              : isRequired
                  ? Colors.orange.withValues(alpha: 0.5)
                  : const Color(0xFFE4E7EB),
          width: isMissingHighlight || isRequired ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isMissingHighlight)
            Container(
              width: double.infinity,
              color: const Color(0xFFFEE2E2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: const Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: Color(0xFFDC2626)),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Required — please complete this field',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // ── Header + reference media (padded) ──────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _fieldTypeColor(item).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        _fieldTypeIcon(item),
                        color: _fieldTypeColor(item),
                        size: 15,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                              ),
                              if (isRequired)
                                const Text(
                                  ' *',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.red,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _getItemFieldType(item),
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (allowImage && !_isImageFieldType(item))
                          IconButton(
                            icon: const Icon(Icons.camera_alt, size: 22),
                            color: const Color(0xFF4D9EFF),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            onPressed: () => _showImagePickerOptions(item),
                          ),
                        if (_itemHasVideo(item))
                          IconButton(
                            icon: const Icon(Icons.videocam, size: 22),
                            color: const Color(0xFFA855F7),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            onPressed: () => _showVideoPickerOptions(item),
                          ),
                        if (_itemHasFile(item))
                          IconButton(
                            icon: const Icon(Icons.attach_file, size: 22),
                            color: const Color(0xFF22C55E),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            onPressed: () => _showFilePickerOptions(item),
                          ),
                        if ((item is Map
                                    ? (item['fieldType'] as String?)
                                    : null)
                                ?.toLowerCase() ==
                            'audio')
                          IconButton(
                            icon: const Icon(Icons.audio_file, size: 22),
                            color: const Color(0xFFF97316),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            onPressed: () => _showAudioPickerOptions(item),
                          ),
                        if (hasFlaggableOptions)
                          IconButton(
                            icon: Icon(
                              flaggedIssues.isNotEmpty
                                  ? Icons.flag
                                  : Icons.flag_outlined,
                              size: 22,
                            ),
                            color: flaggedIssues.isNotEmpty
                                ? Colors.orange
                                : Colors.grey[500],
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            onPressed: () => _showFlagIssuesSheet(item,
                                autoAdvanceOnConfirm: true),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (referenceMedia.isNotEmpty) ...[
                  ReferenceMediaSectionView(
                    mediaList: referenceMedia,
                    imageHeight: 280,
                    maxItems: 1,
                    trailing: InspectionInfoButton(
                      fieldId: uniqueId,
                      referenceMedia: referenceMedia,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),

          // ── Full-width camera card ──────────────────────────────
          if (_itemHasImage(item) && itemImages[uniqueId] == null) ...[
            SectionCameraCard(
              key: ValueKey('camera_$uniqueId'),
              height: 220,
              borderRadius: BorderRadius.zero,
              instructionText: 'Take a clear photo of: $title',
              onPickFromGallery: () => _pickImage(
                ImageSource.gallery,
                uniqueId,
                _getItemFieldId(item),
                item: item,
              ),
              onCapture: (XFile file) async {
                final fieldId = _getItemFieldId(item);
                final String sectionTitle =
                    _sections[_currentSection]['title'] as String;
                final savedPath =
                    await LocalStorageService.saveImage(file.path);
                setState(() {
                  itemImages[uniqueId] = savedPath;
                  _markUploading(uniqueId);
                });
                if (mounted)
                  _showFlagIssuesSheet(item, autoAdvanceOnConfirm: true);
                await _saveDataLocally();
                final bool hasInternet =
                    await ConnectivityChecker.canReachServer();
                if (hasInternet) {
                  final result = await ApiService.uploadImage(
                    savedPath,
                    inspectionId: _effectiveInspectionId,
                    section: sectionTitle,
                    itemId: fieldId,
                    onProgress: (sent, total) =>
                        _onUploadProgress(uniqueId, sent, total),
                  );
                  if (mounted) {
                    _unmarkUploading(uniqueId);
                    final url = result['url']?.toString();
                    if (result['success'] == true &&
                        url != null &&
                        url.isNotEmpty) {
                      setState(() => itemImages[uniqueId] = url);
                      await _saveDataLocally();
                      try {
                        await File(savedPath).delete();
                      } catch (_) {}
                      _saveFieldToServer(item, uniqueId);
                    } else {
                      _showUploadFailedSnack(result);
                    }
                  }
                } else {
                  if (mounted) {
                    _unmarkUploading(uniqueId);
                  }
                }
              },
            ),
            const SizedBox(height: 8),
          ],

          // ── Full-width video card ───────────────────────────────
          if (_itemHasVideo(item) && itemVideos[uniqueId] == null) ...[
            SectionVideoCameraCard(
              key: ValueKey('video_$uniqueId'),
              height: 220,
              borderRadius: BorderRadius.zero,
              instructionText: 'Record a video of: $title',
              onPickFromGallery: () => _pickVideo(item, ImageSource.gallery),
              onCapture: (XFile file) {
                setState(() {
                  _pendingCapturedVideoFile = file;
                  _pendingCapturedVideoUniqueId = uniqueId;
                  _isReviewingVideo = true;
                });
              },
            ),
            const SizedBox(height: 8),
          ],

          // ── Captured image preview + rest (padded) ─────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (allowImage && itemImages[uniqueId] != null) ...[
                  Row(
                    children: [
                      Text(
                        'Captured Image:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).textTheme.bodyMedium?.color,
                        ),
                      ),
                      ValueListenableBuilder<Set<String>>(
                        valueListenable: _uploadingImages,
                        builder: (context, uploading, _) {
                          if (!uploading.contains(uniqueId)) {
                            return const SizedBox.shrink();
                          }
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: 8),
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 4),
                              ValueListenableBuilder<
                                  Map<String, MediaFileProgress>>(
                                valueListenable: _uploadProgress,
                                builder: (context, progress, _) => Text(
                                  uploadBadgeLabel(progress[uniqueId]),
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.orange),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: () => _showImagePreview(itemImages[uniqueId]!),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: 120,
                          maxHeight: 400,
                        ),
                        child: Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Colors.grey.shade300, width: 1),
                          ),
                          child: _buildImageWidget(
                            itemImages[uniqueId]!,
                            cacheWidth: (MediaQuery.of(context).size.width *
                                    MediaQuery.of(context).devicePixelRatio)
                                .round(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (itemVideos[uniqueId] != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Video selected: ${itemVideos[uniqueId]!.split('/').last}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (itemAudios[uniqueId] != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Audio selected: ${itemAudios[uniqueId]!.split('/').last}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (itemFiles[uniqueId] != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'File attached: ${_extractFileName(itemFiles[uniqueId]!)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                _buildItemControls(item, sectionTitle),
                if (hasFlaggableOptions && flaggedIssues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: flaggedIssues.map((issue) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: Colors.orange.withValues(alpha: 0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.flag,
                                size: 11, color: Colors.orange),
                            const SizedBox(width: 4),
                            Text(
                              issue,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.orange,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemControls(dynamic item, String sectionTitle) {
    final uniqueId = _getItemUniqueId(item);
    final useTextField = _itemUsesTextField(item);
    final title = _getItemTitle(item);

    final inputDecoration = InputDecoration(
      filled: true,
      fillColor: Theme.of(context).brightness == Brightness.dark
          ? Colors.grey[850]
          : Colors.grey[50],
      hintText: _getPlaceholderText(title, sectionTitle),
      hintStyle: TextStyle(
        color: Theme.of(context).hintColor.withAlpha(153),
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Theme.of(context).dividerColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            BorderSide(color: Theme.of(context).dividerColor.withAlpha(128)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Theme.of(context).primaryColor, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (useTextField && _isRegNoField(item))
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: textFieldControllers[uniqueId],
                  textCapitalization: TextCapitalization.characters,
                  decoration: inputDecoration,
                  keyboardType: TextInputType.text,
                  maxLines: 1,
                  onChanged: (value) {
                    setState(() {
                      itemValues[uniqueId] = value;
                      _regNoVerifyMessage.remove(uniqueId);
                      _regNoVerifyIsError.remove(uniqueId);
                    });
                    _autoSave();
                    _saveFieldToServer(item, uniqueId);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _verifyingRegNoUniqueId == uniqueId
                    ? SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).primaryColor,
                            ),
                          ),
                        ),
                      )
                    : OutlinedButton(
                        onPressed: () => _verifyRegNo(uniqueId),
                        child: const Text('Verify'),
                      ),
              ),
            ],
          ),
        if (useTextField && _isRegNoField(item))
          _buildRegNoVerifyResultCard(uniqueId),
        if (useTextField && !_isRegNoField(item))
          TextField(
            controller: textFieldControllers[uniqueId],
            decoration: inputDecoration,
            keyboardType: TextInputType.multiline,
            minLines: _itemHasMultiImage(item) ? 4 : 1,
            maxLines: _itemHasMultiImage(item) ? null : 1,
            onChanged: (value) {
              // No setState: the controller already drives the field's own
              // text, and nothing visible depends on itemValues live (the nav
              // bar is index-based; completion indicators live in the drawer,
              // which is closed while typing). Avoids rebuilding the whole
              // screen on every keystroke. Mirrors the Remarks field below.
              itemValues[uniqueId] = value;
              _autoSave();
              _saveFieldToServer(item, uniqueId);
            },
          ),
        if (_itemHasMultiImage(item)) ...[
          const SizedBox(height: 10),
          _buildInlineMultiImageGallery(item, uniqueId),
        ],
        if (!useTextField && _itemHasOptions(item))
          DropdownButtonFormField<String>(
            initialValue:
                itemValues[uniqueId] == 'N/A' ? null : itemValues[uniqueId],
            decoration: InputDecoration(
              filled: true,
              fillColor: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey[850]
                  : Colors.grey[50],
              hintText: 'Select an option',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Theme.of(context).dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: Theme.of(context).dividerColor.withAlpha(128)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: Theme.of(context).primaryColor, width: 2),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            items: ((item['options'] as List?) ?? []).map((opt) {
              final colorCodeStr = (opt['colorCode'] ?? '').toString();
              Color? optionColor;
              if (colorCodeStr.startsWith('#') && colorCodeStr.length >= 7) {
                final hex = colorCodeStr.replaceFirst('#', '');
                optionColor = Color(int.parse('FF$hex', radix: 16));
              }
              return DropdownMenuItem<String>(
                value: (opt['value'] ?? '').toString(),
                child: Row(
                  children: [
                    if (optionColor != null) ...[
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: optionColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text((opt['label'] ?? opt['value'] ?? '').toString()),
                  ],
                ),
              );
            }).toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                itemValues[uniqueId] = value;
              });
              _autoSave();
              _saveFieldToServer(item, uniqueId);
            },
          ),
        if (_itemHasRemarks(item) && remarksControllers[uniqueId] != null) ...[
          const SizedBox(height: 12),
          Text(
            'Remarks',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: remarksControllers[uniqueId],
            decoration: inputDecoration.copyWith(
              hintText: 'Add remarks...',
            ),
            keyboardType: TextInputType.multiline,
            minLines: 2,
            maxLines: null,
            onChanged: (value) {
              itemRemarks[uniqueId] = value;
              _autoSave();
              _saveFieldToServer(item, uniqueId);
            },
          ),
        ],
      ],
    );
  }

  void _showImagePickerOptions(dynamic item) {
    final uniqueId = _getItemUniqueId(item);
    final fieldId = _getItemFieldId(item);

    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Colors.blue),
                title: const Text('Take Photo'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera, uniqueId, fieldId, item: item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.blue),
                title: const Text('Choose from Gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery, uniqueId, fieldId,
                      item: item);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInlineMultiImageGallery(dynamic item, String uniqueId) {
    final images = itemMultiImages[uniqueId] ?? [];
    const maxImages = 11;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Photos (${images.length}/$maxImages)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
            const Spacer(),
            if (images.length < maxImages)
              GestureDetector(
                onTap: () => _pickMultiImagesForItem(item),
                child: Row(
                  children: [
                    Icon(Icons.add_photo_alternate,
                        size: 18, color: Theme.of(context).primaryColor),
                    const SizedBox(width: 4),
                    Text(
                      'Add Photos',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (images.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: images.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final imagePath = images[index];
                final isUploading =
                    _uploadingMultiImagePaths.contains(imagePath);
                return Stack(
                  children: [
                    GestureDetector(
                      onTap: isUploading
                          ? null
                          : () => _showImagePreview(imagePath),
                      child: Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _buildImageWidget(imagePath, cacheWidth: 150),
                        ),
                      ),
                    ),
                    if (isUploading)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!isUploading)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: () {
                            final updated = List<String>.from(images)
                              ..removeAt(index);
                            setState(() {
                              itemMultiImages[uniqueId] =
                                  updated.isEmpty ? null : updated;
                            });
                            _autoSave();
                            _saveFieldToServer(item, uniqueId);
                          },
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.cancel,
                                size: 18, color: Colors.red),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickMultiImagesForItem(dynamic item) async {
    final uniqueId = _getItemUniqueId(item);
    final fieldId = _getItemFieldId(item);
    const maxImages = 11;
    final current = itemMultiImages[uniqueId] ?? [];

    if (current.length >= maxImages) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Maximum of 11 images already added'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final hasPermission = await _ensureMediaPermission(
      Permission.photos,
      permissionName: 'Gallery',
    );
    if (!hasPermission) return;

    try {
      final picker = ImagePicker();
      final picked = await picker.pickMultiImage(imageQuality: 100);
      if (picked.isEmpty || !mounted) return;

      final remainingSlots = maxImages - current.length;
      final toAdd = picked.take(remainingSlots).toList();

      if (toAdd.length < picked.length && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Only ${toAdd.length} image(s) added. Maximum is $maxImages.'),
            backgroundColor: Colors.orange,
          ),
        );
      }

      // Save locally and show in UI immediately
      final savedPaths = <String>[];
      for (final xFile in toAdd) {
        final saved = await LocalStorageService.saveImage(xFile.path);
        savedPaths.add(saved);
      }

      if (!mounted) return;
      setState(() {
        itemMultiImages[uniqueId] = [...current, ...savedPaths];
        _uploadingMultiImagePaths.addAll(savedPaths);
      });
      await _saveDataLocally();

      // Upload each image immediately, replacing local path with URL on success
      final sectionTitle = _sections[_currentSection]['title'] as String;
      final hasInternet = await ConnectivityChecker.canReachServer();

      if (!hasInternet) {
        if (mounted) {
          setState(() => _uploadingMultiImagePaths.removeAll(savedPaths));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                    Text('Images saved locally. Will upload when online.')),
          );
        }
        // Offline: persist to the durable upload queue right away so the photos
        // survive a hard kill and are recoverable on resume.
        unawaited(_commitPendingMediaToQueue());
        return;
      }

      for (final savedPath in savedPaths) {
        final result = await ApiService.uploadImage(
          savedPath,
          inspectionId: _effectiveInspectionId,
          section: sectionTitle,
          itemId: fieldId,
        );
        if (!mounted) return;

        final url = result['url']?.toString();
        final uploadSuccess =
            result['success'] == true && url != null && url.isNotEmpty;
        setState(() {
          _uploadingMultiImagePaths.remove(savedPath);
          if (uploadSuccess) {
            final imgs = List<String>.from(itemMultiImages[uniqueId] ?? []);
            final idx = imgs.indexOf(savedPath);
            if (idx != -1) imgs[idx] = url;
            itemMultiImages[uniqueId] = imgs;
          }
        });
        if (uploadSuccess) {
          try {
            await File(savedPath).delete();
          } catch (_) {}
        }
      }
      await _saveDataLocally();
      _saveFieldToServer(item, uniqueId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick images: $e')),
        );
      }
    }
  }

  Future<bool> _ensureMediaPermission(
    Permission permission, {
    required String permissionName,
  }) async {
    if (!Platform.isIOS) return true;

    var status = await permission.status;
    if (status.isGranted || status.isLimited) return true;

    if (status.isPermanentlyDenied || status.isRestricted) {
      _showPermissionDeniedSnackBar(permissionName, openSettings: true);
      return false;
    }

    status = await permission.request();
    if (status.isGranted || status.isLimited) return true;

    _showPermissionDeniedSnackBar(
      permissionName,
      openSettings: status.isPermanentlyDenied || status.isRestricted,
    );
    return false;
  }

  void _showPermissionDeniedSnackBar(
    String permissionName, {
    bool openSettings = false,
  }) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('$permissionName permission is required to continue.'),
        action: openSettings
            ? SnackBarAction(
                label: 'Settings',
                onPressed: () {
                  openAppSettings();
                },
              )
            : null,
      ),
    );
  }

  Future<void> _pickImage(ImageSource source, String uniqueId, String fieldId,
      {dynamic item}) async {
    try {
      final hasPermission = source == ImageSource.camera
          ? await _ensureMediaPermission(
              Permission.camera,
              permissionName: 'Camera',
            )
          : await _ensureMediaPermission(
              Permission.photos,
              permissionName: 'Gallery',
            );
      if (!hasPermission) return;

      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        imageQuality: 100,
      );

      if (image != null && mounted) {
        final String sectionTitle =
            _sections[_currentSection]['title'] as String;
        final savedPath = await LocalStorageService.saveImage(image.path);

        setState(() {
          itemImages[uniqueId] = savedPath;
          _markUploading(uniqueId);
        });
        if (item != null && mounted)
          _showFlagIssuesSheet(item, autoAdvanceOnConfirm: true);

        await _saveDataLocally();

        final bool hasInternet = await ConnectivityChecker.canReachServer();

        if (hasInternet) {
          final result = await ApiService.uploadImage(
            savedPath,
            inspectionId: _effectiveInspectionId,
            section: sectionTitle,
            itemId: fieldId,
            onProgress: (sent, total) =>
                _onUploadProgress(uniqueId, sent, total),
          );

          if (mounted) {
            setState(() {
              _unmarkUploading(uniqueId);
            });

            final url = result['url']?.toString();
            if (result['success'] == true && url != null && url.isNotEmpty) {
              setState(() {
                itemImages[uniqueId] = url;
              });
              await _saveDataLocally();
              try {
                await File(savedPath).delete();
              } catch (_) {}
              _saveFieldToServer(item, uniqueId);
            } else {
              // Was "will upload when online" for every failure, which is a
              // lie when the server rejected the file outright.
              _showUploadFailedSnack(result);
            }
          }
        } else {
          if (mounted) {
            setState(() {
              _unmarkUploading(uniqueId);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content:
                      Text('Image saved locally. Will upload when online.')),
            );
          }
          // Offline: persist to the durable upload queue right away so the photo
          // survives a hard kill and is recoverable on resume.
          unawaited(_commitPendingMediaToQueue());
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _unmarkUploading(uniqueId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick image: $e')),
        );
      }
    }
  }

  Future<void> _pickFile(dynamic item) async {
    final uniqueId = _getItemUniqueId(item);
    try {
      final hasPhotosPermission = await _ensureMediaPermission(
        Permission.photos,
        permissionName: 'File upload',
      );
      if (!hasPhotosPermission) return;

      final result = await FilePicker.platform.pickFiles(allowMultiple: false);
      if (result != null && result.files.single.path != null && mounted) {
        final file = result.files.single;
        setState(() {
          _pendingCapturedFilePath = file.path;
          _pendingCapturedFileUniqueId = uniqueId;
          _pendingCapturedFileName = file.name;
          _pendingCapturedFileExtension = file.extension?.toLowerCase() ?? '';
          _isReviewingFile = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick file: $e')),
        );
      }
    }
  }

  String _formatAudioDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _startAudioRecording(dynamic item) async {
    final uniqueId = _getItemUniqueId(item);
    try {
      // Always create a fresh recorder — reusing a stopped instance crashes
      // on Android (MediaRecorder state machine rejects re-start).
      await _audioRecorder?.dispose();
      _audioRecorder = AudioRecorder();

      // Use record's own hasPermission() — it handles Android runtime
      // permission requests correctly, unlike our iOS-only helper.
      if (!await _audioRecorder!.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content:
                  Text('Microphone permission is required to record audio'),
            ),
          );
        }
        return;
      }

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/audio_${uniqueId}_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder!.start(const RecordConfig(), path: path);
      _audioElapsed.value = Duration.zero;
      _audioTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _audioElapsed.value += const Duration(seconds: 1);
      });
      if (mounted) setState(() => _isRecordingAudio = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start recording: $e')),
        );
      }
    }
  }

  Future<void> _stopAudioRecording(dynamic item) async {
    final uniqueId = _getItemUniqueId(item);
    _audioTimer?.cancel();
    _audioTimer = null;
    try {
      final path = await _audioRecorder?.stop();
      // Release microphone as soon as the file path is captured.
      await _audioRecorder?.dispose();
      _audioRecorder = null;
      if (mounted) {
        setState(() {
          _isRecordingAudio = false;
          if (path != null) {
            _pendingCapturedAudioPath = path;
            _pendingCapturedAudioUniqueId = uniqueId;
            _isReviewingAudio = true;
          }
        });
      }
    } catch (e) {
      await _audioRecorder?.dispose();
      _audioRecorder = null;
      if (mounted) {
        setState(() => _isRecordingAudio = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stop recording: $e')),
        );
      }
    }
  }

  Future<void> _pickAudio(dynamic item) async {
    final uniqueId = _getItemUniqueId(item);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'm4a', 'aac'],
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null && mounted) {
        setState(() {
          _pendingCapturedAudioPath = result.files.single.path!;
          _pendingCapturedAudioUniqueId = uniqueId;
          _isReviewingAudio = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick audio: $e')),
        );
      }
    }
  }

  Future<void> _discardAllMedia(dynamic item) async {
    final uniqueId = _getItemUniqueId(item);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Discard all media?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          'This will remove the photo, video, audio, and any attached file for this item.',
          style: TextStyle(color: Colors.white60, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard',
                style: TextStyle(
                    color: Color(0xFFFF6B6B), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() {
        itemImages[uniqueId] = null;
        itemVideos[uniqueId] = null;
        itemAudios[uniqueId] = null;
        itemFiles[uniqueId] = null;
        itemMultiImages[uniqueId] = [];
      });
      _autoSave();
    }
  }

  void _showVideoPickerOptions(dynamic item) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.videocam, color: Colors.deepPurple),
                title: const Text('Record Video'),
                onTap: () {
                  Navigator.pop(context);
                  _pickVideo(item, ImageSource.camera);
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.video_library, color: Colors.deepPurple),
                title: const Text('Choose Video'),
                onTap: () {
                  Navigator.pop(context);
                  _pickVideo(item, ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAudioPickerOptions(dynamic item) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.mic, color: Color(0xFFF97316)),
                title: const Text('Record Audio'),
                onTap: () {
                  Navigator.pop(context);
                  _startAudioRecording(item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.audio_file, color: Color(0xFFF97316)),
                title: const Text('Browse Audio Files'),
                onTap: () {
                  Navigator.pop(context);
                  _pickAudio(item);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFilePickerOptions(dynamic item) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.attach_file, color: Color(0xFF22C55E)),
                title: const Text('Browse Files'),
                onTap: () {
                  Navigator.pop(context);
                  _pickFile(item);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickVideo(dynamic item, ImageSource source) async {
    final uniqueId = _getItemUniqueId(item);
    try {
      final hasVideoPermission = source == ImageSource.camera
          ? await _ensureMediaPermission(
              Permission.camera,
              permissionName: 'Camera',
            )
          : await _ensureMediaPermission(
              Permission.photos,
              permissionName: 'Gallery',
            );
      if (!hasVideoPermission) return;

      if (source == ImageSource.camera) {
        final hasMicrophonePermission = await _ensureMediaPermission(
          Permission.microphone,
          permissionName: 'Microphone',
        );
        if (!hasMicrophonePermission) return;
      }

      final picker = ImagePicker();
      final video = await picker.pickVideo(source: source);
      if (video != null && mounted) {
        setState(() {
          _pendingCapturedVideoFile = video;
          _pendingCapturedVideoUniqueId = uniqueId;
          _isReviewingVideo = true;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick video: $e')),
        );
      }
    }
  }

  String _extractFileName(String filePayload) {
    try {
      final parsed = json.decode(filePayload) as Map<String, dynamic>;
      return (parsed['fileName'] ?? 'attached_file').toString();
    } catch (_) {
      return filePayload.split('/').last;
    }
  }

  /// Records byte progress for a field's in-flight upload.
  ///
  /// Fires once per streamed chunk, so it throttles before publishing and
  /// smooths the rate — a raw per-chunk figure on mobile data swings between 0
  /// and several MB/s and reads as noise.
  void _onUploadProgress(String id, int sent, int total) {
    if (!mounted) return;
    if (!_uploadingImages.value.contains(id)) return;

    final now = DateTime.now();
    final previous = _uploadSamples[id];
    final complete = total > 0 && sent >= total;
    if (previous != null &&
        !complete &&
        now.difference(previous.at) < _uploadProgressFrame) {
      return;
    }

    double rate = _uploadProgress.value[id]?.bytesPerSecond ?? 0;
    if (previous != null) {
      final seconds = now.difference(previous.at).inMicroseconds / 1000000;
      final delta = sent - previous.sent;
      if (seconds > 0 && delta >= 0) {
        final sample = delta / seconds;
        rate = rate <= 0 ? sample : (rate * 0.7) + (sample * 0.3);
      }
    }

    _uploadSamples[id] = (at: now, sent: sent);
    _uploadProgress.value = {
      ..._uploadProgress.value,
      id: MediaFileProgress(sent: sent, total: total, bytesPerSecond: rate),
    };
  }

  /// Shows what the server said when a capture-time upload fails.
  ///
  /// The file stays on the device and is retried before submit, so this is not
  /// a dead end — but saying nothing made a failed upload look exactly like a
  /// successful one, which is how media went missing without anyone noticing.
  void _showUploadFailedSnack(Map<String, dynamic> result) {
    if (!mounted) return;
    final message = result['message']?.toString().trim();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message == null || message.isEmpty
            ? 'Upload failed. It will be retried before you submit.'
            : message),
        backgroundColor: const Color(0xFFF59E0B),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  // Mutating the Set in place wouldn't notify listeners, so assign a fresh Set.
  void _markUploading(String id) {
    if (_uploadingImages.value.contains(id)) return;
    _uploadingImages.value = {..._uploadingImages.value, id};
  }

  void _unmarkUploading(String id) {
    _uploadSamples.remove(id);
    if (_uploadProgress.value.containsKey(id)) {
      _uploadProgress.value = {..._uploadProgress.value}..remove(id);
    }
    if (!_uploadingImages.value.contains(id)) return;
    _uploadingImages.value = {..._uploadingImages.value}..remove(id);
  }

  Widget _buildImageWidget(String imagePath,
      {BoxFit fit = BoxFit.fitWidth, int? cacheWidth}) {
    if (imagePath.startsWith('http')) {
      return Image.network(
        imagePath,
        fit: fit,
        width: double.infinity,
        cacheWidth: cacheWidth,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          return const Center(
            child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
          );
        },
      );
    } else {
      return Image.file(
        File(LocalStorageService.resolveMediaPath(imagePath)),
        fit: fit,
        width: double.infinity,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
      );
    }
  }

  void _showImagePreview(String imagePath) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
              maxWidth: MediaQuery.of(context).size.width * 0.9,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () {
                        final items = _sections[_currentSection]['items']
                            as List<dynamic>;
                        final currentItem = items[_currentItemIndex];
                        final uniqueId = _getItemUniqueId(currentItem);
                        setState(() {
                          itemImages[uniqueId] = null;
                        });
                        _autoSave();
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
                Flexible(
                  child: InteractiveViewer(
                    panEnabled: true,
                    boundaryMargin: const EdgeInsets.all(20),
                    minScale: 0.5,
                    maxScale: 4,
                    child: imagePath.startsWith('http')
                        ? Image.network(imagePath, fit: BoxFit.contain)
                        : Image.file(
                            File(LocalStorageService.resolveMediaPath(
                                imagePath)),
                            fit: BoxFit.contain),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _acceptCapturedImage(int quarterTurns) async {
    final file = _pendingCapturedXFile;
    final uniqueId = _pendingCapturedUniqueId;
    if (file == null || uniqueId == null) return;

    setState(() {
      _isReviewingCapture = false;
      _pendingCapturedXFile = null;
      _pendingCapturedUniqueId = null;
    });

    final item = (_sections[_currentSection]['items']
        as List<dynamic>)[_currentItemIndex];
    final fieldId = _getItemFieldId(item);
    final sectionTitle = _sections[_currentSection]['title'] as String;
    final savedPath = await LocalStorageService.saveImage(file.path,
        rotateAngle: quarterTurns * 90);
    unawaited(LocalStorageService.saveMediaToUserStorage(
      savedPath,
      MediaType.image,
      inspectionId: _folderLabelForStorage,
    ));

    setState(() {
      itemImages[uniqueId] = savedPath;
      _markUploading(uniqueId);
    });
    if (mounted) _showFlagIssuesSheet(item, autoAdvanceOnConfirm: true);
    await _saveDataLocally();

    final bool hasInternet = await ConnectivityChecker.canReachServer();
    if (hasInternet) {
      final result = await ApiService.uploadImage(
        savedPath,
        inspectionId: _effectiveInspectionId,
        section: sectionTitle,
        itemId: fieldId,
        onProgress: (sent, total) => _onUploadProgress(uniqueId, sent, total),
      );
      if (mounted) {
        _unmarkUploading(uniqueId);
        final url = result['url']?.toString();
        if (result['success'] == true && url != null && url.isNotEmpty) {
          setState(() => itemImages[uniqueId] = url);
          await _saveDataLocally();
          try {
            await File(savedPath).delete();
          } catch (_) {}
          _saveFieldToServer(item, uniqueId);
        } else {
          _showUploadFailedSnack(result);
        }
      }
    } else {
      if (mounted) _unmarkUploading(uniqueId);
      // Offline: commit this media to the durable upload queue immediately so a
      // hard kill before the next background/close still leaves it queued for
      // upload and recoverable on resume (see _rehydratePendingMediaFromQueue).
      unawaited(_commitPendingMediaToQueue());
    }
  }

  Future<void> _acceptCapturedVideo(int quarterTurns) async {
    final file = _pendingCapturedVideoFile;
    final uniqueId = _pendingCapturedVideoUniqueId;
    if (file == null || uniqueId == null) return;

    String sectionTitle = '';
    String fieldId = '';
    dynamic foundItem;
    for (final section in _sections) {
      for (final item in section['items'] as List<dynamic>) {
        if (_getItemUniqueId(item) == uniqueId) {
          sectionTitle = section['title'] as String;
          fieldId = _getItemFieldId(item);
          foundItem = item;
          break;
        }
      }
      if (sectionTitle.isNotEmpty) break;
    }

    final savedPath = await LocalStorageService.saveVideo(file.path);

    unawaited(LocalStorageService.saveMediaToUserStorage(
      savedPath,
      MediaType.video,
      inspectionId: _folderLabelForStorage,
    ));

    setState(() {
      _isReviewingVideo = false;
      _pendingCapturedVideoFile = null;
      _pendingCapturedVideoUniqueId = null;
      itemVideos[uniqueId] = savedPath;
      itemVideoRotations[uniqueId] = quarterTurns;
      _markUploading(uniqueId);
    });
    if (foundItem != null && mounted)
      _showFlagIssuesSheet(foundItem, autoAdvanceOnConfirm: true);

    await _saveDataLocally();

    final bool hasInternet = await ConnectivityChecker.canReachServer();
    bool uploaded = false;
    if (hasInternet && sectionTitle.isNotEmpty) {
      final result = await ApiService.uploadImage(
        savedPath,
        inspectionId: _effectiveInspectionId,
        section: sectionTitle,
        itemId: fieldId,
        fieldName: 'image',
        mediaType: 'video',
        onProgress: (sent, total) => _onUploadProgress(uniqueId, sent, total),
      );
      final url = result['url']?.toString();
      uploaded = result['success'] == true && url != null && url.isNotEmpty;
      if (uploaded) {
        // Record the URL even if the page unmounted mid-upload, so a successful
        // upload is never lost to a navigation race.
        itemVideos[uniqueId] = url;
        await _saveDataLocally();
        try { await File(savedPath).delete(); } catch (_) {}
      } else {
        log('Video upload failed ($uniqueId): ${result['message']}');
        _showUploadFailedSnack(result);
      }
      if (mounted) {
        _unmarkUploading(uniqueId);
        if (uploaded) {
          setState(() {});
          _saveFieldToServer(foundItem, uniqueId);
        }
      }
    } else {
      if (mounted) _unmarkUploading(uniqueId);
    }

    // Anything still local — offline, no section, or a failed upload — goes to
    // the durable queue now, so a hard kill before the next background/close
    // still leaves it queued for upload and recoverable on resume (see
    // _rehydratePendingMediaFromQueue). Previously only the offline branch did
    // this, so a capture-time upload failure left the video unqueued.
    if (!uploaded) unawaited(_commitPendingMediaToQueue());
  }

  Future<void> _acceptCapturedAudio() async {
    final path = _pendingCapturedAudioPath;
    final uniqueId = _pendingCapturedAudioUniqueId;
    if (path == null || uniqueId == null) return;

    String sectionTitle = '';
    String fieldId = '';
    dynamic foundItem;
    for (final section in _sections) {
      for (final item in section['items'] as List<dynamic>) {
        if (_getItemUniqueId(item) == uniqueId) {
          sectionTitle = section['title'] as String;
          fieldId = _getItemFieldId(item);
          foundItem = item;
          break;
        }
      }
      if (sectionTitle.isNotEmpty) break;
    }

    unawaited(LocalStorageService.saveMediaToUserStorage(
      path,
      MediaType.audio,
      inspectionId: _folderLabelForStorage,
    ));

    setState(() {
      _isReviewingAudio = false;
      _pendingCapturedAudioPath = null;
      _pendingCapturedAudioUniqueId = null;
      itemAudios[uniqueId] = path;
      _markUploading(uniqueId);
    });
    if (foundItem != null && mounted)
      _showFlagIssuesSheet(foundItem, autoAdvanceOnConfirm: true);

    await _saveDataLocally();

    final bool hasInternet = await ConnectivityChecker.canReachServer();
    if (hasInternet && sectionTitle.isNotEmpty) {
      final result = await ApiService.uploadImage(
        path,
        inspectionId: _effectiveInspectionId,
        section: sectionTitle,
        itemId: fieldId,
        fieldName: 'image',
        onProgress: (sent, total) => _onUploadProgress(uniqueId, sent, total),
      );
      if (mounted) {
        _unmarkUploading(uniqueId);
        final url = result['url']?.toString();
        if (result['success'] == true && url != null && url.isNotEmpty) {
          setState(() => itemAudios[uniqueId] = url);
          await _saveDataLocally();
          try {
            await File(path).delete();
          } catch (_) {}
          _saveFieldToServer(foundItem, uniqueId);
        } else {
          _showUploadFailedSnack(result);
        }
      }
    } else {
      if (mounted) _unmarkUploading(uniqueId);
      // Offline: commit this media to the durable upload queue immediately so a
      // hard kill before the next background/close still leaves it queued for
      // upload and recoverable on resume (see _rehydratePendingMediaFromQueue).
      unawaited(_commitPendingMediaToQueue());
    }
  }

  Future<void> _acceptCapturedFile() async {
    final path = _pendingCapturedFilePath;
    final uniqueId = _pendingCapturedFileUniqueId;
    final name = _pendingCapturedFileName;
    final ext = _pendingCapturedFileExtension;
    if (path == null || uniqueId == null) return;

    String sectionTitle = '';
    String fieldId = '';
    dynamic foundItem;
    for (final section in _sections) {
      for (final item in section['items'] as List<dynamic>) {
        if (_getItemUniqueId(item) == uniqueId) {
          sectionTitle = section['title'] as String;
          fieldId = _getItemFieldId(item);
          foundItem = item;
          break;
        }
      }
      if (sectionTitle.isNotEmpty) break;
    }

    unawaited(LocalStorageService.saveMediaToUserStorage(
      path,
      MediaType.file,
      inspectionId: _folderLabelForStorage,
    ));

    final payload = json.encode({
      'filePath': path,
      'fileName': name ?? path.split('/').last,
      'fileType': ext ?? '',
    });
    setState(() {
      _isReviewingFile = false;
      _pendingCapturedFilePath = null;
      _pendingCapturedFileUniqueId = null;
      _pendingCapturedFileName = null;
      _pendingCapturedFileExtension = null;
      itemFiles[uniqueId] = payload;
      _markUploading(uniqueId);
    });
    if (foundItem != null && mounted)
      _showFlagIssuesSheet(foundItem, autoAdvanceOnConfirm: true);

    await _saveDataLocally();

    final bool hasInternet = await ConnectivityChecker.canReachServer();
    if (hasInternet && sectionTitle.isNotEmpty) {
      final result = await ApiService.uploadImage(
        path,
        inspectionId: _effectiveInspectionId,
        section: sectionTitle,
        itemId: fieldId,
        fieldName: 'image',
        onProgress: (sent, total) => _onUploadProgress(uniqueId, sent, total),
      );
      if (mounted) {
        _unmarkUploading(uniqueId);
        final url = result['url']?.toString();
        if (result['success'] == true && url != null && url.isNotEmpty) {
          setState(() => itemFiles[uniqueId] = json.encode({
                'filePath': url,
                'fileName': name ?? path.split('/').last,
                'fileType': ext ?? '',
              }));
          await _saveDataLocally();
          try {
            await File(path).delete();
          } catch (_) {}
          _saveFieldToServer(foundItem, uniqueId);
        } else {
          _showUploadFailedSnack(result);
        }
      }
    } else {
      if (mounted) _unmarkUploading(uniqueId);
      // Offline: commit this media to the durable upload queue immediately so a
      // hard kill before the next background/close still leaves it queued for
      // upload and recoverable on resume (see _rehydratePendingMediaFromQueue).
      unawaited(_commitPendingMediaToQueue());
    }
  }

  bool _checkCurrentItemFlagIssue() {
    final currentSection = _sections[_currentSection];
    final items = currentSection['items'] as List<dynamic>;
    if (items.isEmpty) return true;

    final currentItem = items[_currentItemIndex];
    if (!(_itemHasImage(currentItem) || _itemHasVideo(currentItem))) {
      return true;
    }

    final uniqueId = _getItemUniqueId(currentItem);
    final hasMedia = (itemImages[uniqueId] != null) ||
        (itemVideos[uniqueId] != null) ||
        (itemFiles[uniqueId] != null) ||
        (itemAudios[uniqueId] != null);
    if (!hasMedia) return true;

    final conditionValue = itemValues[uniqueId] ?? '';
    final issueMarked =
        conditionValue == 'no_issues' || conditionValue == 'flagged';
    if (!issueMarked) {
      _highlightFlagIssues.value = true;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Please flag an issue or mark as no issues before proceeding'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return false;
    }
    return true;
  }

  bool _checkCurrentItemRequired() {
    final currentSection = _sections[_currentSection];
    final items = currentSection['items'] as List<dynamic>;
    if (items.isEmpty) return true;

    final currentItem = items[_currentItemIndex];
    if (!_itemIsRequired(currentItem)) return true;

    final uniqueId = _getItemUniqueId(currentItem);
    final title = _getItemTitle(currentItem);
    final errors = <String>[];

    if (_itemUsesTextField(currentItem)) {
      final value = itemValues[uniqueId]?.trim() ?? '';
      if (value.isEmpty) errors.add(title);
    } else if (_itemHasOptions(currentItem)) {
      final value = itemValues[uniqueId] ?? 'N/A';
      if (value == 'N/A' || value.isEmpty) errors.add(title);
    }

    if (_itemHasImage(currentItem)) {
      if (itemImages[uniqueId] == null || itemImages[uniqueId]!.isEmpty) {
        errors.add('$title (image)');
      }
    }
    if (_itemHasVideo(currentItem)) {
      if (itemVideos[uniqueId] == null || itemVideos[uniqueId]!.isEmpty) {
        errors.add('$title (video)');
      }
    }
    if (_itemHasFile(currentItem)) {
      if (itemFiles[uniqueId] == null || itemFiles[uniqueId]!.isEmpty) {
        errors.add('$title (file)');
      }
    }

    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('"$title" is required and must be filled before proceeding'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 3),
        ),
      );
      return false;
    }
    return true;
  }

  void _nextItem() {
    if (_isReviewingCapture) {
      setState(() {
        _isReviewingCapture = false;
        _pendingCapturedXFile = null;
        _pendingCapturedUniqueId = null;
      });
      return;
    }
    if (_isReviewingVideo) {
      setState(() {
        _isReviewingVideo = false;
        _pendingCapturedVideoFile = null;
        _pendingCapturedVideoUniqueId = null;
      });
      return;
    }
    if (_isReviewingAudio) {
      setState(() {
        _isReviewingAudio = false;
        _pendingCapturedAudioPath = null;
        _pendingCapturedAudioUniqueId = null;
      });
      return;
    }
    if (!_checkCurrentItemFlagIssue()) return;
    if (!_checkCurrentItemRequired()) return;
    _highlightFlagIssues.value = false;
    final currentSection = _sections[_currentSection];
    final items = currentSection['items'] as List<dynamic>;
    if (items.isEmpty) return;
    if (_currentItemIndex < items.length - 1) {
      _audioTimer?.cancel();
      _audioTimer = null;
      _audioRecorder?.stop().then((_) {
        _audioRecorder?.dispose();
        _audioRecorder = null;
      });
      final nextItem = items[_currentItemIndex + 1];
      setState(() {
        _currentItemIndex++;
        _currentCaptureMode = _defaultCaptureModeForItem(nextItem);
        _triggerPhotoCapture = null;
        _triggerEnlarge = null;
        _triggerFlashToggle = null;
        _captureUi.flashOn.value = false;
        _triggerVideoToggle = null;
        _triggerVideoPauseResume = null;
        _captureUi.isVideoRecording.value = false;
        _captureUi.isVideoPaused.value = false;
        _isRecordingAudio = false;
        _audioElapsed.value = Duration.zero;
      });
      _autoSave();
    } else {
      _nextSection();
    }
  }

  void _previousItem() {
    if (_isReviewingCapture) {
      setState(() {
        _isReviewingCapture = false;
        _pendingCapturedXFile = null;
        _pendingCapturedUniqueId = null;
      });
      return;
    }
    if (_isReviewingVideo) {
      setState(() {
        _isReviewingVideo = false;
        _pendingCapturedVideoFile = null;
        _pendingCapturedVideoUniqueId = null;
      });
      return;
    }
    if (_isReviewingAudio) {
      setState(() {
        _isReviewingAudio = false;
        _pendingCapturedAudioPath = null;
        _pendingCapturedAudioUniqueId = null;
      });
      return;
    }
    if (_currentItemIndex > 0) {
      _audioTimer?.cancel();
      _audioTimer = null;
      _audioRecorder?.stop().then((_) {
        _audioRecorder?.dispose();
        _audioRecorder = null;
      });
      final currentItems = _sections[_currentSection]['items'] as List<dynamic>;
      final prevItem = currentItems[_currentItemIndex - 1];
      setState(() {
        _currentItemIndex--;
        _currentCaptureMode = _defaultCaptureModeForItem(prevItem);
        _triggerPhotoCapture = null;
        _triggerEnlarge = null;
        _triggerFlashToggle = null;
        _captureUi.flashOn.value = false;
        _triggerVideoToggle = null;
        _triggerVideoPauseResume = null;
        _captureUi.isVideoRecording.value = false;
        _captureUi.isVideoPaused.value = false;
        _isRecordingAudio = false;
        _audioElapsed.value = Duration.zero;
        _highlightFlagIssues.value = false;
      });
      _autoSave();
      return;
    }
    if (_currentSection <= 0) return;

    // Crossing back into the previous section — flush this one's edits first.
    _flushDirtySectionsToServer();

    final prevItems = _sections[_currentSection - 1]['items'] as List<dynamic>;
    final lastIdx = prevItems.isEmpty ? 0 : prevItems.length - 1;
    final lastItem = prevItems.isNotEmpty ? prevItems[lastIdx] : null;

    setState(() {
      _currentSection--;
      _currentItemIndex = lastIdx;
      if (lastItem != null) {
        _currentCaptureMode = _defaultCaptureModeForItem(lastItem);
      }
    });

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _autoSave();
      }
    });
  }

  // Collects the missing required fields in [section] that the user has not yet
  // filled in (text/options) or attached required media for. Each entry carries
  // the item's index within the section so the UI can jump straight to it.
  List<({String label, int itemIndex})> _sectionRequiredFieldErrorsDetailed(
      Map<String, dynamic> section) {
    final items = section['items'] as List<dynamic>;
    final errors = <({String label, int itemIndex})>[];

    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (!_itemIsRequired(item)) continue;

      final uniqueId = _getItemUniqueId(item);
      final title = _getItemTitle(item);

      if (_itemUsesTextField(item)) {
        final value = itemValues[uniqueId]?.trim() ?? '';
        if (value.isEmpty) {
          errors.add((label: title, itemIndex: index));
        }
      } else if (_itemHasOptions(item)) {
        final value = itemValues[uniqueId] ?? 'N/A';
        if (value == 'N/A' || value.isEmpty) {
          errors.add((label: title, itemIndex: index));
        }
      }

      if (_itemHasImage(item)) {
        if (itemImages[uniqueId] == null || itemImages[uniqueId]!.isEmpty) {
          errors.add((label: '$title (image)', itemIndex: index));
        }
      }
      if (_itemHasVideo(item)) {
        if (itemVideos[uniqueId] == null || itemVideos[uniqueId]!.isEmpty) {
          errors.add((label: '$title (video)', itemIndex: index));
        }
      }
      if (_itemHasFile(item)) {
        if (itemFiles[uniqueId] == null || itemFiles[uniqueId]!.isEmpty) {
          errors.add((label: '$title (file)', itemIndex: index));
        }
      }
    }

    return errors;
  }

  List<String> _getRequiredFieldErrors() {
    return _sectionRequiredFieldErrorsDetailed(_sections[_currentSection])
        .map((e) => e.label)
        .toList();
  }

  // Validates required fields across every section, grouped by section so the
  // submit sheet can list them under headers and navigate to each one.
  List<
      ({
        int sectionIndex,
        String sectionTitle,
        List<({String label, int itemIndex})> fields
      })> _getGroupedRequiredFieldErrors() {
    final groups = <({
      int sectionIndex,
      String sectionTitle,
      List<({String label, int itemIndex})> fields
    })>[];

    for (var i = 0; i < _sections.length; i++) {
      final section = _sections[i];
      final detailed = _sectionRequiredFieldErrorsDetailed(section);
      if (detailed.isEmpty) continue;
      groups.add((
        sectionIndex: i,
        sectionTitle: (section['title'] as String?) ?? '',
        fields: detailed,
      ));
    }

    return groups;
  }

  // Jumps the inspection to a specific section/item, resetting capture state
  // the same way section/item navigation does, and highlights the target.
  void _jumpToSectionItem(int sectionIndex, int itemIndex) {
    if (sectionIndex < 0 || sectionIndex >= _sections.length) return;
    final items = _sections[sectionIndex]['items'] as List<dynamic>;
    final safeItemIndex =
        (itemIndex >= 0 && itemIndex < items.length) ? itemIndex : 0;
    final targetItem = items.isNotEmpty ? items[safeItemIndex] : null;

    // Jumping to another section — flush any pending edits from the current one.
    if (sectionIndex != _currentSection) _flushDirtySectionsToServer();

    _audioTimer?.cancel();
    _audioTimer = null;
    _audioRecorder?.stop().then((_) {
      _audioRecorder?.dispose();
      _audioRecorder = null;
    });

    setState(() {
      _currentSection = sectionIndex;
      _currentItemIndex = safeItemIndex;
      _currentCaptureMode =
          targetItem != null ? _defaultCaptureModeForItem(targetItem) : 'PHOTO';
      _triggerPhotoCapture = null;
      _triggerEnlarge = null;
      _triggerFlashToggle = null;
      _captureUi.flashOn.value = false;
      _triggerVideoToggle = null;
      _triggerVideoPauseResume = null;
      _captureUi.isVideoRecording.value = false;
      _captureUi.isVideoPaused.value = false;
      _isRecordingAudio = false;
      _audioElapsed.value = Duration.zero;
    });

    // Highlight the exact field the user was sent back to fill in.
    _highlightMissingFieldId.value =
        targetItem != null ? _getItemUniqueId(targetItem) : null;
    _highlightFlagIssues.value = targetItem != null;

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _autoSave();
      }
    });
  }

  // Graceful replacement for the "required fields missing" snackbar: a bottom
  // sheet listing what's left, grouped by section, with each row tappable to
  // jump straight to the offending field.
  void _showRequiredFieldsSheet(
    List<
            ({
              int sectionIndex,
              String sectionTitle,
              List<({String label, int itemIndex})> fields
            })>
        groups,
  ) {
    final totalMissing = groups.fold<int>(0, (sum, g) => sum + g.fields.length);
    log('Submission blocked - $totalMissing required field(s) missing across ${groups.length} section(s)');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE4E7EB),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.error_outline,
                            color: Color(0xFFDC2626), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Almost done',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$totalMissing required ${totalMissing == 1 ? "item" : "items"} left to complete',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE4E7EB)),
                Flexible(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shrinkWrap: true,
                    itemCount: groups.length,
                    itemBuilder: (context, gIndex) {
                      final group = groups[gIndex];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (group.sectionTitle.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                              child: Text(
                                group.sectionTitle.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  color: Color(0xFF9CA3AF),
                                ),
                              ),
                            ),
                          ...group.fields.map(
                            (field) => InkWell(
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                _jumpToSectionItem(
                                    group.sectionIndex, field.itemIndex);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 12),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFFDC2626),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        field.label,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          color: Color(0xFF111827),
                                        ),
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right,
                                        size: 20, color: Color(0xFF9CA3AF)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        final first = groups.first;
                        _jumpToSectionItem(
                            first.sectionIndex, first.fields.first.itemIndex);
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Go to first missing field'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Every file the inspector has captured, in the order the form asks for it.
  ///
  /// Read fresh on each build of the status sheet: a value flips from a local
  /// path to an https URL the moment its upload lands, and that flip is the
  /// only record that the file made it.
  List<({String label, String type, String value, String uniqueId})>
      _capturedMedia() {
    final media = <({String label, String type, String value, String uniqueId})>[];

    for (final section in _sections) {
      final sectionTitle = (section['title'] ?? '').toString();
      final items = section['items'];
      if (items is! List) continue;

      for (final item in items) {
        final uniqueId = _getItemUniqueId(item);
        final title = _getItemTitle(item);
        final label = sectionTitle.isEmpty ? title : '$title · $sectionTitle';

        void add(String type, String? value) {
          if (value == null || value.isEmpty) return;
          media.add(
              (label: label, type: type, value: value, uniqueId: uniqueId));
        }

        add('Photo', itemImages[uniqueId]);
        add('Video', itemVideos[uniqueId]);
        add('Audio', itemAudios[uniqueId]);
        final filePayload = itemFiles[uniqueId];
        if (filePayload != null && filePayload.isNotEmpty) {
          add('Document', _filePathFromPayload(filePayload));
        }
        for (final path in itemMultiImages[uniqueId] ?? const <String>[]) {
          add('Photo', path);
        }
      }
    }

    return media;
  }

  static IconData _mediaTypeIcon(String type) {
    switch (type) {
      case 'Video':
        return Icons.videocam_outlined;
      case 'Audio':
        return Icons.mic_none;
      case 'Document':
        return Icons.description_outlined;
      default:
        return Icons.image_outlined;
    }
  }

  /// The upload/completion sheet behind the header percentage.
  ///
  /// Two questions the inspector could not answer before opening this: has my
  /// media actually reached the server, and what is still stopping me from
  /// submitting. Both were only discoverable by pressing Submit and reading
  /// what it refused to do.
  void _showInspectionStatusSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
            ),
            // Rebuilds on every upload tick, so a video's percentage moves
            // while the sheet is open instead of freezing at whatever it read
            // when it was pushed.
            child: ValueListenableBuilder<Set<String>>(
              valueListenable: _uploadingImages,
              builder: (context, uploading, _) {
                return ValueListenableBuilder<Map<String, MediaFileProgress>>(
                  valueListenable: _uploadProgress,
                  builder: (context, progress, __) {
                    final media = _capturedMedia();
                    final uploaded =
                        media.where((m) => m.value.startsWith('http')).length;
                    final groups = _getGroupedRequiredFieldErrors();
                    final missing = groups.fold<int>(
                        0, (sum, g) => sum + g.fields.length);

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 12),
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE4E7EB),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                          child: Text(
                            '$_progressPercent% complete',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF111827),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                          child: Text(
                            media.isEmpty
                                ? 'No media captured yet'
                                : '$uploaded of ${media.length} files uploaded'
                                    '${missing > 0 ? ' · $missing field${missing == 1 ? '' : 's'} still required' : ''}',
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF6B7280)),
                          ),
                        ),
                        const Divider(height: 1),
                        Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              if (media.isNotEmpty) ...[
                                _statusSheetHeader('MEDIA'),
                                ...media.map((m) => _mediaStatusRow(
                                      m.label,
                                      m.type,
                                      m.value,
                                      uploading.contains(m.uniqueId),
                                      progress[m.uniqueId],
                                    )),
                              ],
                              if (groups.isNotEmpty) ...[
                                _statusSheetHeader('STILL REQUIRED'),
                                ...groups.expand((group) => group.fields.map(
                                      (field) => InkWell(
                                        onTap: () {
                                          Navigator.of(sheetContext).pop();
                                          _jumpToSectionItem(
                                              group.sectionIndex,
                                              field.itemIndex);
                                        },
                                        child: Padding(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 20,
                                                  vertical: 12),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 6,
                                                height: 6,
                                                decoration:
                                                    const BoxDecoration(
                                                  color: Color(0xFFDC2626),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  group.sectionTitle.isEmpty
                                                      ? field.label
                                                      : '${field.label} · ${group.sectionTitle}',
                                                  style: const TextStyle(
                                                      fontSize: 14,
                                                      color:
                                                          Color(0xFF111827)),
                                                ),
                                              ),
                                              const Icon(Icons.chevron_right,
                                                  size: 20,
                                                  color: Color(0xFF9CA3AF)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )),
                              ],
                              if (media.isEmpty && groups.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text(
                                    'Everything is filled in and uploaded.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 14,
                                        color: Color(0xFF6B7280)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _statusSheetHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: Color(0xFF9CA3AF),
          ),
        ),
      );

  /// One captured file and where it has got to.
  Widget _mediaStatusRow(
    String label,
    String type,
    String value,
    bool uploading,
    MediaFileProgress? progress,
  ) {
    final done = value.startsWith('http');
    final String status;
    final Color color;
    if (done) {
      status = 'Uploaded';
      color = const Color(0xFF22C55E);
    } else if (uploading) {
      status = uploadBadgeLabel(progress);
      color = const Color(0xFFF59E0B);
    } else {
      // Not a failure: it is on the device and goes up before submit. Saying
      // "pending" rather than nothing is what stops the inspector assuming it
      // is lost.
      status = 'On device';
      color = const Color(0xFF6B7280);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Icon(_mediaTypeIcon(type), size: 18, color: const Color(0xFF9CA3AF)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: Color(0xFF111827)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            status,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
          if (done) ...[
            const SizedBox(width: 6),
            const Icon(Icons.check_circle, size: 15, color: Color(0xFF22C55E)),
          ],
        ],
      ),
    );
  }

  /// Shown when one or more media uploads fail during submission, so the user
  /// can retry instead of the field silently arriving empty on the server.
  void _showUploadFailedSheet(List<MediaUploadFailure> fields) {
    log('Submission blocked - ${fields.length} media upload(s) failed: '
        '${fields.map((f) => "${f.field} (${f.reason})").join(", ")}');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE4E7EB),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.cloud_off,
                            color: Color(0xFFDC2626), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Some media didn\'t upload',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${fields.length} ${fields.length == 1 ? "item" : "items"} failed to upload. See why below, then submit again.',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE4E7EB)),
                Flexible(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shrinkWrap: true,
                    itemCount: fields.length,
                    itemBuilder: (context, index) {
                      final failure = fields[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.only(top: 7),
                              decoration: const BoxDecoration(
                                color: Color(0xFFDC2626),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    failure.field,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    failure.reason,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF6B7280),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _handleSubmission();
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Retry submission'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _nextSection() {
    if (!_checkCurrentItemFlagIssue()) return;
    _highlightFlagIssues.value = false;
    final errors = _getRequiredFieldErrors();
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Required fields missing: ${errors.join(", ")}'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    if (_currentSection < _sections.length - 1) {
      // Leaving this section — push its accumulated edits as one save-step.
      _flushDirtySectionsToServer();
      _audioTimer?.cancel();
      _audioTimer = null;
      _audioRecorder?.stop().then((_) {
        _audioRecorder?.dispose();
        _audioRecorder = null;
      });
      final nextSectionItems =
          _sections[_currentSection + 1]['items'] as List<dynamic>;
      final firstNextItem =
          nextSectionItems.isNotEmpty ? nextSectionItems.first : null;
      setState(() {
        _currentSection++;
        _currentItemIndex = 0;
        _currentCaptureMode = firstNextItem != null
            ? _defaultCaptureModeForItem(firstNextItem)
            : 'PHOTO';
        _triggerPhotoCapture = null;
        _triggerEnlarge = null;
        _triggerFlashToggle = null;
        _captureUi.flashOn.value = false;
        _triggerVideoToggle = null;
        _triggerVideoPauseResume = null;
        _captureUi.isVideoRecording.value = false;
        _captureUi.isVideoPaused.value = false;
        _isRecordingAudio = false;
        _audioElapsed.value = Duration.zero;
      });

      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }

      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _autoSave();
        }
      });
    } else {
      if (_isSubmitting) return;

      // Final guard: every required field across all sections must be filled
      // before we allow submission. Surface any that are missing in a sheet.
      final missingGroups = _getGroupedRequiredFieldErrors();
      if (missingGroups.isNotEmpty) {
        _showRequiredFieldsSheet(missingGroups);
        return;
      }

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Submit Inspection'),
            content: const Text(
                'Are you sure you want to submit the inspection data?'),
            actions: [
              TextButton(
                onPressed:
                    _isSubmitting ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: _isSubmitting
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _handleSubmission();
                      },
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Submit'),
              ),
            ],
          );
        },
      );
    }
  }

  /// Builds the full submission payload.
  ///
  /// Pass [httpOnly] true for the actual server submit so local media paths are
  /// dropped (never POSTed). Leave false for offline-saved copies, whose local
  /// paths are still needed and get remapped to URLs by the retry path.
  Map<String, dynamic> _buildSubmissionBody({bool httpOnly = false}) {
    Map<String, dynamic> inspectionData = {};

    for (var section in _sections) {
      final sectionName = (section['name'] as String?) ??
          (section['title'] as String).toLowerCase().replaceAll(' ', '_');
      // Reuse _buildSectionItems to avoid duplication.
      final sectionItems = _buildSectionItems(section, httpOnly: httpOnly);
      inspectionData[sectionName] = {
        'title': section['title'],
        'items': sectionItems,
      };
    }

    // Prefer 'regno' (Documents field id) then any registration-like key
    String registrationNumber = '';
    final regnoValue = (itemValues['regno'] ?? '').trim();
    if (regnoValue.isNotEmpty && regnoValue != 'N/A') {
      registrationNumber = regnoValue;
    } else {
      for (var key in itemValues.keys) {
        final k = key.toLowerCase();
        if (k.contains('registration') ||
            k.contains('regnumber') ||
            k.contains('reg_number') ||
            k.contains('regno')) {
          final value = (itemValues[key] ?? '').trim();
          if (value.isNotEmpty && value != 'N/A') {
            registrationNumber = value;
            break;
          }
        }
      }
    }
    // Fall back to the regno entered on the vehicle-details form. It lives in
    // vehicleDetails and only reaches itemValues when the template happens to
    // expose a matching field, so without this the regno is dropped from the
    // (offline-stored and later uploaded) submission body.
    if (registrationNumber.isEmpty) {
      final fromVehicle = (vehicleDetails?['regno'] ?? '').toString().trim();
      if (fromVehicle.isNotEmpty && fromVehicle != 'N/A') {
        registrationNumber = fromVehicle;
      }
    }

    return {
      'template_type': 'default',
      // The server inspection id, when this draft already exists server-side
      // (initialized online, or resumed). Lets the submit path finalise the
      // existing draft via POST /{id}/submit instead of creating a duplicate,
      // and lets the offline-queue drain know which inspection to finalise.
      if (_effectiveInspectionId != null)
        'inspection_id': _effectiveInspectionId,
      // Only send brand/model ids when known. Emitting null would clobber the
      // draft's existing brand/model on a submit-by-id call.
      if (vehicleDetails?['brand_id'] != null)
        'vehicle_brand_id': vehicleDetails!['brand_id'],
      if (vehicleDetails?['model_id'] != null)
        'vehicle_model_id': vehicleDetails!['model_id'],
      if ((vehicleDetails?['year'] ?? '').toString().isNotEmpty)
        'year': vehicleDetails!['year'],
      if ((vehicleDetails?['variant'] ?? '').toString().isNotEmpty)
        'variant': vehicleDetails!['variant'],
      if ((vehicleDetails?['color'] ?? '').toString().isNotEmpty)
        'color': vehicleDetails!['color'],
      if ((vehicleDetails?['transmission'] ?? '').toString().isNotEmpty)
        'transmission': vehicleDetails!['transmission'],
      'registration_number': registrationNumber,
      'inspection_data': inspectionData,
    };
  }

  /// Uploads any media that is still a local path (capture-time upload failed).
  /// Runs before submission so the backend always receives URLs, not local paths.
  ///
  /// URLs are written into the in-memory maps unconditionally (no longer behind a
  /// `mounted` setState) so a successful upload is never lost if the page unmounts
  /// mid-run; the setState only repaints. Returns the list of field titles whose
  /// upload failed so the caller can block submission instead of silently POSTing
  /// a local path the server can't resolve.
  Future<List<MediaUploadFailure>> _uploadRemainingImages() async {
    final failed = <MediaUploadFailure>[];

    void markFailed(dynamic item, Map<String, dynamic> result) {
      final title = _getItemTitle(item);
      final label = title.isNotEmpty ? title : _getItemFieldId(item);
      if (label.isEmpty) return;
      if (failed.any((f) => f.field == label)) return;
      final reason =
          result['message']?.toString().trim() ?? 'Upload failed. Try again.';
      failed.add(MediaUploadFailure(
          label, reason.isEmpty ? 'Upload failed. Try again.' : reason));
    }

    for (var section in _sections) {
      final sectionTitle = section['title'] as String;
      for (var item in section['items'] as List<dynamic>) {
        final uniqueId = _getItemUniqueId(item);
        final fieldId = _getItemFieldId(item);

        final imagePath = itemImages[uniqueId];
        if (imagePath != null && !imagePath.startsWith('http')) {
          if (mounted) _markUploading(uniqueId);
          final result = await ApiService.uploadImage(
            imagePath,
            inspectionId: _effectiveInspectionId,
            section: sectionTitle,
            itemId: fieldId,
          );
          final url = result['url']?.toString();
          if (result['success'] == true && url != null && url.isNotEmpty) {
            itemImages[uniqueId] = url;
          } else {
            markFailed(item, result);
          }
          if (mounted) setState(() => _unmarkUploading(uniqueId));
        }

        final multiImages = itemMultiImages[uniqueId];
        if (multiImages != null && multiImages.isNotEmpty) {
          final List<String> updated = [];
          for (final path in multiImages) {
            if (!path.startsWith('http')) {
              final result = await ApiService.uploadImage(
                path,
                inspectionId: _effectiveInspectionId,
                section: sectionTitle,
                itemId: fieldId,
              );
              final url = result['url']?.toString();
              if (result['success'] == true && url != null && url.isNotEmpty) {
                updated.add(url);
              } else {
                updated.add(path);
                markFailed(item, result);
              }
            } else {
              updated.add(path);
            }
          }
          itemMultiImages[uniqueId] = updated;
          if (mounted) setState(() {});
        }

        final videoPath = itemVideos[uniqueId];
        if (videoPath != null && !videoPath.startsWith('http')) {
          if (mounted) _markUploading(uniqueId);
          final result = await ApiService.uploadImage(
            videoPath,
            inspectionId: _effectiveInspectionId,
            section: sectionTitle,
            itemId: fieldId,
            fieldName: 'image',
            mediaType: 'video',
            onProgress: (sent, total) =>
                _onUploadProgress(uniqueId, sent, total),
          );
          final url = result['url']?.toString();
          if (result['success'] == true && url != null && url.isNotEmpty) {
            itemVideos[uniqueId] = url;
          } else {
            markFailed(item, result);
          }
          if (mounted) setState(() => _unmarkUploading(uniqueId));
        }

        final audioPath = itemAudios[uniqueId];
        if (audioPath != null && !audioPath.startsWith('http')) {
          if (mounted) _markUploading(uniqueId);
          final result = await ApiService.uploadImage(
            audioPath,
            inspectionId: _effectiveInspectionId,
            section: sectionTitle,
            itemId: fieldId,
            fieldName: 'image',
          );
          final url = result['url']?.toString();
          if (result['success'] == true && url != null && url.isNotEmpty) {
            itemAudios[uniqueId] = url;
          } else {
            markFailed(item, result);
          }
          if (mounted) setState(() => _unmarkUploading(uniqueId));
        }

        final filePayload = itemFiles[uniqueId];
        if (filePayload != null) {
          String? localPath;
          String? fileName;
          String? fileType;
          try {
            final decoded = json.decode(filePayload) as Map<String, dynamic>;
            final p = decoded['filePath'] as String?;
            if (p != null && !p.startsWith('http')) {
              localPath = p;
              fileName = decoded['fileName'] as String?;
              fileType = decoded['fileType'] as String?;
            }
          } catch (_) {
            if (!filePayload.startsWith('http')) localPath = filePayload;
          }
          if (localPath != null) {
            if (mounted) _markUploading(uniqueId);
            final result = await ApiService.uploadImage(
              localPath,
              inspectionId: _effectiveInspectionId,
              section: sectionTitle,
              itemId: fieldId,
              fieldName: 'image',
            );
            final url = result['url']?.toString();
            if (result['success'] == true && url != null && url.isNotEmpty) {
              itemFiles[uniqueId] = json.encode({
                'filePath': url,
                'fileName': fileName ?? localPath.split('/').last,
                'fileType': fileType ?? '',
              });
            } else {
              markFailed(item, result);
            }
            if (mounted) setState(() => _unmarkUploading(uniqueId));
          }
        }
      }
    }
    await _saveDataLocally();
    return failed;
  }

  /// Saves the in-progress inspection as an offline record so a submit that
  /// did not land can be retried later.
  ///
  /// Called from BOTH the rejected-response path and the exception path — an
  /// exception is exactly when durability matters most, and skipping it there
  /// left the work with nothing backing it.
  Future<void> _persistSubmissionForRetry() async {
    final finalItemImages = Map<String, String?>.from(itemImages);
    final finalItemVideos = Map<String, String?>.from(itemVideos);
    final finalItemAudios = Map<String, String?>.from(itemAudios);
    final finalItemFiles = Map<String, String?>.from(itemFiles);
    final finalMultiImages = <String, List<String>>{};
    itemMultiImages.forEach((key, value) {
      if (value != null && value.isNotEmpty) finalMultiImages[key] = value;
    });

    // Section/fieldId per image so the offline upload can route it later.
    final imageMetadata = <String, dynamic>{};
    for (final section in _sections) {
      final sectionTitle = section['title'] as String;
      for (final item in section['items'] as List<dynamic>) {
        final uniqueId = _getItemUniqueId(item);
        if (finalItemImages[uniqueId] != null) {
          imageMetadata[uniqueId] = {
            'section': sectionTitle,
            'itemId': _getItemFieldId(item),
          };
        }
      }
    }

    await LocalStorageService.saveInspection(
      data: _buildSubmissionBody(),
      images: finalItemImages,
      imageMetadata: imageMetadata,
      status: 'offline',
      videos: finalItemVideos,
      audios: finalItemAudios,
      files: finalItemFiles,
      multiImages: finalMultiImages,
    );

    // Keep the files. saveInspection copied them into the offline record, but
    // this screen stays open on a failed submit and its in-memory maps (and the
    // working copy) still point at the ORIGINAL paths. Deleting them here left
    // a retry uploading a file that no longer existed — "File not found"
    // forever, including after resume.
    final sid = _effectiveInspectionId;
    if (sid != null) {
      await LocalStorageService.clearMediaQueueFor(sid,
          deleteLocalFiles: false);
    }
  }

  Future<void> _handleSubmission() async {
    if (_isSubmitting) return;

    // Wait for capture-time uploads still in flight. Without this the submit
    // and an in-progress upload of the same file run concurrently: the field
    // still holds a local path, so _uploadRemainingImages starts a SECOND
    // upload of it. A video takes minutes where a photo takes seconds, so the
    // window is wide. Once an inspection is completed the server rejects
    // further writes, which would orphan the late file permanently.
    if (_uploadingImages.value.isNotEmpty) {
      final count = _uploadingImages.value.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(count == 1
              ? 'Still uploading 1 file. Please wait a moment.'
              : 'Still uploading $count files. Please wait a moment.'),
        ),
      );
      return;
    }

    // Block submission until every required field across all sections is filled.
    final missingGroups = _getGroupedRequiredFieldErrors();
    if (missingGroups.isNotEmpty) {
      _showRequiredFieldsSheet(missingGroups);
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      bool hasInternet = await ConnectivityChecker.canReachServer();

      if (!hasInternet) {
        Map<String, String?> finalItemImages = Map.from(itemImages);
        Map<String, String?> finalItemVideos = Map.from(itemVideos);
        Map<String, String?> finalItemAudios = Map.from(itemAudios);
        Map<String, String?> finalItemFiles = Map.from(itemFiles);
        // Filter out null values from multiImages
        Map<String, List<String>> finalMultiImages = {};
        itemMultiImages.forEach((key, value) {
          if (value != null && value.isNotEmpty) {
            finalMultiImages[key] = value;
          }
        });
        final body = _buildSubmissionBody();

        // Build metadata so offline-queued images retain their section/fieldId
        // for the upload step when the device comes back online.
        final imageMetadata = <String, dynamic>{};
        for (final section in _sections) {
          final sectionTitle = section['title'] as String;
          for (final item in section['items'] as List<dynamic>) {
            final uniqueId = _getItemUniqueId(item);
            if (finalItemImages[uniqueId] != null) {
              imageMetadata[uniqueId] = {
                'section': sectionTitle,
                'itemId': _getItemFieldId(item),
              };
            }
          }
        }

        await LocalStorageService.saveInspection(
          data: body,
          images: finalItemImages,
          imageMetadata: imageMetadata,
          status: 'offline',
          videos: finalItemVideos,
          audios: finalItemAudios,
          files: finalItemFiles,
          multiImages: finalMultiImages,
        );
        // The offline record now owns this inspection's media; drop the queue
        // container WITHOUT deleting the files — the offline record references
        // those same paths and still needs them to upload later.
        final sidOffline = _effectiveInspectionId;
        if (sidOffline != null) {
          await LocalStorageService.clearMediaQueueFor(sidOffline,
              deleteLocalFiles: false);
        }
        if (mounted) {
          ref.read(inspectionProvider.notifier).markDirty();
        }

        await _completeInspection();
        await _cleanupCurrentInspection();
        _navigateToLocalInspections(context);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'No internet connection. Inspection saved to pending.')),
          );
        }
        return;
      }

      try {
        // Process 1: upload any still-local media. If any upload fails, abort
        // before building the body — submitting now would POST a local path the
        // server can't resolve and the field would come back empty on resume.
        final failedUploads = await _uploadRemainingImages();
        if (failedUploads.isNotEmpty) {
          if (mounted) {
            setState(() => _isSubmitting = false);
            _showUploadFailedSheet(failedUploads);
          }
          return;
        }
        // Process 2: make sure the draft exists server-side. It is normally
        // created by initialize at the start of the flow; only mint one here for
        // the rare case where submit is reached without an id (e.g. started
        // offline, now online) — the all-at-once create endpoint is gone.
        final serverId =
            _effectiveInspectionId ?? await _ensureServerInspectionId();

        Map<String, dynamic> result;
        if (serverId == null) {
          // No id and couldn't create one — fail through to the offline-save
          // fallback below so nothing is lost; the queue drain finalises later.
          result = {
            'success': false,
            'message': 'Could not reach the server to start the inspection.',
          };
        } else {
          // Process 3: save-step every populated section so the server holds the
          // complete inspection, then finalise with an EMPTY body. The data is
          // already there via save-step, so we never re-POST the whole JSON.
          final failedSections = await _saveAllSectionsToServer(serverId);
          if (failedSections.isNotEmpty) {
            if (mounted) {
              setState(() => _isSubmitting = false);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'Could not save ${failedSections.join(", ")}. Check your connection and try again.'),
                  backgroundColor: Colors.red.shade700,
                ),
              );
            }
            return;
          }
          result = await ApiService.submitInspectionById(serverId, const {});
          log(result.toString());
        }

        if (result['success'] == true) {
          final sid = _effectiveInspectionId;
          if (sid != null) {
            await LocalStorageService.clearMediaQueueFor(sid);
          }
          // Submitted to the server — now safe to delete the local working-copy
          // media files (the queue no longer owns them since drain keeps files).
          await LocalStorageService.deleteLocalMediaFiles([
            ...itemImages.values.whereType<String>(),
            ...itemVideos.values.whereType<String>(),
            ...itemAudios.values.whereType<String>(),
            ...itemFiles.values
                .whereType<String>()
                .map(_filePathFromPayload)
                .whereType<String>(),
            ...itemMultiImages.values
                .whereType<List<String>>()
                .expand((l) => l),
          ]);
          await _completeInspection();
          await _cleanupCurrentInspection();

          if (mounted) {
            // Read defensively. This runs AFTER the queue and local media
            // have been deleted, so a hard cast here turned a submit that had
            // already succeeded server-side into an error snackbar with no way
            // back. Missing fields degrade to the success page without a
            // report link instead of throwing.
            final data = result['data'];
            final Map<String, dynamic> payload =
                data is Map<String, dynamic> ? data : const {};
            if (data != null && data is! Map<String, dynamic>) {
              log('Submit succeeded but `data` was ${data.runtimeType}');
            }
            final redirectUrl = payload['redirect_url']?.toString() ?? '';
            final inspectionId = payload['inspection_id'] is int
                ? payload['inspection_id'] as int
                : int.tryParse(payload['inspection_id']?.toString() ?? '') ?? 0;
            if (redirectUrl.isNotEmpty) {
              await ReportsCacheService.addReport(
                redirectUrl: redirectUrl,
                inspectionId: inspectionId,
              );
            }
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (context) => InspectionSuccessPage(
                  redirectUrl: redirectUrl,
                  inspectionId: inspectionId,
                  uuid: payload['uuid']?.toString() ?? '',
                ),
              ),
              (route) => false,
            );
          }
        } else {
          await _persistSubmissionForRetry();
          if (mounted) {
            ref.read(inspectionProvider.notifier).markDirty();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to submit: ${result['message']}')),
            );
          }
        }
      } catch (apiError) {
        // A THROW here used to only show a snackbar, leaving the inspection
        // saved nowhere: the rejected-response branch above persists it for
        // retry, but an exception skipped that entirely and the inspector's
        // work sat in memory with no queue entry behind it. Persist on both.
        log('Submission threw: $apiError');
        try {
          await _persistSubmissionForRetry();
        } catch (e) {
          log('Could not persist inspection after submission error: $e');
        }
        if (mounted) {
          ref.read(inspectionProvider.notifier).markDirty();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Submission error: $apiError. '
                  'Saved to pending — it will retry automatically.'),
            ),
          );
        }
      }
    } catch (e) {
      log('Error in submission process: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving inspection: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _navigateToLocalInspections(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MainScreen(
          initialIndex: ref.read(userProvider).isAdmin() ? 3 : 2,
        ),
      ),
    );
  }

  void _showFlagIssuesSheet(dynamic item, {bool autoAdvanceOnConfirm = false}) {
    final uniqueId = _getItemUniqueId(item);
    final sectionTitle = _sections[_currentSection]['title'] as String;
    final currentIssues = itemFlaggedIssues[uniqueId] ?? [];
    final currentNotes = itemRemarks[uniqueId] ?? '';

    // For fields that are pure dropdowns (have options, no image/video capture),
    // don't overwrite the dropdown's selected value when flagging issues.
    final isPureDropdownField =
        _itemHasOptions(item) && !_itemHasImage(item) && !_itemHasVideo(item);

    final List<String> availableIssues = [];
    final Map<String, Color> issueColors = {};
    if (item is Map) {
      final opts = item['options'] as List?;
      if (opts != null) {
        for (final opt in opts) {
          final lbl = opt['label']?.toString() ?? '';
          final val = opt['value']?.toString() ?? '';
          final label = lbl.isNotEmpty ? lbl : val;
          if (label.isNotEmpty) {
            availableIssues.add(label);
            final colorCode = opt['colorCode']?.toString() ?? '';
            if (colorCode.isNotEmpty) {
              try {
                final hex = colorCode.startsWith('#')
                    ? colorCode.substring(1)
                    : colorCode;
                issueColors[label] = Color(int.parse('FF$hex', radix: 16));
              } catch (_) {}
            }
          }
        }
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: InspectionFlagIssuesSheet(
          sectionTitle: sectionTitle,
          selectedIssues: currentIssues,
          notes: currentNotes,
          availableIssues: availableIssues,
          issueColors: issueColors.isEmpty ? null : issueColors,
          onConfirm: (issues, notes, markedNoIssues) {
            setState(() {
              _highlightFlagIssues.value = false;
              if (markedNoIssues) {
                itemFlaggedIssues[uniqueId] = [];
                if (!isPureDropdownField) itemValues[uniqueId] = 'no_issues';
              } else {
                itemFlaggedIssues[uniqueId] = issues;
                if (!isPureDropdownField) {
                  itemValues[uniqueId] = issues.isEmpty ? '' : 'flagged';
                }
              }
              if (notes.isNotEmpty) {
                remarksControllers[uniqueId]?.text = notes;
                itemRemarks[uniqueId] = notes;
              }
            });
            _autoSave();
            _saveFieldToServer(item, uniqueId);
            if (autoAdvanceOnConfirm) {
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted) _nextItem();
              });
            }
          },
        ),
      ),
    );
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openEndDrawer();
  }

  PreferredSizeWidget _buildDarkAppBar(Map<String, dynamic> currentSection) {
    final sectionTitle = currentSection['title'] as String;
    final items = currentSection['items'] as List<dynamic>;
    final itemTitle = (items.isNotEmpty && _currentItemIndex < items.length)
        ? (items[_currentItemIndex]['title'] as String? ?? sectionTitle)
        : sectionTitle;
    final subtitle =
        'Field ${_currentItemIndex + 1} out ${items.length} • Section ${_currentSection + 1}/${_sections.length}';

    return AppBar(
      backgroundColor: Colors.black,
      elevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            itemTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white60, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        Center(
          child: InkWell(
            onTap: _showInspectionStatusSheet,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_progressPercent% Complete',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.expand_more,
                      size: 16, color: Colors.white60),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('Stop Inspection?'),
                  content: const Text(
                    'Your progress will be saved and you can continue later.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: _handleClose,
                      child: const Text('Stop'),
                    ),
                  ],
                );
              },
            );
          },
          icon: const Icon(Icons.close, color: Colors.white60, size: 22),
        ),
        IconButton(
          icon: const Icon(Icons.menu, color: Colors.white60, size: 22),
          onPressed: _openDrawer,
        ),
      ],
    );
  }

  Widget _buildDarkNavBar(List<dynamic> items) {
    if (_isReviewingCapture ||
        _isReviewingVideo ||
        _isReviewingAudio ||
        _isReviewingFile) {
      return const SizedBox.shrink();
    }

    final canGoPrevious =
        !_isSubmitting && (_currentItemIndex > 0 || _currentSection > 0);
    final canGoNext = !_isSubmitting && items.isNotEmpty;

    final bool isLast = _currentItemIndex == items.length - 1 &&
        _currentSection == _sections.length - 1;

    return Container(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: canGoPrevious ? _previousItem : null,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Previous'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white30,
                    side: BorderSide(
                      color: canGoPrevious ? Colors.white30 : Colors.white12,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed:
                      canGoNext ? (isLast ? _nextSection : _nextItem) : null,
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: Text(isLast ? 'Finish' : 'Next'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF448AFF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFullscreenReferenceImage(
      List<Map<String, dynamic>> referenceMedia, int initialIndex) {
    showDialog(
      context: context,
      builder: (_) => InspectionReferenceFullscreen(
        mediaList: referenceMedia,
        initialIndex: initialIndex,
      ),
    );
  }

  Widget _buildImageFieldView(dynamic item) {
    final uniqueId = _getItemUniqueId(item);
    final title = _getItemTitle(item);
    final referenceMedia = _getItemReferenceMedia(item);
    final fieldId = _getItemFieldId(item);
    final hasCapturedPhoto = itemImages[uniqueId] != null;
    final hasCapturedVideo = itemVideos[uniqueId] != null;
    final hasAttachedFile = itemFiles[uniqueId] != null;
    final hasRecordedAudio = itemAudios[uniqueId] != null;
    final flaggedIssues = itemFlaggedIssues[uniqueId] ?? [];
    final conditionValue = itemValues[uniqueId] ?? '';
    final refUrl = referenceMedia.isNotEmpty
        ? (referenceMedia.first['url'] as String? ?? '')
        : '';
    final refMediaType = referenceMedia.isNotEmpty
        ? (referenceMedia.first['mediaType'] as String? ?? 'image')
        : 'image';

    // Build the main capture area based on current mode
    Widget captureArea;
    if (_currentCaptureMode == 'PHOTO') {
      if (hasCapturedPhoto) {
        captureArea = GestureDetector(
          onTap: () => _showImagePreview(itemImages[uniqueId]!),
          child: _buildImageWidget(
            itemImages[uniqueId]!,
            fit: BoxFit.cover,
            cacheWidth: (MediaQuery.of(context).size.width *
                    MediaQuery.of(context).devicePixelRatio)
                .round(),
          ),
        );
      } else {
        captureArea = LayoutBuilder(
          builder: (ctx, constraints) => SectionCameraCard(
            key: ValueKey('cam_$uniqueId'),
            height: constraints.maxHeight,
            borderRadius: BorderRadius.zero,
            showControls: false,
            onCaptureReady: (fn) => setState(() => _triggerPhotoCapture = fn),
            onEnlargeReady: (fn) => setState(() => _triggerEnlarge = fn),
            onFlashReady: (fn) => setState(() => _triggerFlashToggle = fn),
            onPickFromGallery: () =>
                _pickImage(ImageSource.gallery, uniqueId, fieldId),
            onCapture: (XFile file) {
              setState(() {
                _pendingCapturedXFile = file;
                _pendingCapturedUniqueId = uniqueId;
                _isReviewingCapture = true;
              });
            },
          ),
        );
      }
    } else if (_currentCaptureMode == 'VIDEO') {
      if (hasCapturedVideo) {
        captureArea = InspectionVideoPlayer(
          key: ValueKey('vplay_$uniqueId'),
          videoPath: itemVideos[uniqueId]!,
          rotationQuarterTurns: itemVideoRotations[uniqueId] ?? 0,
          onReRecord: () => _showVideoPickerOptions(item),
          onDiscard: () => _discardAllMedia(item),
        );
      } else {
        captureArea = LayoutBuilder(
          builder: (ctx, constraints) => SectionVideoCameraCard(
            key: ValueKey('vid_$uniqueId'),
            height: constraints.maxHeight,
            borderRadius: BorderRadius.zero,
            showControls: false,
            onRecordingToggleReady: (fn) =>
                setState(() => _triggerVideoToggle = fn),
            onPauseResumeReady: (fn) =>
                setState(() => _triggerVideoPauseResume = fn),
            onFlashToggleReady: (fn) =>
                setState(() => _triggerFlashToggle = fn),
            onRecordingChanged: (recording) {
              // Notifier-only: rebuilds just the overlay via ListenableBuilder.
              _captureUi.isVideoRecording.value = recording;
              if (!recording) _captureUi.isVideoPaused.value = false;
            },
            onRecordingPausedChanged: (paused) =>
                _captureUi.isVideoPaused.value = paused,
            onPickFromGallery: () => _pickVideo(item, ImageSource.gallery),
            onCapture: (XFile file) {
              setState(() {
                _pendingCapturedVideoFile = file;
                _pendingCapturedVideoUniqueId = uniqueId;
                _isReviewingVideo = true;
                _captureUi.isVideoRecording.value = false;
                _captureUi.isVideoPaused.value = false;
              });
            },
          ),
        );
      }
    } else if (_currentCaptureMode == 'FILE') {
      if (hasAttachedFile) {
        // File attached — show info on dark background
        captureArea = Container(
          color: const Color(0xFF111111),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.insert_drive_file,
                      color: Color(0xFF4D9EFF), size: 64),
                  const SizedBox(height: 14),
                  Text(
                    _extractFileName(itemFiles[uniqueId]!),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        );
      } else {
        // No file — clean dark bg with faint icon; action button is in panel
        captureArea = Container(
          color: const Color(0xFF111111),
          child: Center(
            child: Icon(Icons.attach_file,
                color: Colors.white.withValues(alpha: 0.06), size: 120),
          ),
        );
      }
    } else {
      // AUDIO mode
      if (hasRecordedAudio) {
        captureArea = InspectionVideoPlayer(
          key: ValueKey('aplay_$uniqueId'),
          videoPath: itemAudios[uniqueId]!,
          onReRecord: () {
            setState(() => itemAudios[uniqueId] = null);
            _showAudioPickerOptions(item);
          },
          onDiscard: () => _discardAllMedia(item),
        );
      } else if (_isRecordingAudio) {
        captureArea = Container(
          color: const Color(0xFF111111),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.red, width: 2),
                  ),
                  child: const Icon(Icons.mic, color: Colors.red, size: 32),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.circle, color: Colors.red, size: 8),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<Duration>(
                      valueListenable: _audioElapsed,
                      builder: (context, elapsed, _) => Text(
                        _formatAudioDuration(elapsed),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text('Recording...',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
        );
      } else {
        // No audio — faint bg + browse button
        captureArea = Container(
          color: const Color(0xFF111111),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mic_outlined,
                    color: Colors.white.withValues(alpha: 0.06), size: 120),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () => _pickAudio(item),
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: const Text('Browse audio files'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white60,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    // Show action row for any mode that has no media yet
    final bool showCameraRow =
        (_currentCaptureMode == 'PHOTO' && !hasCapturedPhoto) ||
            (_currentCaptureMode == 'VIDEO' && !hasCapturedVideo) ||
            (_currentCaptureMode == 'FILE' && !hasAttachedFile) ||
            (_currentCaptureMode == 'AUDIO' && !hasRecordedAudio);

    // Condition chip colours
    final Color condColor = conditionValue == 'no_issues'
        ? Colors.green
        : conditionValue == 'flagged'
            ? Colors.red
            : Colors.white54;
    final IconData condIcon = conditionValue == 'no_issues'
        ? Icons.check_circle_outline
        : conditionValue == 'flagged'
            ? Icons.flag_outlined
            : Icons.radio_button_unchecked;
    final String condLabel = conditionValue == 'flagged'
        ? '${flaggedIssues.length} issue${flaggedIssues.length == 1 ? '' : 's'} flagged'
        : 'No issues — looks good';

    // Only the camera overlay/controls depend on the transient capture flags
    // (flash / recording / paused), so a ListenableBuilder rebuilds just this
    // subtree when they change — captureArea (the live camera) is built above
    // and reused, and the rest of the screen is untouched.
    return ListenableBuilder(
      listenable: _captureUi.listenable,
      builder: (context, _) => Column(
        children: [
          // ── Capture area ──────────────────────────────────────────
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                captureArea,

                // Reference thumbnail (PHOTO / VIDEO only, top-left)
                if (refUrl.isNotEmpty &&
                    _currentCaptureMode != 'FILE' &&
                    _currentCaptureMode != 'AUDIO')
                  Positioned(
                    top: 12,
                    left: 12,
                    child: GestureDetector(
                      onTap: () =>
                          _showFullscreenReferenceImage(referenceMedia, 0),
                      child: Container(
                        width: 100,
                        height: 75,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color:
                                const Color(0xFFFF6B6B).withValues(alpha: 0.8),
                            width: 2,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (refMediaType == 'video')
                                Container(
                                  color: Colors.black87,
                                  child: const Center(
                                    child: Icon(
                                      Icons.play_circle_filled,
                                      color: Colors.white70,
                                      size: 32,
                                    ),
                                  ),
                                )
                              else
                                // Cache-aware so the guide thumbnail still shows
                                // from disk when the inspector is offline (plain
                                // Image.network would fail and leave it blank).
                                CachedReferenceImage(
                                  url: refUrl,
                                  fit: BoxFit.cover,
                                  // 100×75 dp container; 2× for retina.
                                  cacheWidth: 200,
                                  cacheHeight: 150,
                                ),
                              Positioned(
                                bottom: 2,
                                left: 0,
                                right: 0,
                                child: Container(
                                  color: Colors.black54,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 2),
                                  child: const Text(
                                    'REF',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // Recording indicator (VIDEO recording, top-right)
                if (_currentCaptureMode == 'VIDEO' &&
                    _captureUi.isVideoRecording.value)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _captureUi.isVideoPaused.value
                                ? Icons.pause
                                : Icons.circle,
                            color: _captureUi.isVideoPaused.value
                                ? Colors.amber
                                : Colors.red,
                            size: 8,
                          ),
                          const SizedBox(width: 5),
                          Text(
                              _captureUi.isVideoPaused.value ? 'PAUSED' : 'REC',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),

                // Enlarge button (PHOTO, camera active, top-right)
                if (!hasCapturedPhoto && _currentCaptureMode == 'PHOTO')
                  Positioned(
                    top: 12,
                    right: 12,
                    child: GestureDetector(
                      onTap: _triggerEnlarge,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Icon(
                          Icons.open_in_full,
                          color: _triggerEnlarge != null
                              ? Colors.white70
                              : Colors.white24,
                          size: 18,
                        ),
                      ),
                    ),
                  ),

                // Retake badge (PHOTO captured, top-right)
                if (hasCapturedPhoto && _currentCaptureMode == 'PHOTO')
                  Positioned(
                    top: 12,
                    right: 12,
                    child: GestureDetector(
                      onTap: () => _showImagePickerOptions(item),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white30),
                        ),
                        child: ValueListenableBuilder<Set<String>>(
                          valueListenable: _uploadingImages,
                          builder: (context, uploading, _) {
                            final uploadingNow = uploading.contains(uniqueId);
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (uploadingNow) ...[
                                  const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  ),
                                  const SizedBox(width: 6),
                                  ValueListenableBuilder<
                                      Map<String, MediaFileProgress>>(
                                    valueListenable: _uploadProgress,
                                    builder: (context, progress, _) => Text(
                                      // No rate here: the chip sits over the
                                      // camera preview and has no room for it.
                                      uploadBadgeLabel(progress[uniqueId],
                                          withRate: false),
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 12),
                                    ),
                                  ),
                                ] else ...[
                                  const Icon(Icons.refresh,
                                      color: Colors.white, size: 14),
                                  const SizedBox(width: 4),
                                  const Text('Retake',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                // Replace badge (FILE attached, top-right)
                if (hasAttachedFile && _currentCaptureMode == 'FILE')
                  Positioned(
                    top: 12,
                    right: 12,
                    child: GestureDetector(
                      onTap: () => _showFilePickerOptions(item),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white30),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.swap_horiz,
                                color: Colors.white, size: 14),
                            SizedBox(width: 4),
                            Text('Replace',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Condition chip overlay (bottom of capture area)
                Positioned(
                  bottom: 10,
                  left: 12,
                  right: 12,
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _showFlagIssuesSheet(item,
                              autoAdvanceOnConfirm: true),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: condColor.withValues(alpha: 0.6)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(condIcon, size: 13, color: condColor),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    condLabel,
                                    style: TextStyle(
                                      color: condColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          _highlightFlagIssues.value = false;
                          _showFlagIssuesSheet(item,
                              autoAdvanceOnConfirm: true);
                        },
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _highlightFlagIssues,
                          builder: (context, highlight, _) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: highlight
                                  ? Colors.orange.withValues(alpha: 0.2)
                                  : Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: highlight
                                      ? Colors.orange
                                      : Colors.white24),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.flag_outlined,
                                    size: 13,
                                    color: highlight
                                        ? Colors.orange
                                        : Colors.white70),
                                const SizedBox(width: 4),
                                Text('Flag Issue',
                                    style: TextStyle(
                                        color: highlight
                                            ? Colors.orange
                                            : Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Bottom control panel ───────────────────────────────────
          Container(
            color: const Color(0xFF0D0D0D),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Instruction text
                  Text(
                    _currentCaptureMode == 'VIDEO'
                        ? 'Record a video of: $title'
                        : _currentCaptureMode == 'FILE'
                            ? 'Attach a document for: $title'
                            : _currentCaptureMode == 'AUDIO'
                                ? 'Add an audio note for: $title'
                                : 'Take a clear photo of: $title',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),

                  // Mode tabs — text + underline only
                  Row(
                    children: ['FILE', 'PHOTO', 'VIDEO', 'AUDIO'].map((mode) {
                      final isSelected = mode == _currentCaptureMode;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () {
                            if (!isSelected) {
                              _audioTimer?.cancel();
                              _audioTimer = null;
                              _audioRecorder?.stop().then((_) {
                                _audioRecorder?.dispose();
                                _audioRecorder = null;
                              });
                              setState(() {
                                _currentCaptureMode = mode;
                                _triggerPhotoCapture = null;
                                _triggerEnlarge = null;
                                _triggerFlashToggle = null;
                                _captureUi.flashOn.value = false;
                                _triggerVideoToggle = null;
                                _triggerVideoPauseResume = null;
                                _captureUi.isVideoRecording.value = false;
                                _captureUi.isVideoPaused.value = false;
                                _isRecordingAudio = false;
                                _audioElapsed.value = Duration.zero;
                              });
                            }
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                mode,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white38,
                                  fontSize: 11,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              ),
                              const SizedBox(height: 4),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                height: 2,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF4D9EFF)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  // Action row — shown for all modes when no media captured yet
                  if (showCameraRow) ...[
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Left slot: pause/resume while recording, otherwise
                        // gallery (PHOTO/VIDEO) or spacer (FILE/AUDIO)
                        if (_currentCaptureMode == 'VIDEO' &&
                            _captureUi.isVideoRecording.value)
                          GestureDetector(
                            onTap: _triggerVideoPauseResume,
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _triggerVideoPauseResume != null
                                      ? Colors.white54
                                      : Colors.white24,
                                ),
                              ),
                              child: Icon(
                                _captureUi.isVideoPaused.value
                                    ? Icons.play_arrow
                                    : Icons.pause,
                                color: _triggerVideoPauseResume != null
                                    ? Colors.white
                                    : Colors.white38,
                                size: 24,
                              ),
                            ),
                          )
                        else if (_currentCaptureMode == 'PHOTO' ||
                            _currentCaptureMode == 'VIDEO')
                          GestureDetector(
                            onTap: () => _currentCaptureMode == 'VIDEO'
                                ? _pickVideo(item, ImageSource.gallery)
                                : _pickImage(
                                    ImageSource.gallery, uniqueId, fieldId),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Icon(
                                _currentCaptureMode == 'VIDEO'
                                    ? Icons.video_library_outlined
                                    : Icons.photo_library_outlined,
                                color: Colors.white70,
                                size: 22,
                              ),
                            ),
                          )
                        else
                          const SizedBox(width: 46, height: 46),

                        // Centre: main action button for each mode
                        if (_currentCaptureMode == 'PHOTO')
                          // Shutter ring
                          GestureDetector(
                            onTap: _triggerPhotoCapture,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 3),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: _triggerPhotoCapture != null
                                        ? Colors.white
                                        : Colors.white38,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else if (_currentCaptureMode == 'VIDEO')
                          // Record ring → square stop
                          GestureDetector(
                            onTap: _triggerVideoToggle,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _captureUi.isVideoRecording.value
                                      ? Colors.red
                                      : Colors.white,
                                  width: 3,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  decoration: BoxDecoration(
                                    color: _captureUi.isVideoRecording.value
                                        ? Colors.red
                                        : (_triggerVideoToggle != null
                                            ? Colors.white
                                            : Colors.white38),
                                    borderRadius: BorderRadius.circular(
                                        _captureUi.isVideoRecording.value
                                            ? 4
                                            : 40),
                                  ),
                                ),
                              ),
                            ),
                          )
                        else if (_currentCaptureMode == 'FILE')
                          // Attach button
                          GestureDetector(
                            onTap: () => _showFilePickerOptions(item),
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF4D9EFF)
                                    .withValues(alpha: 0.15),
                                border: Border.all(
                                    color: const Color(0xFF4D9EFF), width: 2.5),
                              ),
                              child: const Icon(Icons.attach_file,
                                  color: Color(0xFF4D9EFF), size: 30),
                            ),
                          )
                        else
                          // AUDIO: toggle recording
                          GestureDetector(
                            onTap: () => _isRecordingAudio
                                ? _stopAudioRecording(item)
                                : _startAudioRecording(item),
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isRecordingAudio
                                    ? Colors.red.withValues(alpha: 0.15)
                                    : const Color(0xFFEC4899)
                                        .withValues(alpha: 0.15),
                                border: Border.all(
                                  color: _isRecordingAudio
                                      ? Colors.red
                                      : const Color(0xFFEC4899),
                                  width: 2.5,
                                ),
                              ),
                              child: Icon(
                                _isRecordingAudio ? Icons.stop : Icons.mic,
                                color: _isRecordingAudio
                                    ? Colors.red
                                    : const Color(0xFFEC4899),
                                size: 30,
                              ),
                            ),
                          ),

                        // Right slot: flash (PHOTO / VIDEO) or spacer
                        if (_currentCaptureMode == 'PHOTO' ||
                            _currentCaptureMode == 'VIDEO')
                          GestureDetector(
                            onTap: _triggerFlashToggle != null
                                ? () {
                                    _triggerFlashToggle!();
                                    _captureUi.flashOn.value =
                                        !_captureUi.flashOn.value;
                                  }
                                : null,
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: _captureUi.flashOn.value
                                    ? const Color(0xFFFFC107)
                                    : Colors.white.withValues(alpha: 0.1),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _captureUi.flashOn.value
                                      ? const Color(0xFFFFC107)
                                      : Colors.white24,
                                ),
                              ),
                              child: Icon(
                                _captureUi.flashOn.value
                                    ? Icons.flash_on
                                    : Icons.flash_off,
                                color: _captureUi.flashOn.value
                                    ? Colors.black87
                                    : (_triggerFlashToggle != null
                                        ? Colors.white70
                                        : Colors.white24),
                                size: 22,
                              ),
                            ),
                          )
                        else
                          const SizedBox(width: 46, height: 46),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ] else ...[
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Show loading while template is being initialized
    if (_isLoadingTemplate) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator.adaptive(),
              SizedBox(height: 16),
              Text('Loading inspection template...'),
            ],
          ),
        ),
      );
    }

    // Handle empty sections case
    if (_sections.isEmpty) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline,
                      size: 64, color: Colors.orange),
                  const SizedBox(height: 16),
                  Text(
                    'Could not load inspection form',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Connect to the internet, then go back and open the inspection again. '
                    'If you were resuming a saved inspection, your answers stay on this device once the form loads.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go back'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final currentSection = _sections[_currentSection];
    final items = currentSection['items'] as List<dynamic>;
    final currentItem = items.isNotEmpty ? items[_currentItemIndex] : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) async {
        if (didPop) return;

        final bool shouldClose = await showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('Stop Inspection?'),
                  content: const Text(
                    'Your progress will be saved and you can continue later. Do you want to stop?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Stop'),
                    ),
                  ],
                );
              },
            ) ??
            false;

        if (shouldClose) {
          await _saveDataLocally();
          await _commitPendingMediaToQueue();
          if (mounted) {
            ref.read(inspectionProvider.notifier).markDirty();
            unawaited(
                ref.read(inspectionProvider.notifier).refreshMediaQueue());
          }
          if (!mounted) return;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: Colors.black,
        appBar: _buildDarkAppBar(currentSection),
        endDrawer: _buildDrawer(),
        body: Column(
          children: [
            // Reference-media caching progress — shown only while images are
            // being downloaded/revalidated, hidden once complete.
            ValueListenableBuilder<ReferenceCacheProgress?>(
              valueListenable: ReferenceMediaCache.progress,
              builder: (context, p, _) {
                if (p == null || p.isComplete) {
                  return const SizedBox.shrink();
                }
                return Container(
                  width: double.infinity,
                  color: const Color(0xFF1E1E1E),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF448AFF),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Caching reference media ${p.done}/${p.total}',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              value: p.fraction,
                              minHeight: 3,
                              backgroundColor: Colors.white12,
                              color: const Color(0xFF448AFF),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            // Thin progress bar
            LinearProgressIndicator(
              value: _totalFields > 0 ? _processedFields / _totalFields : 0.0,
              minHeight: 3,
              backgroundColor: Colors.white12,
              color: const Color(0xFF448AFF),
            ),
            Expanded(
              child: _isReviewingFile &&
                      _pendingCapturedFilePath != null &&
                      _pendingCapturedFileName != null
                  ? InspectionFileReview(
                      fileName: _pendingCapturedFileName!,
                      fileExtension: _pendingCapturedFileExtension ?? '',
                      fieldTitle:
                          currentItem != null ? _getItemTitle(currentItem) : '',
                      onPickAgain: () {
                        setState(() {
                          _isReviewingFile = false;
                          _pendingCapturedFilePath = null;
                          _pendingCapturedFileUniqueId = null;
                          _pendingCapturedFileName = null;
                          _pendingCapturedFileExtension = null;
                        });
                      },
                      onUseFile: _acceptCapturedFile,
                    )
                  : _isReviewingVideo && _pendingCapturedVideoFile != null
                      ? InspectionVideoReview(
                          key: ValueKey(_pendingCapturedVideoFile!.path),
                          capturedMediaPath: _pendingCapturedVideoFile!.path,
                          fieldTitle: currentItem != null
                              ? _getItemTitle(currentItem)
                              : '',
                          referenceMedia: currentItem != null
                              ? _getItemReferenceMedia(currentItem)
                              : const [],
                          mediaLabel: 'Video',
                          onRetake: () {
                            setState(() {
                              _isReviewingVideo = false;
                              _pendingCapturedVideoFile = null;
                              _pendingCapturedVideoUniqueId = null;
                            });
                          },
                          onUseMedia: (int quarterTurns) =>
                              _acceptCapturedVideo(quarterTurns),
                        )
                      : _isReviewingAudio && _pendingCapturedAudioPath != null
                          ? InspectionVideoReview(
                              key: ValueKey(_pendingCapturedAudioPath!),
                              capturedMediaPath: _pendingCapturedAudioPath!,
                              fieldTitle: currentItem != null
                                  ? _getItemTitle(currentItem)
                                  : '',
                              referenceMedia: currentItem != null
                                  ? _getItemReferenceMedia(currentItem)
                                  : const [],
                              mediaLabel: 'Audio',
                              onRetake: () {
                                setState(() {
                                  _isReviewingAudio = false;
                                  _pendingCapturedAudioPath = null;
                                  _pendingCapturedAudioUniqueId = null;
                                });
                              },
                              onUseMedia: (_) => _acceptCapturedAudio(),
                            )
                          : _isReviewingCapture && _pendingCapturedXFile != null
                              ? InspectionImageReview(
                                  key: ValueKey(_pendingCapturedXFile!.path),
                                  capturedImagePath:
                                      _pendingCapturedXFile!.path,
                                  fieldTitle: currentItem != null
                                      ? _getItemTitle(currentItem)
                                      : '',
                                  referenceMedia: currentItem != null
                                      ? _getItemReferenceMedia(currentItem)
                                      : [],
                                  onRetake: () {
                                    setState(() {
                                      _isReviewingCapture = false;
                                      _pendingCapturedXFile = null;
                                      _pendingCapturedUniqueId = null;
                                    });
                                  },
                                  onUsePhoto: (int quarterTurns) =>
                                      _acceptCapturedImage(quarterTurns),
                                )
                              : currentItem != null &&
                                      (_itemHasImage(currentItem) ||
                                          _itemHasVideo(currentItem))
                                  ? _buildImageFieldView(currentItem)
                                  : ListView(
                                      key: PageStorageKey<int>(_currentSection),
                                      controller: _scrollController,
                                      children: [
                                        _buildInspectionSection(
                                          currentSection['title'],
                                          items,
                                        ),
                                      ],
                                    ),
            ),
            _buildDarkNavBar(items),
          ],
        ),
      ),
    );
  }

  bool _isFieldFilled(int sectionIndex, int fieldIndex) {
    if (sectionIndex >= _sections.length) return false;
    final items = _sections[sectionIndex]['items'] as List<dynamic>;
    if (fieldIndex >= items.length) return false;

    final item = items[fieldIndex];
    final uniqueId = _getItemUniqueId(item);

    if (itemImages[uniqueId]?.isNotEmpty == true) return true;
    if (itemMultiImages[uniqueId]?.isNotEmpty == true) return true;
    if (itemVideos[uniqueId]?.isNotEmpty == true) return true;
    if (itemAudios[uniqueId]?.isNotEmpty == true) return true;
    if (itemFiles[uniqueId]?.isNotEmpty == true) return true;
    if (itemRemarks[uniqueId]?.isNotEmpty == true) return true;
    final val = itemValues[uniqueId];
    if (val != null && val.isNotEmpty && val != 'N/A') return true;

    return false;
  }

  bool _isSectionComplete(int sectionIndex) {
    if (sectionIndex >= _sections.length) return false;

    final section = _sections[sectionIndex];
    final items = section['items'] as List<dynamic>;

    for (var item in items) {
      final uniqueId = _getItemUniqueId(item);

      if (_itemHasImage(item)) {
        if (itemImages[uniqueId] == null || itemImages[uniqueId]!.isEmpty) {
          return false;
        }
      }

      if (_itemUsesTextField(item)) {
        final value = itemValues[uniqueId] ?? '';
        if (value.trim().isEmpty) {
          return false;
        }
      }

      if (_itemHasOptions(item)) {
        final value = itemValues[uniqueId] ?? 'N/A';
        if (value == 'N/A' || value.isEmpty) {
          return false;
        }
      }
    }

    return true;
  }

  Widget _buildDrawer() {
    return InspectionSectionsDrawer(
      sections: _sections,
      currentSection: _currentSection,
      isSectionComplete: _isSectionComplete,
      isFieldFilled: _isFieldFilled,
      getSectionIcon: _getSectionIcon,
      onSelectSection: (index) => _navigateToField(index, 0),
      onSelectField: (sectionIndex, fieldIndex) =>
          _navigateToField(sectionIndex, fieldIndex),
    );
  }

  void _navigateToField(int sectionIndex, int fieldIndex) {
    final sectionItems = _sections[sectionIndex]['items'] as List<dynamic>;
    final clampedField = fieldIndex.clamp(0, sectionItems.length - 1);
    final targetItem =
        sectionItems.isNotEmpty ? sectionItems[clampedField] : null;

    // Moving to a different section — flush the current one's pending edits.
    if (sectionIndex != _currentSection) _flushDirtySectionsToServer();

    setState(() {
      _currentSection = sectionIndex;
      _currentItemIndex = clampedField;
      _captureUi.isVideoRecording.value = false;
      _captureUi.isVideoPaused.value = false;
      _isRecordingAudio = false;
      _triggerPhotoCapture = null;
      _triggerEnlarge = null;
      _triggerFlashToggle = null;
      _captureUi.flashOn.value = false;
      _triggerVideoToggle = null;
      _triggerVideoPauseResume = null;
      if (targetItem != null) {
        _currentCaptureMode = _defaultCaptureModeForItem(targetItem);
      }
    });

    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    Navigator.pop(context);
  }

  void _cleanupControllers() {
    for (var controller in remarksControllers.values) {
      controller.dispose();
    }
    for (var controller in textFieldControllers.values) {
      controller.dispose();
    }
    remarksControllers.clear();
    textFieldControllers.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveDebouncer?.cancel();
    if (!_sessionCompleted) {
      _flushPendingAutoSave();
      // Persist any still-local media so an interrupted upload auto-syncs later.
      unawaited(_commitPendingMediaToQueue());
    }
    if (!_sessionCompleted) {
      // ref is not guaranteed to be valid during dispose() in Riverpod — guard it.
      try {
        ref.read(inspectionSessionProvider.notifier).saveSnapshot(
              InspectionSessionSnapshot(
                itemImages: Map.from(itemImages),
                itemVideos: Map.from(itemVideos),
                itemAudios: Map.from(itemAudios),
                itemFiles: Map.from(itemFiles),
                itemRemarks: Map.from(itemRemarks),
                itemValues: Map.from(itemValues),
                itemMultiImages: Map.from(itemMultiImages),
                itemFlaggedIssues: Map.from(itemFlaggedIssues),
                currentSection: _currentSection,
                currentItemIndex: _currentItemIndex,
                vehicleDetails: vehicleDetails,
                inspectionTemplate: _inspectionTemplate,
                useDynamicTemplate: _useDynamicTemplate,
                sessionInspectionId: _sessionInspectionId,
              ),
            );
      } on StateError catch (_) {
        // ref was already invalidated (Riverpod container disposed);
        // session data persisted to Hive via _flushPendingAutoSave.
      }
    }
    _scrollController.dispose();
    _cleanupControllers();
    _isSubmitting = false;
    _audioTimer?.cancel();
    if (_isRecordingAudio) {
      _audioRecorder?.stop();
    }
    _audioRecorder?.dispose();
    _audioElapsed.dispose();
    _uploadingImages.dispose();
    _uploadProgress.dispose();
    _highlightFlagIssues.dispose();
    _highlightMissingFieldId.dispose();
    _captureUi.dispose();
    super.dispose();
  }

  void _handleClose() async {
    // Capture the Navigator before any await so we never reach for a defunct
    // context or touch the Navigator while it is mid-transition.
    final navigator = Navigator.of(context);

    // Persisting + queueing is best-effort: Hive keeps the data in memory and
    // it re-syncs on reconnect, so a failure here must not strand the user on
    // the inspection screen. Previously a thrown error (e.g. "No element")
    // skipped the pop and left the user tapping close repeatedly, which
    // compounded into a corrupted Navigator.
    try {
      await _saveDataLocally();
      await _commitPendingMediaToQueue();
      if (mounted) {
        ref.read(inspectionProvider.notifier).markDirty();
        // Surface the just-queued media in the Pending tab and start syncing.
        unawaited(ref.read(inspectionProvider.notifier).refreshMediaQueue());
      }
    } catch (e) {
      debugPrint('Error handling close: $e');
    }

    if (!mounted) return;
    // Single pop: the vehicle-details route is pushReplacement'd away before
    // this screen, so the inspection sits exactly one level above its origin
    // (same as the system-back handler). Popping twice removed the origin too
    // and threw '!_debugLocked' / "No element" navigator assertions.
    if (navigator.canPop()) navigator.pop();
  }
}
