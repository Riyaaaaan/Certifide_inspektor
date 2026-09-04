#!/bin/bash

# ============================================================
#  Flutter Deploy — iOS (TestFlight) + Android (Play Store)
#  Parallel execution after a single flutter clean.
#
#  Profiles:
#    iOS     → ~/.config/ios-upload/flutter-ios-upload/profiles/*.env
#              KEY_ID=, ISSUER_ID=, optional TEAM_ID=
#    Android → ~/.config/android-upload/flutter-android-upload/profiles/*.env
#              SERVICE_ACCOUNT_JSON=<path to .json key>
#              PACKAGE_NAME=<com.example.app>
#              TRACK=<internal|alpha|beta|production>  (default: internal)
#
#  Usage: ./deploy.sh [--debug|-d] [--help|-h]
#
#  Env (optional):
#    IOS_EXPORT_ONLY=1   iOS: export IPA only — reuse build/ios/Runner.xcarchive or
#                        restore from ~/.cache/vdo-agent-deploy/ios/last_Runner.xcarchive
#                        when archive_stamp.txt matches pubspec version (skips pod / Flutter / archive).
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${CYAN}[•] $1${NC}"; }
success() { echo -e "${GREEN}[✓] $1${NC}"; }
warn()    { echo -e "${YELLOW}[!] $1${NC}"; }
error()   { echo -e "${RED}[✗] $1${NC}"; exit 1; }
header()  { echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $1\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
dbg()     { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${YELLOW}[debug] $1${NC}" >&2 || true; }

# ERR trap: show file + line whenever set -e fires
trap 'echo -e "${RED}[✗] Script exited unexpectedly at line $LINENO (exit $?)${NC}" >&2' ERR

# Trim whitespace + surrounding quotes from a value
_trim() {
  local v="${1%%#*}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#\"}"
  printf '%s' "${v%\"}"
}
export -f _trim

DEBUG=0
for _arg in "$@"; do
  case "$_arg" in
    --debug|-d) DEBUG=1 ;;
    --help|-h)
      cat << HELP
Flutter Deploy — iOS TestFlight + Android Play Store (parallel).

  ./deploy.sh [--debug|-d] [--help]

  --debug, -d   Print each parsed value and step (also enables bash -x trace)

  IOS_EXPORT_ONLY=1   iOS: export IPA only from existing/cached .xcarchive (see header comment).

HELP
      exit 0 ;;
  esac
done
[[ "$DEBUG" == "1" ]] && set -x


[[ ! -f "pubspec.yaml" ]] && error "Run from your Flutter project root."
[[ -z "$(which flutter)" ]] && error "Flutter not found in PATH."

# ── SANITIZE ──────────────────────────────────────────────────
sanitize_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]//g'
}

# ── DETECT PACKAGE NAME FROM CODE (single source of truth) ───
detect_android_package() {
  local gradle_file="" pkg=""
  [[ -f "android/app/build.gradle.kts" ]] && gradle_file="android/app/build.gradle.kts"
  [[ -f "android/app/build.gradle" ]]     && gradle_file="android/app/build.gradle"
  if [[ -n "$gradle_file" ]]; then
    pkg=$(grep 'applicationId' "$gradle_file" 2>/dev/null \
      | sed 's/.*applicationId.*=.*"\([^"]*\)".*/\1/' | tr -d ' \t' | head -1)
    [[ -z "$pkg" ]] && pkg=$(grep 'namespace' "$gradle_file" 2>/dev/null \
      | sed 's/.*namespace.*=.*"\([^"]*\)".*/\1/' | tr -d ' \t' | head -1)
  fi
  printf '%s' "$pkg"
}

# iOS PRODUCT_BUNDLE_IDENTIFIER from Xcode project (same logic as run_ios)
detect_ios_bundle_id() {
  local PBXPROJ="ios/Runner.xcodeproj/project.pbxproj" bid=""
  [[ -f "$PBXPROJ" ]] || { printf '%s' "$bid"; return; }
  bid=$(grep 'PRODUCT_BUNDLE_IDENTIFIER' "$PBXPROJ" \
    | grep -v '\$(' | head -1 \
    | sed 's/.*PRODUCT_BUNDLE_IDENTIFIER = //;s/;//;s/^[[:space:]]*//' | tr -d '"')
  printf '%s' "$bid"
}

# ── VERSION BUMP (ask first) ─────────────────────────────────
CURRENT=$(grep '^version:' pubspec.yaml | awk '{print $2}')
VERSION_NAME=$(echo "$CURRENT" | cut -d'+' -f1)
CURRENT_BUILD=$(echo "$CURRENT" | cut -d'+' -f2)

MAJOR=$(echo "$VERSION_NAME" | cut -d'.' -f1)
MINOR=$(echo "$VERSION_NAME" | cut -d'.' -f2)
PATCH=$(echo "$VERSION_NAME" | cut -d'.' -f3)

NEW_BUILD=$((CURRENT_BUILD + 1))

header "📦 Version: $VERSION_NAME+$CURRENT_BUILD — what kind of update?"
echo "  1) Patch  — $MAJOR.$MINOR.$((PATCH+1))+$NEW_BUILD"
echo "  2) Minor  — $MAJOR.$((MINOR+1)).0+$NEW_BUILD"
echo "  3) Major  — $((MAJOR+1)).0.0+$NEW_BUILD"
echo "  4) Build  — $VERSION_NAME+$NEW_BUILD"
echo ""
echo -e "  ${BOLD}[Enter] No change — keep $VERSION_NAME+$CURRENT_BUILD as-is${NC}"
echo ""
read -r -p "  Choice: " VERSION_CHOICE

case "$VERSION_CHOICE" in
  1) VERSION_NAME="$MAJOR.$MINOR.$((PATCH+1))" ;;
  2) VERSION_NAME="$MAJOR.$((MINOR+1)).0" ;;
  3) VERSION_NAME="$((MAJOR+1)).0.0" ;;
  4) ;; # bump build only, version stays
  "") NEW_BUILD="$CURRENT_BUILD" ;; # Enter = no change at all
  *) error "Invalid choice: $VERSION_CHOICE" ;;
esac

success "Will deploy: $VERSION_NAME+$NEW_BUILD"

