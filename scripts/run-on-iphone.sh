#!/usr/bin/env bash

# Usage:
#   ./scripts/run-on-iphone.sh
#   ./scripts/run-on-iphone.sh launch
#   ./scripts/run-on-iphone.sh console
#
# Modes:
#   launch   Generate, clean build, install, and launch the app. Default.
#   console  Generate, clean build, install, and launch attached with
#            `devicectl --console`. This attaches stdio only; Swift `Logger`
#            output on a physical iPhone is better viewed in Xcode or
#            Console.app on macOS.
#
# Environment overrides:
#   DEVICE_ID  Target device UDID.
#   CATVOX_IOS_SCHEME
#   CATVOX_IOS_BUNDLE_ID
#   IOS_CONFIGURATION
#   CATVOX_APP_CHECK_DEBUG_TOKEN or TF_VAR_app_check_debug_token
#              Registered Firebase App Check debug token for Debug builds.
#              Falls back to terraform/terraform.tfvars app_check_debug_token.

set -euo pipefail

DEVICE_ID="${DEVICE_ID:-264DA990-A302-5C43-8D51-91BB11C7A1E4}"
SCHEME="${CATVOX_IOS_SCHEME:-CatVox}"
PROJECT="CatVox.xcodeproj"
CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
BUNDLE_ID="${CATVOX_IOS_BUNDLE_ID:-com.kathelix.catvox}"
DERIVED_DATA_PATH=".build/ios-device"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
MODE="${1:-launch}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# shellcheck source=scripts/lib/app-check-debug-token.sh
source "${SCRIPT_DIR}/lib/app-check-debug-token.sh"

usage() {
  cat <<EOF
Usage: ./scripts/run-on-iphone.sh [launch|console]

Modes:
  launch   Generate, clean build, install, and launch the app. Default.
  console  Generate, clean build, install, and launch attached with devicectl --console.
           For Swift Logger output on a physical iPhone, use Xcode's console
           or Console.app on macOS.

Environment overrides:
  DEVICE_ID  Target device UDID. Current default: ${DEVICE_ID}
  CATVOX_IOS_SCHEME     Current default: ${SCHEME}
  CATVOX_IOS_BUNDLE_ID  Current default: ${BUNDLE_ID}
  IOS_CONFIGURATION      Current default: ${CONFIGURATION}
  CATVOX_APP_CHECK_DEBUG_TOKEN or TF_VAR_app_check_debug_token
             Registered Firebase App Check debug token for Debug builds.
             Falls back to terraform/terraform.tfvars app_check_debug_token.
EOF
}

app_check_debug_token="$(read_catvox_app_check_debug_token)"

case "${MODE}" in
  launch|console)
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown mode: ${MODE}" >&2
    usage >&2
    exit 1
    ;;
esac

for tool in xcodegen xcodebuild xcrun; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
done

echo "Generating Xcode project..."
xcodegen generate

echo "Cleaning derived data at ${DERIVED_DATA_PATH}..."
rm -rf "${DERIVED_DATA_PATH}"

echo "Building ${SCHEME} for device ${DEVICE_ID}..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "id=${DEVICE_ID}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  clean build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Installing app on device ${DEVICE_ID}..."
xcrun devicectl device install app \
  --device "${DEVICE_ID}" \
  "${APP_PATH}"

echo "Launching ${BUNDLE_ID} on device ${DEVICE_ID}..."
if [[ -n "${app_check_debug_token}" ]]; then
  export DEVICECTL_CHILD_AppCheckDebugToken="${app_check_debug_token}"
  echo "Using registered App Check debug token from local environment for this Debug launch."
fi

if [[ "${MODE}" == "console" ]]; then
  xcrun devicectl device process launch \
    --device "${DEVICE_ID}" \
    "${BUNDLE_ID}" \
    --terminate-existing \
    --console
else
  xcrun devicectl device process launch \
    --device "${DEVICE_ID}" \
    "${BUNDLE_ID}" \
    --terminate-existing
fi

echo "Done."
