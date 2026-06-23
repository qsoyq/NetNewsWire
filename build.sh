#!/usr/bin/env bash
set -euo pipefail

# ========= Config =========
PROJECT_PATH="NetNewsWire.xcodeproj"
SCHEME_MAC="NetNewsWire"
TARGET_IOS="NetNewsWire-iOS"

CONFIGURATION="Release"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${ROOT_DIR}/build/release"
DERIVED_DATA="${OUT_DIR}/DerivedData"

APP_NAME_MAC="NetNewsWire.app"
APP_NAME_IOS="NetNewsWire.app"

MODE="${1:-all}" # mac | ios | all

mkdir -p "${OUT_DIR}"

log() { printf "\n[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }

build_mac() {
  local DMG_PATH="${OUT_DIR}/NetNewsWire-macOS.dmg"
  local DMG_STAGING_DIR="${OUT_DIR}/mac-dmg"

  log "Building macOS app..."
  set +e
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME_MAC}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    clean build
  local BUILD_EXIT=$?
  set -e

  local APP_PATH
  APP_PATH="$(find "${DERIVED_DATA}/Build/Products/Release" -maxdepth 1 -type d -name "${APP_NAME_MAC}" | head -n 1 || true)"

  if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
    echo "macOS build failed (exit code ${BUILD_EXIT}) and no .app found"
    exit 1
  fi

  if [[ ${BUILD_EXIT} -ne 0 ]]; then
    log "Warning: xcodebuild exited with ${BUILD_EXIT} (script phase errors), but .app was built successfully"
  fi

  log "Ad-hoc signing app bundle..."
  codesign --force --deep --sign - --timestamp=none "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

  log "Packaging DMG..."
  rm -rf "${DMG_STAGING_DIR}"
  mkdir -p "${DMG_STAGING_DIR}"
  cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"
  ln -s /Applications "${DMG_STAGING_DIR}/Applications"

  rm -f "${DMG_PATH}"
  hdiutil create \
    -volname "NetNewsWire" \
    -srcfolder "${DMG_STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

  log "macOS done: ${DMG_PATH}"
}

build_ios_unsigned_ipa() {
  local IOS_BUILD_DIR="${OUT_DIR}/ios-build"
  local PAYLOAD_DIR="${IOS_BUILD_DIR}/Payload"
  local IPA_PATH="${OUT_DIR}/NetNewsWire-iOS-unsigned.ipa"

  rm -rf "${IOS_BUILD_DIR}"
  mkdir -p "${PAYLOAD_DIR}"

  log "Building iOS app (unsigned; will ad-hoc sign post-build)..."
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -target "${TARGET_IOS}" \
    -configuration "${CONFIGURATION}" \
    SYMROOT="${DERIVED_DATA}/Build/Products" \
    OBJROOT="${DERIVED_DATA}/Build/Intermediates.noindex" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    clean build

  local APP_PATH
  APP_PATH="$(find "${DERIVED_DATA}/Build/Products" -type d -name "${APP_NAME_IOS}" | grep "Release-iphoneos" | head -n 1 || true)"

  if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
    echo "iOS app not found under ${DERIVED_DATA}/Build/Products/Release-iphoneos"
    exit 1
  fi

  log "Stripping PlugIns (LiveContainer cannot run app extensions)..."
  rm -rf "${APP_PATH}/PlugIns"

  log "Ad-hoc signing frameworks and app bundle..."
  if [[ -d "${APP_PATH}/Frameworks" ]]; then
    find "${APP_PATH}/Frameworks" -maxdepth 1 -name "*.framework" -print0 \
      | xargs -0 -I{} codesign --force --sign - --timestamp=none "{}"
  fi
  codesign --force --sign - --timestamp=none "${APP_PATH}"

  log "Packaging IPA..."
  cp -R "${APP_PATH}" "${PAYLOAD_DIR}/"
  (
    cd "${IOS_BUILD_DIR}"
    /usr/bin/zip -qry "${IPA_PATH}" Payload
  )

  log "iOS done: ${IPA_PATH}"
  log "Next: use your third-party signer to re-sign and install to iPhone."
}

case "${MODE}" in
  mac)
    build_mac
    ;;
  ios)
    build_ios_unsigned_ipa
    ;;
  all)
    build_mac
    build_ios_unsigned_ipa
    ;;
  *)
    echo "Usage: $0 [mac|ios|all]"
    exit 1
    ;;
esac

log "All requested tasks completed."