# ── PLATFORM SELECTION ────────────────────────────────────────
header "🚀 Flutter Deploy — which platform(s)?"
echo "  1) Both (iOS + Android)"
echo "  2) iOS only"
echo "  3) Android only"
echo "  4) Android — promote internal → production"
echo ""
read -r -p "  Choose [1]: " PLATFORM_CHOICE
PLATFORM_CHOICE="${PLATFORM_CHOICE:-1}"

DO_PROMOTE=false
case "$PLATFORM_CHOICE" in
  1) DO_IOS=true;  DO_ANDROID=true  ;;
  2) DO_IOS=true;  DO_ANDROID=false ;;
  3) DO_IOS=false; DO_ANDROID=true  ;;
  4) DO_IOS=false; DO_ANDROID=false; DO_PROMOTE=true ;;
  *) error "Invalid choice: $PLATFORM_CHOICE" ;;
esac

# ============================================================
# ── iOS PROFILE SETUP ────────────────────────────────────────
# ============================================================

IOS_PROFILES_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ios-upload/flutter-ios-upload/profiles"
mkdir -p "$IOS_PROFILES_DIR"

APP_STORE_API_KEY_ID=""
APP_STORE_API_ISSUER_ID=""
IOS_UPLOAD_PROFILE_NAME=""
IOS_TEAM_ID=""

