#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/build"
OUTPUT_IPA="$OUTPUT_DIR/DawnPilot.ipa"
ALLOW_NONINCREASING_BUILD="${DAWNPILOT_ALLOW_NONINCREASING_BUILD:-false}"

case "$ALLOW_NONINCREASING_BUILD" in
    1|true|TRUE|yes|YES)
        ALLOW_NONINCREASING_BUILD=true
        ;;
    0|false|FALSE|no|NO)
        ALLOW_NONINCREASING_BUILD=false
        ;;
    *)
        echo "error: DAWNPILOT_ALLOW_NONINCREASING_BUILD must be true or false" >&2
        exit 1
        ;;
esac

DERIVED_DATA="$(mktemp -d /tmp/DawnPilot-AltStore-DerivedData.XXXXXX)"
PACKAGE_ROOT="$(mktemp -d /tmp/DawnPilot-AltStore-Package.XXXXXX)"
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
    -name '*.mobileprovision' -o \
    -name '*.p12' -o \
    -name '*.pem' -o \
    -name '*.key' -o \
    -name '.env*' -o \
    -name 'cache.json' -o \
    -name '*.sqlite' -o \
    -name '*.sqlite3' -o \
    -name '*.xcuserstate' -o \
    -name 'xcuserdata' \
\) -print -quit)"
if [[ -n "$forbidden_content" ]]; then
    echo "error: forbidden AltStore package content remains: $forbidden_content" >&2
    exit 1
fi

app_count="$(find "$PACKAGE_ROOT/Payload" -type d -name '*.app' -print | wc -l | tr -d '[:space:]')"
if [[ "$app_count" != "1" ]] || [[ ! -d "$STAGED_APP" ]]; then
    echo "error: IPA must contain exactly one Payload/DawnPilot.app" >&2
    echo "error: found $app_count app bundles" >&2
    exit 1
fi

if LC_ALL=C grep -RIlE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|DAWNPILOT_TOKEN=' \
    "$STAGED_APP" >/dev/null 2>&1; then
    echo "error: credential-like content was found in the staged app" >&2
    exit 1
fi

if codesign -d "$STAGED_APP" >/dev/null 2>&1 \
    || codesign -d "$STAGED_APP/DawnPilot" >/dev/null 2>&1; then
    echo "error: AltStore input app must be unsigned" >&2
    exit 1
fi

architectures="$(lipo -archs "$STAGED_APP/DawnPilot")"
if [[ "$architectures" != "arm64" ]]; then
    echo "error: AltStore input must contain only arm64 (found: $architectures)" >&2
    exit 1
fi

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$STAGED_APP/Info.plist")"
if [[ "$bundle_identifier" != "com.yessicmd.dawnpilot" ]]; then
    echo "error: unexpected bundle identifier: $bundle_identifier" >&2
    exit 1
fi

bundle_package_type="$(plutil -extract CFBundlePackageType raw "$STAGED_APP/Info.plist")"
bundle_executable="$(plutil -extract CFBundleExecutable raw "$STAGED_APP/Info.plist")"
requires_iphone="$(plutil -extract LSRequiresIPhoneOS raw "$STAGED_APP/Info.plist")"
icon_name="$(
    plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName \
        raw "$STAGED_APP/Info.plist"
)"
device_family="$(plutil -extract UIDeviceFamily.0 raw "$STAGED_APP/Info.plist")"
if [[ "$bundle_package_type" != "APPL" \
    || "$bundle_executable" != "DawnPilot" \
    || "$requires_iphone" != "true" \
    || "$icon_name" != "AppIcon" \
    || "$device_family" != "1" ]]; then
    echo "error: required iPhone application metadata is missing or invalid" >&2
    exit 1
fi
if plutil -extract UIDeviceFamily.1 raw "$STAGED_APP/Info.plist" >/dev/null 2>&1; then
    echo "error: AltStore input must target only the iPhone device family" >&2
    exit 1
fi
if [[ ! -f "$STAGED_APP/Assets.car" ]] \
    || ! find "$STAGED_APP" -maxdepth 1 -name 'AppIcon*.png' -print -quit \
        | grep -q .; then
    echo "error: compiled AppIcon assets are missing" >&2
    exit 1
