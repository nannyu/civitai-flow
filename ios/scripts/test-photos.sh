#!/bin/bash
set -euo pipefail

# Run real PhotoKit imports in a disposable simulator, never in a connected phone's library.
photo_check_ios="$(cd "$(dirname "$0")/.." && pwd)"
photo_check_output="${FLOW_PHOTO_CHECK_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/FlowPhotosChecks.XXXXXX")}"
photo_check_device="${FLOW_PHOTO_SIMULATOR_ID:-}"
photo_check_created=false
mkdir -p "$photo_check_output"

cleanup() {
  if [[ "$photo_check_created" == true ]]; then
    xcrun simctl shutdown "$photo_check_device" >/dev/null 2>&1 || true
    xcrun simctl delete "$photo_check_device" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

command -v xcodegen >/dev/null || { echo "Install XcodeGen before running these iOS integration checks." >&2; exit 1; }
if [[ -z "$photo_check_device" ]]; then
  photo_check_runtime="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; r=[x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; print(sorted(r)[-1] if r else "")')"
  [[ -n "$photo_check_runtime" ]] || { echo "Install an iOS Simulator runtime in Xcode first." >&2; exit 1; }
  photo_check_device="$(xcrun simctl create 'Flow Photos Checks' com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$photo_check_runtime")"
  photo_check_created=true
  xcrun simctl boot "$photo_check_device"
fi
xcrun simctl bootstatus "$photo_check_device" -b

FLOW_PHOTO_SOURCE_ROOT="$photo_check_ios" xcodegen generate \
  --spec "$photo_check_ios/PhotoSaveChecks/project.yml" \
  --project "$photo_check_output" --project-root "$photo_check_output"
xcodebuild -project "$photo_check_output/PhotoSaveChecks.xcodeproj" -scheme PhotoSaveChecks \
  -destination "platform=iOS Simulator,id=$photo_check_device" \
  -derivedDataPath "$photo_check_output/DerivedData" build-for-testing
xcrun simctl install "$photo_check_device" "$photo_check_output/DerivedData/Build/Products/Debug-iphonesimulator/PhotoSaveCheckHost.app"
# Only this separate test host requests read access, to verify test IDs and exported bytes.
xcrun simctl privacy "$photo_check_device" grant photos app.civitai.flow.photo-checks
xcodebuild -project "$photo_check_output/PhotoSaveChecks.xcodeproj" -scheme PhotoSaveChecks \
  -destination "platform=iOS Simulator,id=$photo_check_device" \
  -derivedDataPath "$photo_check_output/DerivedData" -parallel-testing-enabled NO \
  test-without-building
printf 'PhotoKit check results: %s\n' "$photo_check_output/DerivedData/Logs/Test"
