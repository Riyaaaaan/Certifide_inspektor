# Dynamic Inspection API — App Team Reference

## Overview

The inspection flow works in these stages:

1. **Initialize** — Create a draft record, get back an `inspection_id`, and receive the full template structure
2. **Save Steps** — Send sections one at a time as the inspector fills them in (can be edited at any time)
3. **Submit** — Mark the inspection complete (awaiting admin review)
4. **Resume** (optional) — Re-fetch a draft/in-progress inspection with all saved values pre-filled, so the app can continue after a crash/restart
5. **Reopen** (admin only) — Flip a submitted (but not-yet-approved) inspection back to draft for further editing

**Who can edit, and when:**

| Role | While `draft` | After submit (`completed`, not approved) | After approval |
|---|---|---|---|
| Inspector (owner) | ✅ edit via save-step | ❌ locked | ❌ locked |
| Admin | ✅ edit via save-step | ✅ edit via save-step | ❌ locked |

Once an inspector submits, the record is **locked for them** — they can no longer save-step. An **admin** can keep editing a submitted inspection (or call `/reopen` to pull it back into `draft` and clear `submitted_at`), right up until it's approved. Approved inspections are locked for everyone (the report is shareable and must not change).

The old single-call endpoint (`POST /api/dynamic-inspections`) still works unchanged for clients that send everything at once.

---

## Authentication

Every endpoint requires a JWT bearer token.

```
Authorization: Bearer <token>
```

A 401 is returned if the token is missing or expired. A 403 is returned if the user's role is insufficient (e.g. a non-admin hitting an admin-only endpoint).

---

## Recommended Flow

```
POST /initialize          → get inspection_id + template structure
  ↓
POST /upload-image        → upload media, get back paths
  ↓ (repeat per section)
POST /{id}/save-step      → save one section at a time
  ↓
POST /{id}/submit         → finalise

--- app killed / restarted? ---
GET  /{id}/resume         → re-fetch structure with all saved values pre-filled,
                            then continue saving steps as normal

--- admin needs to edit after the inspector submitted? ---
POST /{id}/reopen         → (admin only) flip completed → draft, if not yet approved
  ↓
POST /{id}/save-step      → edit sections
  ↓
POST /{id}/submit         → re-finalise
```

> After submitting, the **inspector** is locked out. An **admin** can edit a
> submitted (un-approved) inspection directly via save-step, or call `/reopen`
> first to put it back in `draft` state (clears `submitted_at`, restores the
> guided flow).

---

## Endpoints

### 1. Initialize Inspection

**`POST /api/dynamic-inspections/initialize`**

Creates a draft record and returns the full template structure with pre-filled vehicle fields and reference media filtered by make/model.

**Each call creates a new draft** and returns a new `inspection_id` — it is *not* idempotent. Do not call `initialize` to resume; to continue an in-progress inspection after an app restart, list drafts via `GET /my-history?status=draft` and reload the chosen one with `GET /{id}/resume`. Calling `initialize` again will start a *separate* draft for the same vehicle.

#### Request Body

| Field | Type | Required | Notes |
|---|---|---|---|
| `vehicle_brand_id` | integer | Yes | Must exist in `vehicle_brands` table |
| `vehicle_model_id` | integer | Yes | Must exist in `vehicle_models` table |
| `registration_number` | string (max 50) | No | Stored uppercased; can be provided later via save-step or submit |
| `year` | string | No | Manufacturing year |
| `variant` | string (max 255) | No | |
| `color` | string (max 255) | No | Maps to `colour` field in Documents |
| `transmission` | string (max 50) | No | Normalised to `MANUAL` or `AUTOMATIC` |
| `for_user` | boolean | No | If `true`, non-Documents dropdowns become plain text fields (simplified inspector UX) |

```json
{
  "vehicle_brand_id": 1,
  "vehicle_model_id": 5,
  "registration_number": "MH12AB1234",
  "year": "2020",
  "variant": "VX CVT",
  "color": "Pearl White",
  "transmission": "AUTOMATIC",
  "for_user": true
}
```

#### Response `200`