fi

minimum_os="$(plutil -extract MinimumOSVersion raw "$STAGED_APP/Info.plist")"
platform="$(plutil -extract CFBundleSupportedPlatforms.0 raw "$STAGED_APP/Info.plist")"
if [[ "$platform" != "iPhoneOS" || "$minimum_os" != "26.0" ]]; then
    echo "error: unexpected platform or minimum OS: $platform / $minimum_os" >&2
    exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw "$STAGED_APP/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw "$STAGED_APP/Info.plist")"
if [[ ! "$build_number" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "error: build number must contain only dot-separated integers: $build_number" >&2
    exit 1
fi

if [[ -f "$OUTPUT_IPA" ]]; then
    existing_info="$DERIVED_DATA/existing-Info.plist"
    existing_info_count="$(
        unzip -Z1 "$OUTPUT_IPA" \
            | awk '$0 == "Payload/DawnPilot.app/Info.plist" {count++} END {print count+0}'
    )"
    if [[ "$existing_info_count" != "1" ]]; then
        echo "error: existing canonical IPA has no unique DawnPilot Info.plist" >&2
        echo "error: inspect it before replacement" >&2
        exit 1
    fi
    unzip -p "$OUTPUT_IPA" Payload/DawnPilot.app/Info.plist > "$existing_info"
    existing_bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$existing_info")"
    existing_build_number="$(plutil -extract CFBundleVersion raw "$existing_info")"
    if [[ "$existing_bundle_identifier" != "$bundle_identifier" ]]; then
        echo "error: existing canonical IPA has a different bundle identifier" >&2
        exit 1
    fi
    if [[ ! "$existing_build_number" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
        echo "error: existing canonical IPA has an invalid build number: $existing_build_number" >&2
        exit 1
    fi
    if ! awk -v candidate="$build_number" -v existing="$existing_build_number" '
        BEGIN {
            candidate_count = split(candidate, candidate_parts, ".");
            existing_count = split(existing, existing_parts, ".");
            count = candidate_count > existing_count ? candidate_count : existing_count;
            for (part_index = 1; part_index <= count; part_index++) {
                candidate_value = 0;
                existing_value = 0;
                if (part_index <= candidate_count) {
                    candidate_value = candidate_parts[part_index] + 0;
                }
                if (part_index <= existing_count) {
                    existing_value = existing_parts[part_index] + 0;
                }
                if (candidate_value > existing_value) exit 0;
                if (candidate_value < existing_value) exit 1;
            }
            exit 1;
        }
    '; then
        if [[ "$ALLOW_NONINCREASING_BUILD" != "true" ]]; then
            echo "error: candidate build is not newer than the existing build" >&2
            echo "error: candidate $build_number, existing $existing_build_number" >&2
            echo "error: explicitly approve a replacement by setting" >&2
            echo "error: DAWNPILOT_ALLOW_NONINCREASING_BUILD=true" >&2
            exit 1
        fi
        echo "warning: explicit override allows non-increasing build replacement" >&2
        echo "warning: existing $existing_build_number, candidate $build_number" >&2
    fi
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
zip_app_roots="$(unzip -Z1 "$TEMP_IPA" | awk -F/ '
    {
        path = "";
        for (path_index = 1; path_index <= NF; path_index++) {
            path = path (path_index == 1 ? "" : "/") $path_index;
            if ($path_index ~ /[.]app$/) print path;
        }
    }
' | sort -u)"
if [[ "$zip_app_roots" != "Payload/DawnPilot.app" ]]; then
    echo "error: IPA must contain exactly one app bundle: $zip_app_roots" >&2
    exit 1
fi

checksum="$(shasum -a 256 "$TEMP_IPA" | awk '{print $1}')"
file_size="$(stat -f '%z' "$TEMP_IPA")"

mv -f "$TEMP_IPA" "$OUTPUT_IPA"
echo "Created: $OUTPUT_IPA"
echo "Version: $version ($build_number)"
echo "Bundle ID: $bundle_identifier"
echo "App icon: $icon_name"
echo "Platform: $platform, minimum iOS: $minimum_os"
echo "Architectures: $architectures"
echo "Size: $file_size bytes"
echo "SHA-256: $checksum"