read_ios_profile() {
  local file="$1"
  local raw_k raw_i raw_t
  dbg "read_ios_profile: file=$file"
  raw_k=$(grep -E '^[[:space:]]*KEY_ID[[:space:]]*='     "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
  raw_i=$(grep -E '^[[:space:]]*ISSUER_ID[[:space:]]*='  "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
  raw_t=$(grep -E '^[[:space:]]*TEAM_ID[[:space:]]*='    "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
  APP_STORE_API_KEY_ID=$(_trim "$raw_k")
  APP_STORE_API_ISSUER_ID=$(_trim "$raw_i")
  IOS_TEAM_ID=$(_trim "$raw_t")
  IOS_UPLOAD_PROFILE_NAME=$(basename "$file" .env)
  dbg "read_ios_profile: KEY_ID='$APP_STORE_API_KEY_ID' ISSUER_ID='$APP_STORE_API_ISSUER_ID' TEAM_ID='$IOS_TEAM_ID'"
  return 0
}

create_ios_profile() {
  local KEYS_DIR="$HOME/.appstoreconnect/private_keys" pname kid iid tid p8src dest
  echo ""
  echo -e "${CYAN}  New App Store Connect profile${NC}"
  read -r -p "  Profile id (e.g. conceptmates): " pname
  pname=$(sanitize_id "$pname")
  [[ -z "$pname" ]] && error "Profile id required."
  [[ -f "$IOS_PROFILES_DIR/${pname}.env" ]] && error "Profile already exists: $pname"
  read -r -p "  API Key ID: " kid; kid="${kid// /}"; [[ -z "$kid" ]] && error "Key ID required."
  read -r -p "  Issuer ID (UUID): " iid; iid="${iid// /}"; [[ -z "$iid" ]] && error "Issuer ID required."
  read -r -p "  Apple Developer Team ID (optional, Enter to skip): " tid; tid="${tid// /}"
  while true; do
    read -r -p "  Path to .p8 private key: " p8src
    p8src="${p8src/#\~/$HOME}"
    [[ -f "$p8src" ]] && break
    warn "File not found: $p8src"
  done
  mkdir -p "$KEYS_DIR"
  dest="$KEYS_DIR/AuthKey_${kid}.p8"
  cp "$p8src" "$dest"; chmod 600 "$dest" 2>/dev/null || true
  success "Key installed: $dest"
  { echo "KEY_ID=$kid"; echo "ISSUER_ID=$iid"; [[ -n "$tid" ]] && echo "TEAM_ID=$tid"; } > "$IOS_PROFILES_DIR/${pname}.env"
  success "iOS profile saved: $IOS_PROFILES_DIR/${pname}.env"
  IOS_LAST_PROFILE="$IOS_PROFILES_DIR/${pname}.env"
}

select_ios_profile() {
  local profiles=() f i choice idx selected create_idx
  while IFS= read -r f; do [[ -n "$f" ]] && profiles+=("$f"); done \
    < <(find "$IOS_PROFILES_DIR" -maxdepth 1 -name '*.env' -print | sort)

  header "🍎 iOS — App Store Connect profile"

  if [[ ${#profiles[@]} -eq 0 ]]; then
    warn "No iOS profiles found. Let's create one."
    create_ios_profile
    read_ios_profile "$IOS_LAST_PROFILE"; return
  fi

  i=1
  for f in "${profiles[@]}"; do echo "  $i) $(basename "$f" .env)"; i=$((i+1)); done
  create_idx=$i
  echo "  ${create_idx}) Create new profile"
  echo ""
  read -r -p "  Choose [1]: " choice; choice="${choice:-1}"

  if [[ "$choice" == "$create_idx" || "$choice" == "new" || "$choice" == "create" ]]; then
    create_ios_profile; read_ios_profile "$IOS_LAST_PROFILE"; return
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    idx=$((choice - 1))
    [[ "$idx" -ge 0 && "$idx" -lt ${#profiles[@]} ]] || error "Invalid: $choice"
    selected="${profiles[$idx]}"
  else
    selected="$IOS_PROFILES_DIR/${choice}.env"
    [[ -f "$selected" ]] || error "Profile not found: $choice"
  fi

  read_ios_profile "$selected"
  dbg "select_ios_profile: resolved KEY_ID='$APP_STORE_API_KEY_ID' ISSUER='$APP_STORE_API_ISSUER_ID'"
  if [[ -z "$APP_STORE_API_KEY_ID" || -z "$APP_STORE_API_ISSUER_ID" ]]; then
    error "iOS profile missing KEY_ID or ISSUER_ID."
  fi
  return 0
}

# ============================================================
# ── ANDROID PROFILE SETUP ────────────────────────────────────
# ============================================================

ANDROID_PROFILES_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/android-upload/flutter-android-upload/profiles"
mkdir -p "$ANDROID_PROFILES_DIR"

ANDROID_SERVICE_ACCOUNT_JSON=""
ANDROID_PACKAGE_NAME=""
ANDROID_TRACK="internal"
ANDROID_PROFILE_NAME=""

read_android_profile() {
  local file="$1"
  local raw_j raw_p raw_t
  dbg "read_android_profile: file=$file"
  raw_j=$(grep -E '^[[:space:]]*SERVICE_ACCOUNT_JSON[[:space:]]*=' "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
  raw_p=$(grep -E '^[[:space:]]*PACKAGE_NAME[[:space:]]*='         "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
  raw_t=$(grep -E '^[[:space:]]*TRACK[[:space:]]*='                "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
  ANDROID_SERVICE_ACCOUNT_JSON=$(_trim "$raw_j")
  ANDROID_SERVICE_ACCOUNT_JSON="${ANDROID_SERVICE_ACCOUNT_JSON/#\~/$HOME}"

  # SERVICE_ACCOUNT_JSON must be a path to a json key file.
  if [[ ! -f "$ANDROID_SERVICE_ACCOUNT_JSON" ]]; then
    echo -e "${RED}[✗] SERVICE_ACCOUNT_JSON must point to a file: $ANDROID_SERVICE_ACCOUNT_JSON${NC}" >&2
    exit 1
  fi
  if ! python3 -c "import json,sys; json.load(open('$ANDROID_SERVICE_ACCOUNT_JSON'))" 2>/dev/null; then
    echo -e "${RED}[✗] Service account JSON is not valid JSON: $ANDROID_SERVICE_ACCOUNT_JSON${NC}" >&2
    exit 1
  fi

  local profile_pkg=$(_trim "$raw_p")
  local track; track=$(_trim "$raw_t")
  ANDROID_TRACK="${track:-internal}"
  ANDROID_PROFILE_NAME=$(basename "$file" .env)

  # Always use package name from code — never trust profile env
  local code_pkg
  code_pkg=$(detect_android_package)
  if [[ -n "$code_pkg" ]]; then
    if [[ -n "$profile_pkg" && "$profile_pkg" != "$code_pkg" ]]; then
      warn "Profile PACKAGE_NAME ($profile_pkg) differs from code ($code_pkg) — using code."
    fi
    ANDROID_PACKAGE_NAME="$code_pkg"
  elif [[ -n "$profile_pkg" ]]; then
    warn "Could not detect package from code — falling back to profile: $profile_pkg"
    ANDROID_PACKAGE_NAME="$profile_pkg"
  fi

  dbg "read_android_profile: JSON='$ANDROID_SERVICE_ACCOUNT_JSON' PKG='$ANDROID_PACKAGE_NAME' TRACK='$ANDROID_TRACK'"
  return 0
}

create_android_profile() {
  local pname json_src pkg track
  echo ""
  echo -e "${CYAN}  New Android Play Store profile${NC}"
  echo "  (Google Play Console → Setup → API access → Service accounts → create .json key)"
  echo ""

  local detected_pkg
  detected_pkg=$(detect_android_package)

  read -r -p "  Profile id (e.g. conceptmates): " pname
  pname=$(sanitize_id "$pname")
  [[ -z "$pname" ]] && error "Profile id required."
  [[ -f "$ANDROID_PROFILES_DIR/${pname}.env" ]] && error "Profile already exists: $pname"

  # FIX: Validate JSON file on creation
  while true; do
    read -r -p "  Path to service account .json: " json_src
    json_src="${json_src/#\~/$HOME}"
    if [[ ! -f "$json_src" ]]; then
      warn "File not found: $json_src"
      continue
    fi
    if ! python3 -c "import json,sys; json.load(open('$json_src'))" 2>/dev/null; then
      warn "File is not valid JSON: $json_src"
      continue
    fi
    break
  done

  if [[ -n "$detected_pkg" ]]; then
    echo -e "  Package name (e.g. com.example.app) [${GREEN}${detected_pkg}${NC}]: "
    read -r pkg
    [[ -z "$pkg" ]] && pkg="$detected_pkg"
  else
    echo -e "  Package name (e.g. com.example.app): "
    read -r pkg
  fi
  pkg="${pkg// /}"; [[ -z "$pkg" ]] && error "Package name required."
  read -r -p "  Track [internal]: " track
  track="${track:-internal}"
  {
    echo "# Android Play Store profile — $pname"
    echo "SERVICE_ACCOUNT_JSON=$json_src"
    echo "PACKAGE_NAME=$pkg"
    echo "TRACK=$track"
  } > "$ANDROID_PROFILES_DIR/${pname}.env"
  success "Android profile saved: $ANDROID_PROFILES_DIR/${pname}.env"
  ANDROID_LAST_PROFILE="$ANDROID_PROFILES_DIR/${pname}.env"
}

select_android_profile() {
  local profiles=() f i choice idx selected create_idx
  while IFS= read -r f; do [[ -n "$f" ]] && profiles+=("$f"); done \
    < <(find "$ANDROID_PROFILES_DIR" -maxdepth 1 -name '*.env' -print | sort)

  header "🤖 Android — Play Store profile"

  if [[ ${#profiles[@]} -eq 0 ]]; then
    warn "No Android profiles found. Let's create one."
    create_android_profile
    read_android_profile "$ANDROID_LAST_PROFILE"; return
  fi

  i=1
  for f in "${profiles[@]}"; do echo "  $i) $(basename "$f" .env)"; i=$((i+1)); done
  create_idx=$i
  echo "  ${create_idx}) Create new profile"
  echo ""
  read -r -p "  Choose [1]: " choice; choice="${choice:-1}"

  if [[ "$choice" == "$create_idx" || "$choice" == "new" || "$choice" == "create" ]]; then
    create_android_profile; read_android_profile "$ANDROID_LAST_PROFILE"; return
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    idx=$((choice - 1))
    [[ "$idx" -ge 0 && "$idx" -lt ${#profiles[@]} ]] || error "Invalid: $choice"
    selected="${profiles[$idx]}"
  else
    selected="$ANDROID_PROFILES_DIR/${choice}.env"
    [[ -f "$selected" ]] || error "Profile not found: $choice"
  fi

  read_android_profile "$selected"
  dbg "select_android_profile: JSON='$ANDROID_SERVICE_ACCOUNT_JSON' PKG='$ANDROID_PACKAGE_NAME'"

  if [[ -z "$ANDROID_SERVICE_ACCOUNT_JSON" || -z "$ANDROID_PACKAGE_NAME" ]]; then
    error "Android profile missing SERVICE_ACCOUNT_JSON or PACKAGE_NAME."
  fi
  return 0
}

# ── SELECT PROFILES ───────────────────────────────────────────
$DO_IOS     && select_ios_profile
( $DO_ANDROID || $DO_PROMOTE ) && select_android_profile

# ── PROMOTE TO PRODUCTION (standalone flow) ──────────────────
if $DO_PROMOTE; then
  header "🚀 Promote to production"

  echo -e "  Package : ${GREEN}$ANDROID_PACKAGE_NAME${NC}"
  echo -e "  Profile : ${GREEN}$ANDROID_PROFILE_NAME${NC}"
  echo -e "  Pubspec : ${GREEN}$VERSION_NAME+$CURRENT_BUILD${NC}"
  echo ""

  # Ensure google-api-python-client is available for Play Store API queries
  if ! python3 -c "import google.oauth2.service_account; import googleapiclient.discovery" 2>/dev/null; then
    log "Installing Google Play API dependencies..."
    pip3 install --quiet google-api-python-client google-auth 2>/dev/null \
      || pip install --quiet google-api-python-client google-auth 2>/dev/null \
      || error "Failed to install google-api-python-client. Run: pip3 install google-api-python-client google-auth"
  fi

  log "Scanning all tracks for build $CURRENT_BUILD..."

  # Query ALL tracks from Google Play, find where our pubspec build lives
  TRACKS_JSON=$(python3 - "$ANDROID_SERVICE_ACCOUNT_JSON" "$ANDROID_PACKAGE_NAME" "$CURRENT_BUILD" << 'PYEOF'
import sys, json
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build

sa_json       = sys.argv[1]
package       = sys.argv[2]
target_build  = int(sys.argv[3])

creds = Credentials.from_service_account_file(
    sa_json, scopes=["https://www.googleapis.com/auth/androidpublisher"]
)
service = build("androidpublisher", "v3", credentials=creds)

edit_id = service.edits().insert(packageName=package, body={}).execute()["id"]
try:
    tracks = service.edits().tracks().list(
        packageName=package, editId=edit_id
    ).execute().get("tracks", [])

    result = {
        "all_tracks": [],
        "build_found_on": None,
        "build_status": None,
        "build_track": None,
    }

    for t in tracks:
        track_name = t.get("track", "")
        for r in t.get("releases", []):
            codes = [int(v) for v in r.get("versionCodes", [])]
            status = r.get("status", "unknown")
            name = r.get("name", "")
            entry = {
                "track": track_name,
                "status": status,
                "versionCodes": codes,
                "name": name,
            }
            result["all_tracks"].append(entry)
            if target_build in codes:
                result["build_found_on"] = track_name
                result["build_status"] = status
                result["build_track"] = entry

    print(json.dumps(result))
finally:
    service.edits().delete(packageName=package, editId=edit_id).execute()
PYEOF
  ) || error "Failed to query Google Play API. Check service account permissions."

  dbg "Tracks JSON: $TRACKS_JSON"

  # Parse results
  BUILD_FOUND_ON=$(echo "$TRACKS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['build_found_on'] or '')
")
  BUILD_STATUS=$(echo "$TRACKS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['build_status'] or '')
")

  # Show all tracks summary
  echo ""
  echo -e "${CYAN}${BOLD}  Google Play Track Summary${NC}"
  echo "$TRACKS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d['all_tracks']:
    print('  (no releases found on any track)')
else:
    for t in d['all_tracks']:
        codes = ', '.join(str(c) for c in t['versionCodes'])
        name = f\" ({t['name']})\" if t.get('name') else ''
        print(f\"  {t['track']:12s} → build {codes}{name} [{t['status']}]\")
"
  echo ""

  # Check if our pubspec build is on any track
  if [[ -z "$BUILD_FOUND_ON" ]]; then
    warn "Build $CURRENT_BUILD ($VERSION_NAME) is NOT on any track."
    echo -e "  ${YELLOW}Deploy it first (option 3), then come back to promote.${NC}"
    exit 1
  fi

  echo -e "  Build ${GREEN}$CURRENT_BUILD${NC} found on: ${BOLD}$BUILD_FOUND_ON${NC} [${BUILD_STATUS}]"
  echo ""

  # Already on production?
  if [[ "$BUILD_FOUND_ON" == "production" ]]; then
    success "Build $CURRENT_BUILD is already on production!"
    exit 0
  fi

  # Check status before promoting
  case "$BUILD_STATUS" in
    completed)
      success "Build $CURRENT_BUILD is fully released on $BUILD_FOUND_ON."
      echo ""
      echo -e "  ${CYAN}Promote $BUILD_FOUND_ON → production?${NC}"
      read -r -p "  Proceed? (y/n): " CONFIRM
      [[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0
      ;;
    inProgress)
      warn "Build $CURRENT_BUILD is still rolling out on $BUILD_FOUND_ON."
      echo -e "  ${YELLOW}Staged rollout in progress. Promote anyway?${NC}"
      read -r -p "  Promote? (y/n): " CONFIRM
      [[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0
      ;;
    draft)
      warn "Build $CURRENT_BUILD is in DRAFT on $BUILD_FOUND_ON — not yet submitted."
      echo -e "  ${YELLOW}Submit it from Google Play Console first.${NC}"
      exit 1
      ;;
    halted)
      warn "Build $CURRENT_BUILD is HALTED on $BUILD_FOUND_ON."
      echo -e "  ${YELLOW}Resume rollout in Google Play Console first.${NC}"
      exit 1
      ;;
    *)
      warn "Build $CURRENT_BUILD has status '$BUILD_STATUS' on $BUILD_FOUND_ON."
      echo -e "  ${YELLOW}Check Google Play Console.${NC}"
      exit 1
      ;;
  esac

  log "Promoting $BUILD_FOUND_ON → production..."
  fastlane supply \
    --track "$BUILD_FOUND_ON" \
    --track_promote_to production \
    --package_name "$ANDROID_PACKAGE_NAME" \
    --json_key "$ANDROID_SERVICE_ACCOUNT_JSON" \
    --skip_upload_metadata \
    --skip_upload_changelogs \
    --skip_upload_images \
    --skip_upload_screenshots

  PROMOTE_EXIT=$?
  if [[ "$PROMOTE_EXIT" -ne 0 ]]; then
    error "Promotion failed (exit $PROMOTE_EXIT). Check Google Play Console for details."
  fi

  success "Promoted to production!"
  echo ""
  echo -e "  ${GREEN}Build $CURRENT_BUILD ($VERSION_NAME) promoted from $BUILD_FOUND_ON → production.${NC}"
  echo -e "  ${YELLOW}Google Play may still take time to review and roll out.${NC}"
  exit 0
fi

IOS_BUNDLE_ID=""
if $DO_IOS; then
  IOS_BUNDLE_ID=$(detect_ios_bundle_id)
fi

# ── SUMMARY + CONFIRM ─────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Deploy Summary"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Version  : ${GREEN}$VERSION_NAME${NC}"
echo -e "  Build    : ${YELLOW}$CURRENT_BUILD${NC} → ${GREEN}$NEW_BUILD${NC}"
if $DO_IOS; then
  echo ""
  echo -e "  ${BOLD}iOS${NC}"
  echo -e "    Bundle ID: ${GREEN}${IOS_BUNDLE_ID:-<unknown>}${NC}"
  echo -e "    Profile  : ${GREEN}$IOS_UPLOAD_PROFILE_NAME${NC}"
  echo -e "    Team ID  : ${GREEN}${IOS_TEAM_ID:-<from Xcode>}${NC}"
fi
if $DO_ANDROID; then
  echo ""
  echo -e "  ${BOLD}Android${NC}"
  echo -e "    Profile  : ${GREEN}$ANDROID_PROFILE_NAME${NC}"
  echo -e "    Package  : ${GREEN}$ANDROID_PACKAGE_NAME${NC}"
  echo -e "    Track    : ${GREEN}$ANDROID_TRACK${NC}"
fi
echo ""
read -r -p "  Proceed? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "Aborted." && exit 0
echo ""

# ── BUILD CHOICE PER PLATFORM ────────────────────────────────
# Survives `flutter clean` (which deletes all of build/). Enables upload-only reruns.
IOS_IPA_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/vdo-agent-deploy/ios"
IOS_ARCHIVE_CACHE="${IOS_IPA_CACHE_DIR}/last_Runner.xcarchive"
IOS_ARCHIVE_STAMP="${IOS_IPA_CACHE_DIR}/archive_stamp.txt"

# Check for existing build artifacts
EXISTING_AAB=$(find build/app/outputs/bundle/release -name "*.aab" 2>/dev/null | head -1)
EXISTING_IPA=$(find build/ios/export -name "*.ipa" 2>/dev/null | head -1)
[[ -z "$EXISTING_IPA" && -f "$IOS_IPA_CACHE_DIR/last_upload.ipa" ]] && EXISTING_IPA="$IOS_IPA_CACHE_DIR/last_upload.ipa"

IOS_USE_EXISTING=false
ANDROID_USE_EXISTING=false
IOS_DO_EXPORT_ONLY=false

if $DO_IOS; then
  if [[ -n "$EXISTING_IPA" ]]; then
    echo -e "  ${BOLD}iOS build:${NC} existing IPA found → ${CYAN}$(basename "$EXISTING_IPA")${NC}"
    echo "    [Enter/1] New build"
    echo "    2) Use current build"
    read -r -p "    Choice: " IOS_BUILD_CHOICE
    [[ "$IOS_BUILD_CHOICE" == "2" ]] && IOS_USE_EXISTING=true
  else
    log "iOS: no existing IPA — will build fresh."
  fi
  echo ""
fi

if $DO_ANDROID; then
  if [[ -n "$EXISTING_AAB" ]]; then
    echo -e "  ${BOLD}Android build:${NC} existing AAB found → ${CYAN}$(basename "$EXISTING_AAB")${NC}"
    echo "    [Enter/1] New build"
    echo "    2) Use current build"
    read -r -p "    Choice: " ANDROID_BUILD_CHOICE
    [[ "$ANDROID_BUILD_CHOICE" == "2" ]] && ANDROID_USE_EXISTING=true
  else
    log "Android: no existing AAB — will build fresh."
  fi
  echo ""
fi

# ── BUMP BUILD NUMBER ─────────────────────────────────────────
if [[ "$VERSION_NAME+$NEW_BUILD" != "$CURRENT" ]]; then
  log "Bumping version → $VERSION_NAME+$NEW_BUILD..."
  sed -i '' "s/^version: .*/version: ${VERSION_NAME}+${NEW_BUILD}/" pubspec.yaml
  success "pubspec.yaml → $VERSION_NAME+$NEW_BUILD"
else
  log "Version unchanged: $VERSION_NAME+$NEW_BUILD"
fi

# ── iOS EXPORT-ONLY (reuse .xcarchive; must decide after version bump) ──
if $DO_IOS && ! $IOS_USE_EXISTING; then
  PUB_VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
  _ios_can_export_only=false
  if [[ -d "build/ios/Runner.xcarchive" ]]; then
    _ios_can_export_only=true
  elif [[ -d "$IOS_ARCHIVE_CACHE" && -f "$IOS_ARCHIVE_STAMP" ]] && [[ "$(cat "$IOS_ARCHIVE_STAMP")" == "$PUB_VERSION" ]]; then
    _ios_can_export_only=true
  fi
  if $_ios_can_export_only; then
    if [[ "${IOS_EXPORT_ONLY:-}" == "1" ]]; then
      IOS_DO_EXPORT_ONLY=true
      log "iOS: IOS_EXPORT_ONLY=1 — export IPA only (skip pod, Flutter, archive)."
    else
      echo -e "  ${BOLD}iOS:${NC} .xcarchive available (pubspec ${PUB_VERSION})."
      echo "    [Enter/1] Full build"
      echo "    3) Export IPA only (reuse archive — no Flutter compile)"
      read -r -p "    Choice: " IOS_MODE_CHOICE
      [[ "$IOS_MODE_CHOICE" == "3" ]] && IOS_DO_EXPORT_ONLY=true
    fi
  fi
  if [[ "${IOS_EXPORT_ONLY:-}" == "1" ]] && ! $IOS_DO_EXPORT_ONLY; then
    error "IOS_EXPORT_ONLY=1 but no usable Runner.xcarchive for pubspec $(grep '^version:' pubspec.yaml | awk '{print $2}') (build/ or cache + archive_stamp.txt)."
  fi
  echo ""
fi

# ── FLUTTER CLEAN (once, before forking) ──────────────────────
# Cache Runner.xcarchive before clean (export-only retries after failed signing)
if [[ -d "build/ios/Runner.xcarchive" ]]; then
  _arch_ver=$(grep '^version:' pubspec.yaml | awk '{print $2}')
  rm -rf "$IOS_ARCHIVE_CACHE"
  mkdir -p "$IOS_IPA_CACHE_DIR"
  cp -R "build/ios/Runner.xcarchive" "$IOS_ARCHIVE_CACHE"
  echo "$_arch_ver" > "$IOS_ARCHIVE_STAMP"
  log "iOS: cached Runner.xcarchive + archive_stamp.txt → $IOS_ARCHIVE_CACHE"
fi

# Preserve iOS IPA outside build/ before clean (Android-only rebuilds still run flutter clean)
if [[ -d "build/ios/export" ]]; then
  _ipa_pre_clean=$(find build/ios/export -maxdepth 1 -name "*.ipa" 2>/dev/null | head -1)
  if [[ -n "$_ipa_pre_clean" ]]; then
    mkdir -p "$IOS_IPA_CACHE_DIR"
    cp -f "$_ipa_pre_clean" "$IOS_IPA_CACHE_DIR/last_upload.ipa"
    log "iOS: cached export IPA (survives flutter clean) → $IOS_IPA_CACHE_DIR/last_upload.ipa"
  fi
fi

# Skip clean+build if both platforms reuse existing artifacts
if $IOS_USE_EXISTING && $ANDROID_USE_EXISTING; then
  log "Both platforms using existing builds — skipping clean/build."
elif ( $DO_IOS && ! $IOS_USE_EXISTING ) || ( $DO_ANDROID && ! $ANDROID_USE_EXISTING ); then
  log "Flutter clean..."
  flutter clean
  success "Clean done"

  log "Flutter pub get..."
  flutter pub get
  success "Pub get done"
else
  log "Skipping clean — using existing build."
fi

if ( $DO_IOS && ! $IOS_USE_EXISTING ) || ( $DO_ANDROID && ! $ANDROID_USE_EXISTING ); then
  if $DO_IOS && ! $IOS_USE_EXISTING; then
    log "iOS build — Bundle ID: ${IOS_BUNDLE_ID:-<unknown>}"
  fi
  if $DO_ANDROID && ! $ANDROID_USE_EXISTING; then
    log "Android build — applicationId: ${ANDROID_PACKAGE_NAME:-<unknown>}"
  fi
fi

# ── PARALLEL PIPELINES ────────────────────────────────────────
rm -f /tmp/deploy_ios_XXXX.log /tmp/deploy_android_XXXX.log
IOS_LOG=$(mktemp /tmp/deploy_ios_XXXX.log)
ANDROID_LOG=$(mktemp /tmp/deploy_android_XXXX.log)
IOS_PID=""
ANDROID_PID=""

# ── iOS pipeline ──────────────────────────────────────────────
run_ios() {
  local log_file="$1"

  local PBXPROJ="ios/Runner.xcodeproj/project.pbxproj"
  local INFO_PLIST="ios/Runner/Info.plist"
  local WORKSPACE="ios/Runner.xcworkspace"
  local ARCHIVE_PATH="build/ios/Runner.xcarchive"
  local EXPORT_PATH="build/ios/export"
  local EXPORT_PLIST="/tmp/ExportOptions_flutter_deploy.plist"

  local APP_NAME
  APP_NAME=$(grep -A1 'CFBundleDisplayName' "$INFO_PLIST" \
    | grep '<string>' | sed 's/.*<string>//;s/<\/string>//' | tr -d '\t')
  [[ -z "$APP_NAME" ]] && APP_NAME=$(grep '^name:' pubspec.yaml | awk '{print $2}')

  local BUNDLE_ID
  BUNDLE_ID=$(grep 'PRODUCT_BUNDLE_IDENTIFIER' "$PBXPROJ" \
    | grep -v '\$(' | head -1 \
    | sed 's/.*PRODUCT_BUNDLE_IDENTIFIER = //;s/;//;s/^[[:space:]]*//' | tr -d '"')

  local TEAM_ID="${IOS_TEAM_ID}"
  [[ -z "$TEAM_ID" ]] && TEAM_ID=$(grep 'DEVELOPMENT_TEAM' "$PBXPROJ" \
    | grep -v '""' | head -1 \
    | sed 's/.*DEVELOPMENT_TEAM = //;s/;//;s/^[[:space:]]*//' | tr -d '"')

  local SCHEME="Runner"
  local P8_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${APP_STORE_API_KEY_ID}.p8"

  {
    echo "[iOS] Starting..."
    echo "[iOS] Bundle ID: $BUNDLE_ID"
    [[ ! -f "$P8_FILE" ]] && echo "[iOS] ERROR: Missing .p8 key: $P8_FILE" && exit 1

    echo "[iOS] Writing ExportOptions.plist..."
    python3 -c "
import plistlib
data = {
    'method': 'app-store-connect',
    'teamID': '${TEAM_ID}',
    'signingStyle': 'automatic',
    'uploadBitcode': False,
    'uploadSymbols': True,
    'compileBitcode': False,
}
with open('${EXPORT_PLIST}', 'wb') as f:
    plistlib.dump(data, f)
"

    local IPA_PATH=""

    if [[ "$IOS_USE_EXISTING" == "true" ]]; then
      echo "[iOS] Using existing build..."
      IPA_PATH=$(find "$EXPORT_PATH" -name "*.ipa" 2>/dev/null | head -1)
      [[ -z "$IPA_PATH" && -f "${IOS_IPA_CACHE_DIR}/last_upload.ipa" ]] && IPA_PATH="${IOS_IPA_CACHE_DIR}/last_upload.ipa"
      [[ -z "$IPA_PATH" ]] && echo "[iOS] ERROR: No existing IPA found (build/ios/export or cache)." && exit 1
      echo "[iOS] Reusing: $IPA_PATH"
    elif [[ "$IOS_DO_EXPORT_ONLY" == "true" ]]; then
      echo "[iOS] Export-only (reuse .xcarchive)..."
      PUB_VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
      if [[ ! -d "$ARCHIVE_PATH" ]]; then
        if [[ -d "$IOS_ARCHIVE_CACHE" && -f "$IOS_ARCHIVE_STAMP" ]] && [[ "$(cat "$IOS_ARCHIVE_STAMP")" == "$PUB_VERSION" ]]; then
          mkdir -p "build/ios"
          rm -rf "$ARCHIVE_PATH"
          cp -R "$IOS_ARCHIVE_CACHE" "$ARCHIVE_PATH"
          echo "[iOS] Restored Runner.xcarchive from cache."
        else
          echo "[iOS] ERROR: build/ios/Runner.xcarchive missing and no cache for version $PUB_VERSION."
          exit 1
        fi
      fi
      [[ ! -d "$ARCHIVE_PATH" ]] && echo "[iOS] ERROR: Archive not found at $ARCHIVE_PATH" && exit 1

      echo "[iOS] Export IPA..."
      xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$P8_FILE" \
        -authenticationKeyID "$APP_STORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APP_STORE_API_ISSUER_ID" \
        | xcpretty 2>/dev/null || true

      IPA_PATH=$(find "$EXPORT_PATH" -name "*.ipa" 2>/dev/null | head -1)
      [[ -z "$IPA_PATH" ]] && echo "[iOS] ERROR: IPA not found." && exit 1
      mkdir -p "${IOS_IPA_CACHE_DIR}"
      cp -f "$IPA_PATH" "${IOS_IPA_CACHE_DIR}/last_upload.ipa"
      echo "[iOS] Cached export for next deploy → ${IOS_IPA_CACHE_DIR}/last_upload.ipa"
    else
      echo "[iOS] Pod install..."
      cd ios && pod install --repo-update && cd ..

      echo "[iOS] Flutter build iOS..."
      flutter build ios --release --no-codesign

      echo "[iOS] Xcode archive..."
      xcodebuild archive \
        -workspace "$WORKSPACE" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -destination "generic/platform=iOS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$P8_FILE" \
        -authenticationKeyID "$APP_STORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APP_STORE_API_ISSUER_ID" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        | xcpretty 2>/dev/null || true

      [[ ! -d "$ARCHIVE_PATH" ]] && echo "[iOS] ERROR: Archive failed." && exit 1

      echo "[iOS] Export IPA..."
      xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$P8_FILE" \
        -authenticationKeyID "$APP_STORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APP_STORE_API_ISSUER_ID" \
        | xcpretty 2>/dev/null || true

      IPA_PATH=$(find "$EXPORT_PATH" -name "*.ipa" 2>/dev/null | head -1)
      [[ -z "$IPA_PATH" ]] && echo "[iOS] ERROR: IPA not found." && exit 1
      mkdir -p "${IOS_IPA_CACHE_DIR}"
      cp -f "$IPA_PATH" "${IOS_IPA_CACHE_DIR}/last_upload.ipa"
      echo "[iOS] Cached export for next deploy → ${IOS_IPA_CACHE_DIR}/last_upload.ipa"
    fi

    echo "[iOS] Validating IPA..."
    xcrun altool \
      --validate-app \
      --type ios \
      --file "$IPA_PATH" \
      --apiKey "$APP_STORE_API_KEY_ID" \
      --apiIssuer "$APP_STORE_API_ISSUER_ID" \
      --verbose

    echo "[iOS] Upload to TestFlight..."
    xcrun altool \
      --upload-app \
      --type ios \
      --file "$IPA_PATH" \
      --apiKey "$APP_STORE_API_KEY_ID" \
      --apiIssuer "$APP_STORE_API_ISSUER_ID" \
      --verbose
    echo "[iOS] Upload: SUCCESS"

    echo "[iOS] Done ✅"
  } >> "$log_file" 2>&1
}

# ── Android pipeline ──────────────────────────────────────────
run_android() {
  local log_file="$1"
  {
    echo "[Android] Starting..."
    echo "[Android] applicationId: $ANDROID_PACKAGE_NAME"

    # FIX: Removed bundletool check — it's not used in this pipeline.
    # If you need local APK set generation, add bundletool calls explicitly.

    if ! command -v fastlane &>/dev/null; then
      echo "[Android] ERROR: fastlane not found. Install via: gem install fastlane"
      exit 1
    fi

    local AAB_PATH=""

    if [[ "$ANDROID_USE_EXISTING" == "true" ]]; then
      echo "[Android] Using existing build..."
      AAB_PATH=$(find build/app/outputs/bundle/release -name "*.aab" 2>/dev/null | head -1)
      [[ -z "$AAB_PATH" ]] && echo "[Android] ERROR: No existing AAB found." && exit 1
      echo "[Android] Reusing: $AAB_PATH"
    else
      # FIX: Verify keystore env vars are set before attempting release build
      if [[ -n "${KEYSTORE_PATH:-}" ]]; then
        if [[ ! -f "$KEYSTORE_PATH" ]]; then
          echo "[Android] ERROR: KEYSTORE_PATH set but file not found: $KEYSTORE_PATH"
          exit 1
        fi
        echo "[Android] Keystore: $KEYSTORE_PATH ✓"
      else
        echo "[Android] WARNING: KEYSTORE_PATH not set — assuming signing is configured in build.gradle directly."
      fi

      echo "[Android] Flutter build appbundle..."
      flutter build appbundle \
        --release \
        --obfuscate \
        --split-debug-info=build/debug-info

      AAB_PATH=$(find build/app/outputs/bundle/release -name "*.aab" 2>/dev/null | head -1)
      [[ -z "$AAB_PATH" ]] && echo "[Android] ERROR: .aab not found." && exit 1
    fi
    echo "[Android] AAB: $AAB_PATH"

    echo "[Android] Uploading to Play Store (track: $ANDROID_TRACK)..."

    fastlane supply \
      --aab "$AAB_PATH" \
      --track "$ANDROID_TRACK" \
      --package_name "$ANDROID_PACKAGE_NAME" \
      --json_key "$ANDROID_SERVICE_ACCOUNT_JSON" \


    local SUPPLY_EXIT=$?

    [[ "$SUPPLY_EXIT" -ne 0 ]] && echo "[Android] ERROR: fastlane supply failed (exit $SUPPLY_EXIT)." && exit "$SUPPLY_EXIT"

    # Auto-promote to production after Play Store processes the build
    if ! python3 -c "import google.oauth2.service_account; import googleapiclient.discovery" 2>/dev/null; then
      pip3 install --quiet google-api-python-client google-auth 2>/dev/null || true
    fi

    echo "[Android] Waiting 4 min for Play Store to process build $NEW_BUILD..."
    sleep 240

    echo "[Android] Checking track status..."
    local _TRACKS_JSON
    _TRACKS_JSON=$(python3 - "$ANDROID_SERVICE_ACCOUNT_JSON" "$ANDROID_PACKAGE_NAME" "$NEW_BUILD" << 'PYEOF'
import sys, json
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build as gcp_build

sa_json      = sys.argv[1]
package      = sys.argv[2]
target_build = int(sys.argv[3])

creds   = Credentials.from_service_account_file(sa_json, scopes=["https://www.googleapis.com/auth/androidpublisher"])
service = gcp_build("androidpublisher", "v3", credentials=creds)
edit_id = service.edits().insert(packageName=package, body={}).execute()["id"]
try:
    tracks = service.edits().tracks().list(packageName=package, editId=edit_id).execute().get("tracks", [])
    result = {"build_found_on": None, "build_status": None}
    for t in tracks:
        for r in t.get("releases", []):
            if target_build in [int(v) for v in r.get("versionCodes", [])]:
                result["build_found_on"] = t.get("track", "")
                result["build_status"]   = r.get("status", "unknown")
    print(json.dumps(result))
finally:
    service.edits().delete(packageName=package, editId=edit_id).execute()
PYEOF
    ) || { echo "[Android] WARNING: Play API query failed — skipping auto-promote."; echo "[Android] Done ✅"; return; }

    local _FOUND_ON _STATUS
    _FOUND_ON=$(echo "$_TRACKS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['build_found_on'] or '')")
    _STATUS=$(echo "$_TRACKS_JSON"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['build_status'] or '')")

    echo "[Android] Build $NEW_BUILD → track: ${_FOUND_ON:-not found} [$_STATUS]"

    if [[ -n "$_FOUND_ON" && "$_FOUND_ON" != "production" && ( "$_STATUS" == "completed" || "$_STATUS" == "inProgress" ) ]]; then
      echo "[Android] Auto-promoting $_FOUND_ON → production..."
      fastlane supply \
        --track "$_FOUND_ON" \
        --track_promote_to production \
        --package_name "$ANDROID_PACKAGE_NAME" \
        --json_key "$ANDROID_SERVICE_ACCOUNT_JSON" \
        --skip_upload_metadata \
        --skip_upload_changelogs \
        --skip_upload_images \
        --skip_upload_screenshots
      echo "[Android] Promoted to production ✅"
    else
      echo "[Android] Status '$_STATUS' on '${_FOUND_ON:-unknown}' — skipping auto-promote."
    fi

    echo "[Android] Done ✅"
  } >> "$log_file" 2>&1
}

# ── FORK PIPELINES ────────────────────────────────────────────
if $DO_IOS && $DO_ANDROID; then
  log "Starting iOS + Android pipelines in parallel..."
  run_ios     "$IOS_LOG"     & IOS_PID=$!
  run_android "$ANDROID_LOG" & ANDROID_PID=$!
elif $DO_IOS; then
  log "Starting iOS pipeline..."
  run_ios "$IOS_LOG" & IOS_PID=$!
elif $DO_ANDROID; then
  log "Starting Android pipeline..."
  run_android "$ANDROID_LOG" & ANDROID_PID=$!
fi

# ── LIVE LOG TAIL ─────────────────────────────────────────────
if $DO_IOS && $DO_ANDROID; then
  tail -f "$IOS_LOG" "$ANDROID_LOG" &
  TAIL_PID=$!
elif $DO_IOS; then
  tail -f "$IOS_LOG" & TAIL_PID=$!
else
  tail -f "$ANDROID_LOG" & TAIL_PID=$!
fi

# ── WAIT + RESULTS ────────────────────────────────────────────
# FIX: Capture exit codes properly. The original `&& wait || IOS_EXIT=$?` pattern
# is broken — if the [[ ]] condition is true but wait succeeds, $? is 0 and
# IOS_EXIT is never set; if wait fails, || captures $? of wait, not the job.
# Correct pattern: run wait unconditionally, then capture $?.
IOS_EXIT=0
ANDROID_EXIT=0

if [[ -n "$IOS_PID" ]]; then
  wait "$IOS_PID"
  IOS_EXIT=$?
fi
if [[ -n "$ANDROID_PID" ]]; then
  wait "$ANDROID_PID"
  ANDROID_EXIT=$?
fi

kill "$TAIL_PID" 2>/dev/null || true
sleep 0.2   # let tail flush

echo ""
echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Results — $VERSION_NAME+$NEW_BUILD"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if $DO_IOS; then
  if [[ "$IOS_EXIT" -eq 0 ]]; then
    success "iOS   → TestFlight ✅"
    if grep -q "\[iOS\] Upload: SUCCESS" "$IOS_LOG"; then
      echo -e "    App Store Upload   : ${GREEN}Uploaded ✅${NC}"
    else
      echo -e "    App Store Upload   : ${YELLOW}Unknown${NC}"
    fi
  else
    echo -e "${RED}[✗] iOS   → FAILED (see $IOS_LOG)${NC}"
    if grep -q "\[iOS\] Upload: SUCCESS" "$IOS_LOG"; then
      echo -e "    App Store Upload   : ${GREEN}Uploaded ✅${NC}"
    else
      echo -e "    App Store Upload   : ${RED}Failed ❌${NC}"
    fi
  fi
fi
if $DO_ANDROID; then
  if [[ "$ANDROID_EXIT" -eq 0 ]]; then
    success "Android → Play Store ($ANDROID_TRACK) ✅"
  else
    echo -e "${RED}[✗] Android → FAILED (see $ANDROID_LOG)${NC}"
  fi
fi
echo ""

# Exit non-zero if any pipeline failed
[[ "$IOS_EXIT" -ne 0 || "$ANDROID_EXIT" -ne 0 ]] && exit 1
exit 0