```json
{
  "status": "success",
  "data": {
    "inspection_id": 123,
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "template_type": {
      "id": 1,
      "name": "default",
      "display_name": "Standard Inspection",
      "description": "...",
      "country_code": "IN",
      "has_government_api": true,
      "government_api_type": "ulip"
    },
    "vehicle_info": {
      "brand": "Toyota",
      "model": "Fortuner",
      "category": "SUV",
      "year": "2020",
      "variant": "VX CVT",
      "color": "Pearl White",
      "transmission": "AUTOMATIC"
    },
    "structure": {
      "sections": [
        {
          "id": 1,
          "name": "documents",
          "title": "Vehicle Documents",
          "description": "...",
          "order": 1,
          "fields": [
            {
              "id": 101,
              "field_id": "regno",
              "title": "Registration Number",
              "field_type": "text",
              "is_required": true,
              "has_remarks": false,
              "has_image": false,
              "has_video": false,
              "has_file": false,
              "has_multiple_images": false,
              "order": 1,
              "metadata": {},
              "initial_value": "MH12AB1234",
              "options": [],
              "reference_media": [
                {
                  "id": 1,
                  "media_type": "image",
                  "file_path": "reference-media/image/2024/01/15/abc.jpg",
                  "url": "https://app.example.com/storage/reference-media/...",
                  "description": "Sample registration card",
                  "order": 0
                }
              ]
            }
          ]
        }
      ]
    },
    "for_user": true
  }
}
```

**Field type values:** `text`, `dropdown`, `file`, `image`, `video`

**Notes:**
- Fields in the Documents section that match vehicle details (`make`, `model`, `manufacturingyear`, `variant`, `colour`, `transmission`) will have `initial_value` pre-populated
- `reference_media` are example/guide images for each field, filtered by the selected brand/model
- Store `inspection_id` — you need it for all subsequent calls

---

### 2. Upload Media

Upload before saving a step — get back a path, then include that path in the step payload.

---

#### `POST /api/dynamic-inspections/upload-image`

Accepts images, HEIC, and also handles audio. Use this for `has_image` fields and `has_multiple_images` fields.

**Request** — `multipart/form-data`

| Field | Type | Required | Notes |
|---|---|---|---|
| `image` | file | Yes | jpeg, png, jpg, gif, heic, heif, webp, mp4, m4a, pdf, docx, xls, xlsx, csv — max 100 MB |
| `section` | string | Yes | Section name |
| `itemId` | string | Yes | Field ID |

**Response `200` — image**
```json
{
  "status": "success",
  "message": "Image uploaded successfully",
  "imagePath": {
    "url": "https://app.example.com/storage/inspections/images/2024/01/15/abc123.jpg",
    "path": "inspections/images/2024/01/15/abc123.jpg"
  }
}
```

**Response `200` — video/audio (detected by extension)**
```json
{
  "status": "success",
  "message": "Video uploaded successfully",
  "videoPath": {
    "url": "https://app.example.com/storage/inspections/videos/2024/01/15/vid1.mp4",
    "path": "inspections/videos/2024/01/15/vid1.mp4"
  }
}
```

Processing applied to images: EXIF rotation fix, max 2000×2000 resize, JPEG 85% / PNG 9 compression, HEIC→JPEG conversion.

---

#### `POST /api/dynamic-inspections/upload-video`

**Request** — `multipart/form-data`

| Field | Type | Required | Notes |
|---|---|---|---|
| `video` | file | Yes | mp4, avi, mov, wmv, flv, webm, mkv — max 25 MB |
| `section` | string | Yes | |
| `itemId` | string | Yes | |

**Response `200`**
```json
{
  "status": "success",
  "message": "Video uploaded successfully",
  "videoPath": {
    "url": "https://app.example.com/storage/inspections/videos/2024/01/15/vid1.mp4",
    "path": "inspections/videos/2024/01/15/vid1.mp4"
  }
}
```

---

#### `POST /api/dynamic-inspections/upload-file`

**Request** — `multipart/form-data`

| Field | Type | Required | Notes |
|---|---|---|---|
| `file` | file | Yes | jpg, jpeg, png, gif, heic, heif, webp, pdf, doc, docx, xls, xlsx, txt, mp4, avi, mov, wmv, flv, webm, mkv — max 25 MB |
| `section` | string | Yes | |
| `itemId` | string | Yes | |

**Response `200`**
```json
{
  "status": "success",
  "message": "File uploaded successfully",
  "filePath": {
    "url": "https://app.example.com/storage/inspections/attachments/2024/01/15/doc1.pdf",
    "path": "inspections/attachments/2024/01/15/doc1.pdf",
    "name": "RC_document.pdf",
    "type": "pdf"
  }
}
```

---

### 3. Save Step

**`POST /api/dynamic-inspections/{id}/save-step`**

Saves one section into the inspection. Can be called multiple times — each call merges the section into the existing record (re-sending the same section overwrites it).

Edit permissions depend on role:

- **Inspector (owner):** may save-step only while `processing_status = "draft"`. Once they submit, the record is locked for them (422).
- **Admin:** may save-step while the inspection is **not yet approved** — `processing_status` is `"draft"` **or** `"completed"` (with `is_approved = false`). Once approved, it's locked for everyone (422).

#### Request Body

| Field | Type | Required | Notes |
|---|---|---|---|
| `section` | string (max 100) | Yes | Must match a section `name` from the structure |
| `items` | array (min 1) | Yes | Array of field objects |

Each item in `items`:

| Field | Type | Notes |
|---|---|---|
| `id` | string | `field_id` from the structure |
| `title` | string | Display title |
| `value` | string / null | Selected value or entered text |
| `remarks` | string / null | Only if `has_remarks: true` |
| `imagePath` | string / object / null | Path from upload-image response, or `{ url, path }` |
| `multiImages` | string[] | Array of paths — for `has_multiple_images: true` fields |
| `videoPath` | string / object / null | Path from upload-video response |
| `audioPath` | string / object / null | Audio path |
| `filePath` | string / object / null | Path from upload-file response |

```json
{
  "section": "body_panel",
  "items": [
    {
      "id": "front_bumper",
      "title": "Front Bumper",
      "value": "GOOD",
      "remarks": "Minor scratch on lower edge",
      "imagePath": "inspections/images/2024/01/15/abc123.jpg"
    },
    {
      "id": "hood",
      "title": "Hood",
      "value": "FAIR",
      "remarks": null,
      "multiImages": [
        "inspections/images/2024/01/15/img1.jpg",
        "inspections/images/2024/01/15/img2.jpg"
      ]
    }
  ]
}
```

#### Response `200`

```json
{
  "status": "success",
  "message": "Section 'body_panel' saved.",
  "data": {
    "inspection_id": 123,
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "saved_sections": ["documents", "body_panel"],
    "processing_status": "draft"
  }
}
```

`saved_sections` is the list of all sections saved so far — useful for progress tracking.

#### Error responses

| Code | Reason |
|---|---|
| 403 | Not the owner of this inspection (and not admin) |
| 422 | Inspector editing a submitted inspection (locked after submit) |
| 422 | Inspection has been approved (locked for everyone) |
| 422 | `section` does not exist in the template |
| 422 | Validation failure on `section` or `items` |
| 500 | Server error |

---

### 4. Submit Inspection

**`POST /api/dynamic-inspections/{id}/submit`**

Finalises the draft. Sets `processing_status = "completed"` and records `submitted_at`.

Idempotent — calling submit on an already-completed inspection returns `200` without error.

You can optionally send remaining data in this call (full payload or one final section). If all sections were already saved via `save-step`, send an empty body.

#### Request Body (empty — all sections already saved)
```json
{}
```

#### Request Body (send one last section)
```json
{
  "section": "summary_remarks",
  "items": [
    {
      "id": "overall_remarks",
      "title": "Overall Remarks",
      "value": "Vehicle in good condition",
      "remarks": null
    }
  ]
}
```

#### Request Body (send full payload at once)
```json
{
  "inspection_data": {
    "documents": {
      "items": [ ... ]
    },
    "body_panel": {
      "items": [ ... ]
    }
  }
}
```

#### Response `200`

```json
{
  "status": "success",
  "message": "Inspection submitted successfully.",
  "data": {
    "inspection_id": 123,
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "redirect_url": "/inspection/123/view"
  }
}
```

#### Error responses

| Code | Reason |
|---|---|
| 403 | Not the owner (and not admin) |
| 422 | `processing_status` is not `"draft"` |
| 422 | No data at all (no steps saved, no body sent) |
| 500 | Server error |

---

### 5. Resume Inspection (re-fetch with saved values)

**`GET /api/dynamic-inspections/{id}/resume`**

Returns the full template structure (identical shape to `/initialize`) **with every field's saved value injected** so the app can prefill and continue an in-progress inspection — e.g. after the app is killed or the device restarts.

Works regardless of `processing_status` (draft or completed). It's a read-only fetch of whatever has been saved so far. Owner-only (admins can read any).

The structure is the same as `/initialize`. In addition, each field that has saved data carries these `initial_*` keys (absent/empty when nothing was saved for that field):

| Key | Source (save-step item) | Notes |
|---|---|---|
| `initial_value` | `value` | Selected/entered value |
| `initial_remarks` | `remarks` | |
| `initial_image` | `imagePath` | string or `{ url, path }` |
| `initial_multi_images` | `multiImages` | array of URL strings |
| `initial_video` | `videoPath` | |
| `initial_audio` | `audioPath` | |
| `initial_file` | `filePath` | |
| `initial_summary_images` | `summaryImages` | only for the summary field |

