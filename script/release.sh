#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---release}"
case "$MODE" in
  --release|release)
    ;;
  --preflight|preflight)
    ;;
  *)
    echo "usage: $0 [--release|--preflight]" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/packaging_common.sh"

APP_NAME="TaskScope"
MIN_SYSTEM_VERSION="14.0"
BUNDLE_ID="$(taskscope_resolve_bundle_id)"
APP_VERSION="$(taskscope_read_release_value "$ROOT_DIR/VERSION" "version")"
APP_BUILD_NUMBER="$(taskscope_read_release_value "$ROOT_DIR/BUILD_NUMBER" "build number")"
RELEASE_ARCHS="${TASKSCOPE_RELEASE_ARCHS:-arm64}"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_ROOT="$DIST_DIR/releases"
BASE_NAME="$APP_NAME-$APP_VERSION-macOS-arm64"
FINAL_DIR="$RELEASE_ROOT/$BASE_NAME"
RELEASE_LOCK="$DIST_DIR/.$APP_NAME.release.lock"
RELEASE_LOCK_ACQUIRED=0
WORK_DIR=""
PRESERVE_WORK=0

fail() {
  echo "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required release tool is unavailable: $1"
}

validate_credential_independent_inputs() {
  if [[ "$BUNDLE_ID" == com.local.* ]]; then
    fail "Public releases cannot use the development bundle identifier '$BUNDLE_ID'."
  fi
  if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    fail "Invalid VERSION value: $APP_VERSION"
  fi
  if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    fail "Invalid BUILD_NUMBER value: $APP_BUILD_NUMBER"
  fi
  if [[ "$RELEASE_ARCHS" != "arm64" ]]; then
    fail "The verified first-release architecture policy is arm64 only."
  fi
  if [[ "$(uname -m)" != "arm64" ]]; then
    fail "The arm64 release must be built on an arm64 Mac."
  fi

  require_command awk
  require_command codesign
  require_command ditto
  require_command dwarfdump
  require_command git
  require_command lipo
  require_command plutil
  require_command security
  require_command shasum
  require_command shlock
  require_command spctl
  require_command swift
  require_command xcodebuild
  require_command xcrun

  xcrun --find appintentsmetadataprocessor >/dev/null
  xcrun --find dsymutil >/dev/null
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null

  # Build numbers must increase for every distributed artifact: refuse to
  # release a build number that is not greater than the latest v* tag's.
  local latest_tag
  local tagged_build
  latest_tag="$(git -C "$ROOT_DIR" tag --list 'v*' --sort=-version:refname | head -n 1)"
  if [[ -n "$latest_tag" ]]; then
    tagged_build="$(git -C "$ROOT_DIR" show "$latest_tag:BUILD_NUMBER" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$tagged_build" =~ ^[0-9]+$ ]] && (( APP_BUILD_NUMBER <= tagged_build )); then
      fail "BUILD_NUMBER ($APP_BUILD_NUMBER) must be greater than the value at $latest_tag ($tagged_build)."
    fi
  fi

  # The release notes must exist before the artifact does.
  if ! /usr/bin/grep -Eq "^## \[$APP_VERSION\]" "$ROOT_DIR/CHANGELOG.md"; then
    fail "CHANGELOG.md lacks a '## [$APP_VERSION]' heading for this release."
  fi
}

