// lib/models/inspection_template_model.dart

class InspectionTemplate {
  final int id;
  final String name;
  final String displayName;
  final String description;
  final String? countryCode;
  final bool hasGovernmentApi;
  final String? governmentApiType;

  InspectionTemplate({
    required this.id,
    required this.name,
    required this.displayName,
    required this.description,
    this.countryCode,
    required this.hasGovernmentApi,
    this.governmentApiType,
  });

  factory InspectionTemplate.fromJson(Map<String, dynamic> json) {
    return InspectionTemplate(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      displayName: json['display_name'] ?? '',
      description: json['description'] ?? '',
      countryCode: json['country_code'],
      hasGovernmentApi: json['has_government_api'] ?? false,
      governmentApiType: json['government_api_type'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'display_name': displayName,
      'description': description,
      'country_code': countryCode,
      'has_government_api': hasGovernmentApi,
      'government_api_type': governmentApiType,
    };
  }
}

class VehicleInfo {
  final String brand;
  final String model;
  final String category;
  final String? year;
  final String? variant;
  final String? colour;
  final String? transmission;
  final String? regNo;

  VehicleInfo({
    required this.brand,
    required this.model,
    required this.category,
    this.year,
    this.variant,
    this.colour,
    this.transmission,
    this.regNo,
  });

  factory VehicleInfo.fromJson(Map<String, dynamic> json) {
    // Server may return "color" or "colour"
    final colourRaw = (json['colour'] ?? json['color'])?.toString();
    // Normalise transmission to title-case (e.g. "MANUAL" → "Manual")
    final txRaw = json['transmission']?.toString();
    final transmission = txRaw != null && txRaw.isNotEmpty
        ? txRaw[0].toUpperCase() + txRaw.substring(1).toLowerCase()
        : null;
    // Server may return "registration_number", "regno" or "regNo"
    final regNoRaw =
        (json['registration_number'] ?? json['regno'] ?? json['regNo'])
            ?.toString();
    return VehicleInfo(
      brand: json['brand'] ?? '',
      model: json['model'] ?? '',
      category: json['category'] ?? '',
      year: json['year']?.toString(),
      variant: json['variant']?.toString(),
      colour: colourRaw,
      transmission: transmission,
      regNo: regNoRaw,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'brand': brand,
      'model': model,
      'category': category,
      if (year != null) 'year': year,
      if (variant != null) 'variant': variant,
      if (colour != null) 'colour': colour,
      if (transmission != null) 'transmission': transmission,
      if (regNo != null) 'registration_number': regNo,
    };
  }
}

class InspectionField {
  final int id;
  final String fieldId;
  final String title;
  final String fieldType;
  final bool isRequired;
  final bool hasRemarks;
  final bool hasImage;
  final bool hasVideo;
  final bool hasFile;
  final bool hasMultipleImages;
  final int order;
  final Map<String, dynamic>? metadata;
  final List<DropdownOption> options;
  final List<ReferenceMedia> referenceMedia;

  // Pre-filled values from /resume or /initialize response.
  final String? initialValue;
  final String? initialRemarks;
  final String? initialImage;
  final List<String>? initialMultiImages;
  final String? initialVideo;
  final String? initialAudio;
  final String? initialFile;

  InspectionField({
    required this.id,
    required this.fieldId,
    required this.title,
    required this.fieldType,
    required this.isRequired,
    required this.hasRemarks,
    required this.hasImage,
    required this.hasVideo,
    required this.hasFile,
    required this.hasMultipleImages,
    required this.order,
    this.metadata,
    required this.options,
    required this.referenceMedia,
    this.initialValue,
    this.initialRemarks,
    this.initialImage,
    this.initialMultiImages,
    this.initialVideo,
    this.initialAudio,
    this.initialFile,
  });

