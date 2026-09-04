#!/bin/bash

set -e

# Mirror chorulla_palli_app style: passwords are kept in-script as requested.
STORE_PASSWORD="test123"
KEY_PASSWORD="test123"
KEY_ALIAS="upload"
STORE_FILE_NAME="upload-keystore.p12"

# Debug keystore settings (same property names/style as reference app).
DEBUG_STORE_FILE_NAME="debug-app.p12"
DEBUG_KEYSTORE_PATH="${DEBUG_STORE_FILE_NAME}"
DEBUG_STORE_FILE="../../debug-app.p12"
DEBUG_STORE_PASSWORD="test123"
DEBUG_KEY_ALIAS="debug"
DEBUG_KEY_PASSWORD="test123"

KEYSTORE_PATH="android/app/${STORE_FILE_NAME}"
KEY_PROPERTIES_PATH="android/key.properties"
PROGUARD_RULES_FILE="android/app/proguard-rules.pro"

step_done() {
  echo "✓ $1"
}

step_skip() {
  echo "↷ $1 (already done)"
}

if ! command -v keytool >/dev/null 2>&1; then
  echo "Error: keytool is not installed or not in PATH."
  exit 1
fi

mkdir -p "android/app"
step_done "Checked prerequisites"

if [ -f "${KEYSTORE_PATH}" ]; then
  step_skip "Release keystore exists at ${KEYSTORE_PATH}"
else
  keytool -genkeypair -v \
    -storetype PKCS12 \
    -keystore "${KEYSTORE_PATH}" \
    -alias "${KEY_ALIAS}" \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -storepass "${STORE_PASSWORD}" \
    -keypass "${KEY_PASSWORD}" \
    -dname "CN=Android,O=Conceptmates,C=IN"
  step_done "Created release keystore at ${KEYSTORE_PATH}"
fi

if [ -f "${DEBUG_KEYSTORE_PATH}" ]; then
  step_skip "Debug keystore exists at ${DEBUG_KEYSTORE_PATH}"
else
  keytool -genkeypair -v \
    -storetype PKCS12 \
    -keystore "${DEBUG_KEYSTORE_PATH}" \
    -alias "${DEBUG_KEY_ALIAS}" \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -storepass "${DEBUG_STORE_PASSWORD}" \
    -keypass "${DEBUG_KEY_PASSWORD}" \
    -dname "CN=Android Debug,O=Conceptmates,C=IN"
  step_done "Created debug keystore at ${DEBUG_KEYSTORE_PATH}"
fi

key_props_content="$(cat <<EOF
storePassword=${STORE_PASSWORD}
keyPassword=${KEY_PASSWORD}
keyAlias=${KEY_ALIAS}
storeFile=${STORE_FILE_NAME}

# Debug keystore (debug-app.p12, alias: debug)
debugStoreFile=${DEBUG_STORE_FILE}
debugStorePassword=${DEBUG_STORE_PASSWORD}
debugKeyAlias=${DEBUG_KEY_ALIAS}
debugKeyPassword=${DEBUG_KEY_PASSWORD}
EOF
)"

if [ -f "${KEY_PROPERTIES_PATH}" ] && [ "$(cat "${KEY_PROPERTIES_PATH}")" = "${key_props_content}" ]; then
  step_skip "Key properties already up to date at ${KEY_PROPERTIES_PATH}"
else
  printf "%s\n" "${key_props_content}" > "${KEY_PROPERTIES_PATH}"
  step_done "Wrote key properties at ${KEY_PROPERTIES_PATH}"
fi

if [ ! -f "${PROGUARD_RULES_FILE}" ]; then
  touch "${PROGUARD_RULES_FILE}"
  step_done "Created ${PROGUARD_RULES_FILE}"
else
  step_skip "${PROGUARD_RULES_FILE} already exists"
fi

echo ""
echo "All signing setup checks completed."
echo "Next steps:"
echo "  flutter clean && flutter pub get"
echo "  flutter build apk --debug"
echo "  flutter build appbundle --release"