> Note: the pre-fill key from `/initialize` is `initial_value` (vehicle details).
> `/resume` uses the **same** `initial_value` key plus the additional `initial_*`
> keys above for media/remarks, so a single rendering path can handle both.

#### Response `200`

```json
{
  "status": "success",
  "data": {
    "inspection_id": 123,
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "processing_status": "draft",
    "is_approved": false,
    "submitted_at": null,
    "saved_sections": ["documents", "body_panel"],
    "template_type": {
      "id": 1,
      "name": "default",
      "display_name": "Standard Inspection",
      "description": "...",
      "country_code": "IN",
      "has_government_api": true,
      "government_api_type": "ulip"
    },
    "vehicle_info": {
      "brand": "Toyota",
      "model": "Fortuner",
      "category": "SUV",
      "registration_number": "MH12AB1234"
    },
    "structure": {
      "sections": [
        {
          "id": 2,
          "name": "body_panel",
          "title": "Body & Panels",
          "description": "...",
          "order": 2,
          "fields": [
            {
              "id": 201,
              "field_id": "front_bumper",
              "title": "Front Bumper",
              "field_type": "dropdown",
              "is_required": true,
              "has_remarks": true,
              "has_image": true,
              "has_video": false,
              "has_file": false,
              "order": 1,
              "metadata": {},
              "options": [ ... ],
              "reference_media": [ ... ],
              "initial_value": "GOOD",
              "initial_remarks": "Minor scratch on lower edge",
              "initial_image": "inspections/images/2024/01/15/abc123.jpg",
              "initial_multi_images": [],
              "initial_video": null,
              "initial_audio": null,
              "initial_file": null
            }
          ]
        }
      ]
    }
  }
}
```

#### Error responses

| Code | Reason |
|---|---|
| 403 | Not the owner of this inspection (and not admin) |
| 404 | Inspection (or its template type) not found |
| 500 | Server error |

---

### 6. Reopen Inspection (admin only — edit after submitting)

**`POST /api/dynamic-inspections/{id}/reopen`**

Requires role: `admin`.

Flips a submitted inspection back to `draft` (and clears `submitted_at`) so it re-enters the guided step-by-step flow. After reopening: edit via `/save-step`, then call `/submit` again to re-finalise.

- **Admin-only** — an inspector cannot edit once they've submitted, so they cannot reopen either (403).
- Only works while **not yet approved** — an approved inspection returns 422.
- Idempotent — reopening an already-`draft` inspection is a no-op success.

> An admin doesn't strictly need this just to edit — `/save-step` already accepts
> admin edits on a `completed` (un-approved) record. Use `/reopen` when you want
> the record back in `draft` state (clears `submitted_at`, removes it from review
> queues, restores the guided flow).

Empty request body.

#### Response `200`

```json
{
  "status": "success",
  "message": "Inspection reopened. You can now edit and resubmit.",
  "data": {
    "inspection_id": 123,
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "processing_status": "draft",
    "saved_sections": ["documents", "body_panel"]
  }
}
```

#### Error responses

| Code | Reason |
|---|---|
| 403 | Caller is not an admin |
| 422 | Inspection has been approved (cannot be reopened) |
| 404 | Inspection not found |
| 500 | Server error |

---

### 7. Inspection History

**`GET /api/dynamic-inspections/my-history`**

Requires role: `admin` or `inspector`.

Admins see all inspections. Inspectors see only their own. By default **draft records are excluded** — pass `status=draft` to fetch them instead (see below).

This is a **lightweight list** — each row carries only the inspection id, identifiers, status and basic vehicle info. The full `inspection_data` (all sections, items, images, remarks) is **not** included; fetch it per-record via `GET /api/dynamic-inspections/{id}` when you open a single inspection, or `GET /api/dynamic-inspections/{id}/resume` to resume a draft with saved values pre-filled.

#### Query Parameters

| Param | Type | Notes |
|---|---|---|
| `status` | string | `draft`, `pending`, `approved`, `rejected`. `draft` works for any role (scoped to your own rows); `pending`/`approved`/`rejected` are admin-only |
| `template_type_id` | integer | |
| `reg_no` | string | Registration number filter |
| `date_from` | date | ISO format |
| `date_to` | date | ISO format |
| `sort` | string | `oldest` (default — oldest first) or `latest` (newest first) |
| `per_page` | integer | 1–100, default 15 |

#### Fetching drafts (resume initialised inspections)