  static String? _asString(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  factory InspectionField.fromJson(Map<String, dynamic> json) {
    final rawMultiImages = json['initial_multi_images'];
    List<String>? multiImages;
    if (rawMultiImages is List && rawMultiImages.isNotEmpty) {
      multiImages = rawMultiImages.map((e) => e.toString()).toList();
    }

    return InspectionField(
      id: json['id'] ?? 0,
      fieldId: json['field_id'] ?? '',
      title: json['title'] ?? '',
      fieldType: json['field_type'] ?? 'text',
      isRequired: json['is_required'] ?? false,
      hasRemarks: json['has_remarks'] ?? false,
      hasImage: json['has_image'] ?? false,
      hasVideo: json['has_video'] ?? false,
      hasFile: json['has_file'] ?? false,
      hasMultipleImages: json['has_multiple_images'] ?? false,
      order: json['order'] ?? 0,
      metadata: json['metadata'],
      options: (json['options'] as List<dynamic>?)
              ?.map((e) => DropdownOption.fromJson(e))
              .toList() ??
          [],
      referenceMedia: (json['reference_media'] as List<dynamic>?)
              ?.map((e) => ReferenceMedia.fromJson(e))
              .toList() ??
          [],
      initialValue: _asString(json['initial_value']),
      initialRemarks: _asString(json['initial_remarks']),
      initialImage: _asString(json['initial_image'] is Map
          ? (json['initial_image'] as Map)['url']
          : json['initial_image']),
      initialMultiImages: multiImages,
      initialVideo: _asString(json['initial_video'] is Map
          ? (json['initial_video'] as Map)['url']
          : json['initial_video']),
      initialAudio: _asString(json['initial_audio'] is Map
          ? (json['initial_audio'] as Map)['url']
          : json['initial_audio']),
      initialFile: _asString(json['initial_file'] is Map
          ? (json['initial_file'] as Map)['url']
          : json['initial_file']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'field_id': fieldId,
      'title': title,
      'field_type': fieldType,
      'is_required': isRequired,
      'has_remarks': hasRemarks,
      'has_image': hasImage,
      'has_video': hasVideo,
      'has_file': hasFile,
      'has_multiple_images': hasMultipleImages,
      'order': order,
      'metadata': metadata,
      'options': options.map((e) => e.toJson()).toList(),
      'reference_media': referenceMedia.map((e) => e.toJson()).toList(),
      if (initialValue != null) 'initial_value': initialValue,
      if (initialRemarks != null) 'initial_remarks': initialRemarks,
      if (initialImage != null) 'initial_image': initialImage,
      if (initialMultiImages != null) 'initial_multi_images': initialMultiImages,
      if (initialVideo != null) 'initial_video': initialVideo,
      if (initialAudio != null) 'initial_audio': initialAudio,
      if (initialFile != null) 'initial_file': initialFile,
    };
  }
}

class DropdownOption {
  final int id;
  final String value;
  final String label;
  final String colorName;
  final String colorCode;
  final int order;

  DropdownOption({
    required this.id,
    required this.value,
    required this.label,
    required this.colorName,
    required this.colorCode,
    required this.order,
  });

  factory DropdownOption.fromJson(Map<String, dynamic> json) {
    return DropdownOption(
      id: json['id'] ?? 0,
      value: json['value'] ?? '',
      label: json['label'] ?? '',
      colorName: json['color_name'] ?? '',
      colorCode: json['color_code'] ?? '#000000',
      order: json['order'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'value': value,
      'label': label,
      'color_name': colorName,
      'color_code': colorCode,
      'order': order,
    };
  }
}

class ReferenceMedia {
  final int id;
  final String mediaType;
  final String filePath;
  final String url;
  final String? description;
  final int order;

  ReferenceMedia({
    required this.id,
    required this.mediaType,
    required this.filePath,
    required this.url,
    this.description,
    required this.order,
  });

  factory ReferenceMedia.fromJson(Map<String, dynamic> json) {
    return ReferenceMedia(
      id: json['id'] ?? 0,
      mediaType: json['media_type'] ?? json['type'] ?? '',
      filePath: json['file_path'] ?? '',
      url: json['url'] ?? '',
      description: json['description'],
      order: json['order'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'media_type': mediaType,
      'file_path': filePath,
      'url': url,
      'description': description,
      'order': order,
    };
  }
}

class InspectionSection {
  final int id;
  final String name;
  final String title;
  final String? description;
  final int order;
  final List<InspectionField> fields;

  InspectionSection({
    required this.id,
    required this.name,
    required this.title,
    this.description,
    required this.order,
    required this.fields,
  });

  factory InspectionSection.fromJson(Map<String, dynamic> json) {
    return InspectionSection(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      title: json['title'] ?? '',
      description: json['description'],
      order: json['order'] ?? 0,
      fields: (json['fields'] as List<dynamic>?)
              ?.map((e) => InspectionField.fromJson(e))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'title': title,
      'description': description,
      'order': order,
      'fields': fields.map((e) => e.toJson()).toList(),
    };
  }
}

class InspectionStructure {
  final List<InspectionSection> sections;

  InspectionStructure({required this.sections});

  factory InspectionStructure.fromJson(Map<String, dynamic> json) {
    return InspectionStructure(
      sections: (json['sections'] as List<dynamic>?)
              ?.map((e) => InspectionSection.fromJson(e))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sections': sections.map((e) => e.toJson()).toList(),
    };
  }
}

class InspectionInitializationResponse {
  final InspectionTemplate templateType;
  final VehicleInfo vehicleInfo;
  final InspectionStructure structure;

  /// Previously-saved answers and already-uploaded media URLs returned by
  /// /resume under `saved_sections`, flattened to `{ itemId: {value, remarks,
  /// image, multiImages, video, audio, file} }`. The server may carry resumed
  /// data here instead of (or in addition to) per-field `initial_*`, so the
  /// resume merge consults it to avoid dropping already-uploaded data.
  final Map<String, Map<String, dynamic>> savedFields;

  InspectionInitializationResponse({
    required this.templateType,
    required this.vehicleInfo,
    required this.structure,
    this.savedFields = const {},
  });

  /// Tolerantly flattens the server `saved_sections` payload (shape unknown /
  /// inconsistent across endpoints) into a flat `itemId -> normalized fields`
  /// map. Accepts a list of sections (each with `items`/`fields`), a map keyed
  /// by section, a flat list of items, or the already-flattened round-trip
  /// shape this class' [toJson] emits.
  static Map<String, Map<String, dynamic>> _parseSavedFields(dynamic raw) {
    final out = <String, Map<String, dynamic>>{};
    if (raw == null) return out;

    String? str(dynamic v) {
      if (v == null) return null;
      if (v is Map) return (v['url'] ?? v['path'] ?? v['value'])?.toString();
      final s = v.toString();
      return s.isEmpty ? null : s;
    }

    List<String>? strList(dynamic v) {
      if (v is! List) return null;
      final list = <String>[];
      for (final e in v) {
        final s = e is Map
            ? (e['url'] ?? e['path'] ?? e['imagePath'])?.toString()
            : e?.toString();
        if (s != null && s.isNotEmpty) list.add(s);
      }
      return list.isEmpty ? null : list;
    }

    void addItem(Map item) {
      final id = (item['id'] ??
              item['fieldId'] ??
              item['field_id'] ??
              item['uniqueId'] ??
              item['unique_id'])
          ?.toString();
      if (id == null || id.isEmpty) return;
      out[id] = {
        'value': str(item['value']),
        'remarks': str(item['remarks'] ?? item['remark']),
        'image': str(item['imagePath'] ?? item['image'] ?? item['initial_image']),
        'multiImages': strList(item['multiImages'] ?? item['multi_images']),
        'video': str(item['videoPath'] ?? item['video']),
        'audio': str(item['audioPath'] ?? item['audio']),
        'file': str(item['filePath'] ?? item['file']),
      };
    }

    void scan(dynamic node) {
      if (node is List) {
        for (final e in node) {
          scan(e);
        }
      } else if (node is Map) {
        final items = node['items'] ?? node['fields'];
        if (items is List) {
          for (final it in items) {
            if (it is Map) addItem(it);
          }
        } else if (node.containsKey('id') ||
            node.containsKey('fieldId') ||
            node.containsKey('field_id')) {
          // A bare field item (flat list, or the flattened round-trip shape).
          addItem(node);
        } else {
          // A map keyed by section/id — recurse into the values.
          for (final v in node.values) {
            scan(v);
          }
        }
      }
    }

    scan(raw);
    return out;
  }

  /// Flat list of every image reference-media URL across all sections/fields,
  /// for warming the offline cache. Excludes non-image media (video/audio are
  /// streamed; `link`/YouTube live on uncacheable third-party hosts).
  List<String> get referenceImageUrls => [
        for (final section in structure.sections)
          for (final field in section.fields)
            for (final media in field.referenceMedia)
              if (media.url.isNotEmpty &&
                  media.mediaType.toLowerCase() == 'image')
                media.url,
      ];

  factory InspectionInitializationResponse.fromJson(Map<String, dynamic> json) {
    return InspectionInitializationResponse(
      templateType: InspectionTemplate.fromJson(
          json['template_type'] ?? json['templateType'] ?? {}),
      vehicleInfo: VehicleInfo.fromJson(
          json['vehicle_info'] ?? json['vehicleInfo'] ?? {}),
      structure: InspectionStructure.fromJson(
          json['structure'] ?? {}),
      savedFields:
          _parseSavedFields(json['saved_sections'] ?? json['savedSections']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'template_type': templateType.toJson(),
      'vehicle_info': vehicleInfo.toJson(),
      'structure': structure.toJson(),
      // Round-trip as a flat list of items (each carrying its id) so the offline
      // Hive copy re-parses through the same path the server payload takes.
      'saved_sections': [
        for (final e in savedFields.entries) {'id': e.key, ...e.value},
      ],
    };
  }
}
