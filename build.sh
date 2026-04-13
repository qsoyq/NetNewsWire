#!/usr/bin/env bash
set -euo pipefail

# ========= Config =========
PROJECT_PATH="NetNewsWire.xcodeproj"
SCHEME_MAC="NetNewsWire"
SCHEME_IOS="NetNewsWire-iOS"

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

  log "Building macOS app (unsigned)..."
  set +e
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME_MAC}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_ENTITLEMENTS="" \
    ENABLE_HARDENED_RUNTIME=NO \
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

  log "Packaging DMG..."
  rm -f "${DMG_PATH}"
  hdiutil create \
    -volname "NetNewsWire" \
    -srcfolder "${APP_PATH}" \
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

  log "Building iOS app (unsigned)..."
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME_IOS}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "${DERIVED_DATA}" \
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

  log "Packaging unsigned IPA..."
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