`GET /api/dynamic-inspections/my-history?status=draft` returns the caller's **initialised-but-not-submitted** inspections — useful for showing an inspector their in-progress work so they can resume it.

- Returns **only** `processing_status = "draft"` rows (the default list, with no `status`, still excludes drafts).
- Scoped to the caller's own rows for inspectors; admins see everyone's drafts.
- Each row's `status` field is `"draft"`, and `uuid`/`report_url` are `null` (a draft has no shareable report).
- Use the row's `id` with `GET /api/dynamic-inspections/{id}/resume` to load the draft and continue.

#### Response `200`

```json
{
  "status": "success",
  "meta": {
    "viewer_role": "inspector"
  },
  "data": {
    "data": [
      {
        "id": 123,
        "uuid": "550e8400-...",
        "reference_number": "CER202401151234001",
        "registration_number": "MH12AB1234",
        "is_approved": false,
        "approved_at": null,
        "processing_status": "completed",
        "submitted_at": "2024-01-15 09:00:00",
        "created_at": "2024-01-15 08:00:00",
        "status": "pending",
        "report_url": null,
        "vehicle_info": {
          "registration_number": "MH12AB1234",
          "make_model": "Toyota Fortuner"
        },
        "user": { "id": 1, "name": "Inspector Name", "email": "..." },
        "templateType": { "id": 1, "name": "default", "display_name": "Standard Inspection" },
        "vehicleBrand": { "id": 1, "name": "Toyota" },
        "vehicleModel": { "id": 1, "name": "Fortuner" }
      }
    ],
    "pagination": {
      "current_page": 1,
      "last_page": 5,
      "per_page": 15,
      "total": 75,
      "from": 1,
      "to": 15
    }
  }
}
```

**Inspector visibility rules:**
- `report_url` is `null` for pending/rejected — inspectors cannot share unapproved reports
- `uuid` is `null` for pending/rejected records

---

### 8. Other Endpoints

#### Fetch Government Vehicle Data (India only)

**`POST /api/dynamic-inspections/fetch-government-data`**

Calls ULIP API using the registration number and returns formatted vehicle data for the Documents section. Only available when `template_type.has_government_api = true`.

```json
{ "registration_number": "MH12AB1234" }
```

#### View Single Inspection

**`GET /api/dynamic-inspections/{id}`**

Returns full inspection data with color codes applied to field values.

#### Shareable Report

**`GET /api/dynamic-inspections/{uuid}/view-shared`**

Returns the HTML report. Soft-authenticated — supports `?token=<jwt>` for iframe embeds (e.g. CRM). Only returns approved inspections.

---

## Inspection Status Reference

| `processing_status` | `is_approved` | `approved_at` | Meaning |
|---|---|---|---|
| `draft` | false | null | Initialised, not yet submitted |
| `completed` | false | null | Submitted, awaiting admin review |
| `completed` | false | set | Rejected by admin |
| `completed` | true | set | Approved — report is shareable |

The `status` field in history responses maps these to: `"draft"`, `"pending"`, `"approved"`, `"rejected"`.

---

## Field Type Reference

| `field_type` | UI | Attach flags |
|---|---|---|
| `text` | Free text input | — |
| `dropdown` | Picker from `options` | — |
| `image` | Camera / gallery | `has_image`, `has_multiple_images` |
| `video` | Video recorder | `has_video` |
| `file` | File picker | `has_file` |

Additional attach flags that can appear on any field type:

| Flag | Meaning |
|---|---|
| `has_remarks` | Show a remarks text input alongside this field |
| `has_image` | Allow one image attachment |
| `has_multiple_images` | Allow a gallery of images (`multiImages[]` array) |
| `has_video` | Allow a video attachment |
| `has_file` | Allow a file attachment |

---

## Error Response Format

All errors follow this shape:

```json
{
  "status": "error",
  "message": "Human-readable message"
}
```

Validation errors (422) include an `errors` object:

```json
{
  "status": "error",
  "errors": {
    "section": ["The section field is required."],
    "vehicle_brand_id": ["The selected vehicle brand id is invalid."]
  }
}
```

---

## Media Storage Paths

All paths returned by upload endpoints are relative to the app's storage root. Use the `url` field for display; use the `path` field when setting `imagePath`, `videoPath`, or `filePath` in step/submit payloads.

```
inspections/images/YYYY/MM/DD/        ← photos
inspections/videos/YYYY/MM/DD/        ← videos
inspections/audios/YYYY/MM/DD/        ← audio recordings
inspections/attachments/YYYY/MM/DD/   ← PDFs, documents
reference-media/image/YYYY/MM/DD/     ← guide/reference images (read-only)
```