cleanup_release() {
  local exit_code="$?"

  if [[ "$RELEASE_LOCK_ACQUIRED" -eq 1 ]]; then
    rm -f "$RELEASE_LOCK"
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    if [[ "$exit_code" -eq 0 && "$PRESERVE_WORK" -eq 0 ]]; then
      rm -rf "$WORK_DIR"
    else
      echo "Release work preserved for diagnosis at $WORK_DIR" >&2
    fi
  fi

  return "$exit_code"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

verify_release_signature() {
  local bundle="$1"
  local executable="$bundle/Contents/MacOS/$APP_NAME"
  local plist="$bundle/Contents/Info.plist"
  local metadata="$bundle/Contents/Resources/Metadata.appintents"
  local signature_info
  local entitlements

  [[ -d "$bundle" ]] || fail "Release verification failed: missing $bundle"
  [[ -x "$executable" ]] || fail "Release verification failed: missing executable."
  [[ "$(plist_value "$plist" CFBundleIdentifier)" == "$BUNDLE_ID" ]] \
    || fail "Release verification failed: bundle identifier mismatch."
  [[ "$(plist_value "$plist" CFBundleShortVersionString)" == "$APP_VERSION" ]] \
    || fail "Release verification failed: version mismatch."
  [[ "$(plist_value "$plist" CFBundleVersion)" == "$APP_BUILD_NUMBER" ]] \
    || fail "Release verification failed: build number mismatch."
  [[ "$(plist_value "$plist" LSMinimumSystemVersion)" == "$MIN_SYSTEM_VERSION" ]] \
    || fail "Release verification failed: minimum-system mismatch."
  [[ "$(lipo -archs "$executable")" == "arm64" ]] \
    || fail "Release verification failed: expected exactly arm64."
  /usr/bin/vtool -show-build "$executable" 2>/dev/null \
    | /usr/bin/grep -Eq "minos[[:space:]]+$MIN_SYSTEM_VERSION" \
    || fail "Release verification failed: binary deployment target mismatch."

  [[ -s "$metadata/version.json" && -s "$metadata/extract.actionsdata" ]] \
    || fail "Release verification failed: App Intents metadata is missing."
  /usr/bin/codesign --verify --deep --strict --verbose=4 "$bundle"

  signature_info="$(/usr/bin/codesign -dvvv "$bundle" 2>&1)"
  /usr/bin/grep -Eq 'flags=.*runtime' <<< "$signature_info" \
    || fail "Release verification failed: hardened runtime is absent."
  /usr/bin/grep -Fq "TeamIdentifier=$TASKSCOPE_EXPECTED_TEAM_ID" <<< "$signature_info" \
    || fail "Release verification failed: signing Team ID mismatch."

  entitlements="$(/usr/bin/codesign -d --entitlements - "$bundle" 2>/dev/null || true)"
  if /usr/bin/grep -q '<key>' <<< "$entitlements"; then
    fail "Release verification failed: the release unexpectedly contains entitlements."
  fi
}

verify_notarized_bundle() {
  local bundle="$1"

  verify_release_signature "$bundle"
  xcrun stapler validate "$bundle"
  /usr/sbin/spctl -a -vvv -t exec "$bundle"
}

validate_credential_independent_inputs

if [[ "$MODE" == "--preflight" || "$MODE" == "preflight" ]]; then
  echo "Credential-independent release preflight passed."
  echo "Version: $APP_VERSION ($APP_BUILD_NUMBER)"
  echo "Bundle identifier: $BUNDLE_ID"
  echo "Architecture: arm64"
  for required_name in \
    TASKSCOPE_CODE_SIGN_IDENTITY \
    TASKSCOPE_EXPECTED_TEAM_ID \
    TASKSCOPE_NOTARY_KEYCHAIN_PROFILE; do
    if [[ -z "${!required_name:-}" ]]; then
      echo "Full release still requires $required_name."
    fi
  done
  exit 0
fi

[[ -n "${TASKSCOPE_CODE_SIGN_IDENTITY:-}" ]] \
  || fail "TASKSCOPE_CODE_SIGN_IDENTITY is required."
[[ "$TASKSCOPE_CODE_SIGN_IDENTITY" == "Developer ID Application:"* ]] \
  || fail "TASKSCOPE_CODE_SIGN_IDENTITY must name a Developer ID Application identity."
[[ "${TASKSCOPE_EXPECTED_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "TASKSCOPE_EXPECTED_TEAM_ID must be a 10-character Apple Team ID."
[[ -n "${TASKSCOPE_NOTARY_KEYCHAIN_PROFILE:-}" ]] \
  || fail "TASKSCOPE_NOTARY_KEYCHAIN_PROFILE is required."

if ! /usr/bin/security find-identity -v -p codesigning \
  | /usr/bin/awk -F '"' -v expected="$TASKSCOPE_CODE_SIGN_IDENTITY" \
      '$2 == expected { found = 1 } END { exit found ? 0 : 1 }'; then
  fail "The requested Developer ID Application identity is not available with its private key."
fi

cd "$ROOT_DIR"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
  || fail "Release builds require a clean Git worktree."

xcrun notarytool history \
  --keychain-profile "$TASKSCOPE_NOTARY_KEYCHAIN_PROFILE" \
  --output-format json >/dev/null

mkdir -p "$DIST_DIR" "$RELEASE_ROOT"
if ! /usr/bin/shlock -f "$RELEASE_LOCK" -p "$$"; then
  fail "Another TaskScope release process owns $RELEASE_LOCK."
fi
RELEASE_LOCK_ACQUIRED=1
trap cleanup_release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ ! -e "$FINAL_DIR" ]] \
  || fail "Refusing to overwrite existing release output: $FINAL_DIR"

WORK_DIR="$(mktemp -d "$DIST_DIR/.$APP_NAME.release.XXXXXX")"
WORK_APP="$WORK_DIR/$APP_NAME.app"
WORK_DSYM="$WORK_DIR/$APP_NAME.dSYM"
SUBMISSION_ZIP="$WORK_DIR/$BASE_NAME-notary-submission.zip"
NOTARY_RESULT="$WORK_DIR/$BASE_NAME-notary.json"
OUTPUT_DIR="$WORK_DIR/output"
ROUND_TRIP_DIR="$WORK_DIR/round-trip"
FINAL_ZIP="$OUTPUT_DIR/$BASE_NAME.zip"
DSYM_ZIP="$OUTPUT_DIR/$BASE_NAME-dSYM.zip"
PROVENANCE="$OUTPUT_DIR/$BASE_NAME-provenance.txt"
CHECKSUMS="$OUTPUT_DIR/SHA256SUMS"

TASKSCOPE_SIGNING_STYLE=distribution \
TASKSCOPE_BUNDLE_ID="$BUNDLE_ID" \
TASKSCOPE_CODE_SIGN_IDENTITY="$TASKSCOPE_CODE_SIGN_IDENTITY" \
TASKSCOPE_VERIFIED_BUNDLE_COPY="$WORK_APP" \
BUILD_CONFIGURATION=release \
  "$ROOT_DIR/script/build_and_run.sh" --stage >/dev/null

xcrun dsymutil "$WORK_APP/Contents/MacOS/$APP_NAME" -o "$WORK_DSYM"

BINARY_UUIDS="$(dwarfdump --uuid "$WORK_APP/Contents/MacOS/$APP_NAME" | awk '{print $2, $3}')"
DSYM_UUIDS="$(dwarfdump --uuid "$WORK_DSYM" | awk '{print $2, $3}')"
[[ -n "$BINARY_UUIDS" && "$BINARY_UUIDS" == "$DSYM_UUIDS" ]] \
  || fail "Release verification failed: app and dSYM UUIDs differ."

verify_release_signature "$WORK_APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$SUBMISSION_ZIP"

xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$TASKSCOPE_NOTARY_KEYCHAIN_PROFILE" \
  --wait --output-format json > "$NOTARY_RESULT"

NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  if [[ -n "$NOTARY_ID" ]]; then
    xcrun notarytool log \
      --keychain-profile "$TASKSCOPE_NOTARY_KEYCHAIN_PROFILE" \
      "$NOTARY_ID" \
      "$WORK_DIR/$BASE_NAME-notary-log.json" || true
  fi
  fail "Notarization was not accepted (status: ${NOTARY_STATUS:-unknown})."
fi

xcrun stapler staple "$WORK_APP"
verify_notarized_bundle "$WORK_APP"

mkdir -p "$OUTPUT_DIR" "$ROUND_TRIP_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$FINAL_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK_DSYM" "$DSYM_ZIP"
/usr/bin/ditto "$NOTARY_RESULT" "$OUTPUT_DIR/$(basename "$NOTARY_RESULT")"

GIT_COMMIT="$(git rev-parse HEAD)"
XCODE_VERSION="$(xcodebuild -version | /usr/bin/awk '{printf "%s%s", separator, $0; separator="; "}')"
SWIFT_VERSION="$(swift --version | /usr/bin/awk 'NR == 1 { print; exit }')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
{
  printf 'product=%s\n' "$APP_NAME"
  printf 'version=%s\n' "$APP_VERSION"
  printf 'build=%s\n' "$APP_BUILD_NUMBER"
  printf 'bundle_id=%s\n' "$BUNDLE_ID"
  printf 'architecture=arm64\n'
  printf 'minimum_macos=%s\n' "$MIN_SYSTEM_VERSION"
  printf 'git_commit=%s\n' "$GIT_COMMIT"
  printf 'xcode=%s\n' "$XCODE_VERSION"
  printf 'swift=%s\n' "$SWIFT_VERSION"
  printf 'macos_sdk=%s\n' "$SDK_VERSION"
  printf 'signing_type=Developer ID Application\n'
  printf 'team_id=%s\n' "$TASKSCOPE_EXPECTED_TEAM_ID"
  printf 'notary_submission_id=%s\n' "$NOTARY_ID"
  printf 'notary_status=%s\n' "$NOTARY_STATUS"
  printf 'binary_uuids=%s\n' "$BINARY_UUIDS"
} > "$PROVENANCE"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$FINAL_ZIP")" \
    "$(basename "$DSYM_ZIP")" \
    "$(basename "$PROVENANCE")" \
    "$(basename "$NOTARY_RESULT")" > "$(basename "$CHECKSUMS")"
  shasum -a 256 -c "$(basename "$CHECKSUMS")"
)

/usr/bin/ditto -x -k "$FINAL_ZIP" "$ROUND_TRIP_DIR"
verify_notarized_bundle "$ROUND_TRIP_DIR/$APP_NAME.app"

mv "$OUTPUT_DIR" "$FINAL_DIR"

echo "Created verified release artifacts in $FINAL_DIR"
