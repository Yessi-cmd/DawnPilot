#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$(mktemp -d /tmp/DawnPilot-AltStore-DerivedData.XXXXXX)"
PACKAGE_ROOT="$(mktemp -d /tmp/DawnPilot-AltStore-Package.XXXXXX)"
OUTPUT_DIR="$PROJECT_ROOT/build"
OUTPUT_IPA="$OUTPUT_DIR/DawnPilot.ipa"
TEMP_IPA="$OUTPUT_DIR/.DawnPilot.ipa.tmp.$$"

cleanup() {
    rm -rf "$DERIVED_DATA" "$PACKAGE_ROOT"
    rm -f "$TEMP_IPA"
}
trap cleanup EXIT

command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen is required" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"

(
    cd "$PROJECT_ROOT"
    xcodegen generate
)

xcodebuild \
    -project "$PROJECT_ROOT/DawnPilot.xcodeproj" \
    -scheme DawnPilot \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    clean build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=''

SOURCE_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/DawnPilot.app"
STAGED_APP="$PACKAGE_ROOT/Payload/DawnPilot.app"

if [[ ! -x "$SOURCE_APP/DawnPilot" ]]; then
    echo "error: unsigned app product was not created" >&2
    exit 1
fi

mkdir -p "$PACKAGE_ROOT/Payload"
ditto "$SOURCE_APP" "$STAGED_APP"

rm -rf "$STAGED_APP/PlugIns"
find "$STAGED_APP" -type d -name _CodeSignature -prune -exec rm -rf {} +
find "$STAGED_APP" -name embedded.mobileprovision -delete
xattr -cr "$STAGED_APP"

forbidden_content="$(find "$STAGED_APP" \( \
    -name '*.appex' -o \
    -name PlugIns -o \
    -name _CodeSignature -o \
    -name embedded.mobileprovision -o \
    -name '.env*' \
\) -print -quit)"
if [[ -n "$forbidden_content" ]]; then
    echo "error: forbidden AltStore package content remains: $forbidden_content" >&2
    exit 1
fi

if codesign --verify --deep --strict "$STAGED_APP" >/dev/null 2>&1; then
    echo "error: AltStore input app must be unsigned" >&2
    exit 1
fi

architectures="$(lipo -archs "$STAGED_APP/DawnPilot")"
if [[ " $architectures " != *" arm64 "* ]]; then
    echo "error: arm64 architecture is missing: $architectures" >&2
    exit 1
fi

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$STAGED_APP/Info.plist")"
if [[ "$bundle_identifier" != "com.yessicmd.dawnpilot" ]]; then
    echo "error: unexpected bundle identifier: $bundle_identifier" >&2
    exit 1
fi

requires_iphone="$(plutil -extract LSRequiresIPhoneOS raw "$STAGED_APP/Info.plist")"
icon_name="$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw "$STAGED_APP/Info.plist")"
if [[ "$requires_iphone" != "true" || "$icon_name" != "AppIcon" ]]; then
    echo "error: required iPhone or AppIcon metadata is missing" >&2
    exit 1
fi
if [[ ! -f "$STAGED_APP/Assets.car" ]] || ! find "$STAGED_APP" -maxdepth 1 -name 'AppIcon*.png' -print -quit | grep -q .; then
    echo "error: compiled AppIcon assets are missing" >&2
    exit 1
fi

minimum_os="$(plutil -extract MinimumOSVersion raw "$STAGED_APP/Info.plist")"
platform="$(plutil -extract CFBundleSupportedPlatforms.0 raw "$STAGED_APP/Info.plist")"
if [[ "$platform" != "iPhoneOS" ]]; then
    echo "error: unexpected build platform: $platform" >&2
    exit 1
fi

rm -f "$TEMP_IPA"
(
    cd "$PACKAGE_ROOT"
    COPYFILE_DISABLE=1 /usr/bin/zip -qry "$TEMP_IPA" Payload
)
unzip -tq "$TEMP_IPA" >/dev/null

top_levels="$(unzip -Z1 "$TEMP_IPA" | awk -F/ 'NF {print $1}' | sort -u)"
if [[ "$top_levels" != "Payload" ]]; then
    echo "error: unexpected IPA top-level content: $top_levels" >&2
    exit 1
fi

mv -f "$TEMP_IPA" "$OUTPUT_IPA"

version="$(plutil -extract CFBundleShortVersionString raw "$STAGED_APP/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw "$STAGED_APP/Info.plist")"
checksum="$(shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')"

echo "Created: $OUTPUT_IPA"
echo "Version: $version ($build_number)"
echo "Bundle ID: $bundle_identifier"
echo "App icon: $icon_name"
echo "Platform: $platform, minimum iOS: $minimum_os"
echo "Architectures: $architectures"
echo "SHA-256: $checksum"
