#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build" "$project_root/../output"
xcodebuild -project "$project_root/Guoju.xcodeproj" -scheme Guoju \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$project_root/build/device" -allowProvisioningUpdates build \
  > "$project_root/build/device-build.log" 2>&1
app_path="$project_root/build/device/Build/Products/Release-iphoneos/Guoju.app"
codesign --verify --deep --strict "$app_path"
stage="$(mktemp -d "${TMPDIR:-/tmp}/guoju-ipa.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$app_path" "$stage/Payload/Guoju.app"
ipa_path="$project_root/../output/Guoju-Native-iOS-1.0.0.ipa"
ditto -c -k --keepParent "$stage/Payload" "$ipa_path"
shasum -a 256 "$ipa_path"
