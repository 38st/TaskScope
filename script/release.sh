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

compatibility_failure() {
  echo "GlobalProtect lifecycle compatibility unverified: $*" >&2
  echo "Collect authorized lifecycle evidence using GLOBALPROTECT_COMPATIBILITY.md#machine-checkable-release-evidence, then rerun preflight." >&2
  fail "Until that evidence passes, retain source/development-only scope and the unverified notice in release notes; do not publish an app binary."
}

validate_compatibility_file() {
  local relative_path="$1"
  local component
  local current="$ROOT_DIR"
  local -a components

  # Only repository files are evidence. Never follow symlinks or accept paths
  # outside the checkout, including through a symlinked parent directory.
  [[ "$relative_path" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ \
    && "/$relative_path/" != *"/../"* \
    && "/$relative_path/" != *"/./"* \
    && "$relative_path" != *"//"* ]] \
    || compatibility_failure "Invalid evidence path '$relative_path'; use a repository-relative path without dot segments."
  IFS=/ read -r -a components <<< "$relative_path"
  for component in "${components[@]}"; do
    current="$current/$component"
    [[ ! -L "$current" ]] \
      || compatibility_failure "Evidence must not use symlinks: $relative_path"
  done
  [[ -f "$current" && -r "$current" && -s "$current" ]] \
    || compatibility_failure "Missing, unreadable, or empty evidence file: $relative_path"
  git -C "$ROOT_DIR" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 \
    || compatibility_failure "Evidence file is not tracked: $relative_path. Review and git add the redacted file."
}

validate_compatibility_evidence() {
  local evidence_dir="Evidence/GlobalProtect/lifecycle/$APP_VERSION-$APP_BUILD_NUMBER"
  local manifest
  local parsed
  local key
  local value
  local revision
  local count=0

  # Deliberately no environment override or skip flag: simulations and the
  # historical read-only report cannot satisfy a public-binary release gate.
  for manifest in "$ROOT_DIR/$evidence_dir/"*.evidence; do
    [[ -e "$manifest" || -L "$manifest" ]] || continue
    validate_compatibility_file "${manifest#"$ROOT_DIR/"}"
    if ! parsed="$(LC_ALL=C awk -v version="$APP_VERSION" -v build="$APP_BUILD_NUMBER" \
      -v bundle_id="$BUNDLE_ID" '
      function problem(message) {
        print FILENAME ": " message > "/dev/stderr"
        invalid = 1
      }
      function expect(key, expected) {
        if (values[key] != expected) problem(key " must be " expected ".")
      }
      BEGIN {
        n = split("schema_version evidence_kind test_date taskscope_version taskscope_build source_revision bundle_id signing_kind install_method macos_version macos_build architecture globalprotect_version agent_layout persistence_event coverage_gaps manual_results", keys, " ")
        for (i = 1; i <= n; i++) required[keys[i]] = 1
        step_count = split("baseline keep_off relaunch persistence keep_off_disabled open protected_service vpn managed_policy", steps, " ")
        for (i = 1; i <= step_count; i++) required["result_" steps[i]] = 1
        report_count = 6
        for (i = 1; i <= report_count; i++) required["report_" steps[i]] = 1
      }
      /^#/ || /^$/ { next }
      {
        separator = index($0, "=")
        key = substr($0, 1, separator - 1)
        value = substr($0, separator + 1)
        if (!separator || !(key in required)) {
          problem("line " FNR ": unknown field or malformed key=value record.")
          next
        }
        if (key in values) problem("Duplicate field: " key ".")
        if (value == "" || value ~ /[[:space:]]/) problem(key " must be a nonempty value without whitespace.")
        values[key] = value
      }
      END {
        for (key in required) if (!(key in values)) problem("Missing required field: " key ".")
        expect("schema_version", "1")
        expect("evidence_kind", "authorized-lifecycle")
        expect("taskscope_version", version)
        expect("taskscope_build", build)
        expect("bundle_id", bundle_id)
        expect("architecture", "arm64")
        expect("coverage_gaps", "none")
        if (values["test_date"] !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) problem("test_date must use YYYY-MM-DD.")
        if (values["source_revision"] !~ /^[0-9a-f]{40}$/) problem("source_revision must be a full lowercase Git commit SHA.")
        if (values["signing_kind"] !~ /^(ad-hoc|apple-development|developer-id)$/) problem("signing_kind must be ad-hoc, apple-development, or developer-id.")
        if (values["install_method"] !~ /^(staged-bundle|local-install|downloaded-archive)$/) problem("install_method must be staged-bundle, local-install, or downloaded-archive.")
        if (values["macos_version"] !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) problem("macos_version must be a numeric macOS version.")
        if (values["macos_build"] !~ /^[0-9]+[A-Z][0-9]+[a-z]?$/) problem("macos_build must be an Apple build identifier.")
        if (values["globalprotect_version"] !~ /^[0-9]+(\.[0-9]+){1,3}(-[0-9]+)?$/) problem("globalprotect_version must identify the tested version, including its suffix when present.")
        if (values["agent_layout"] !~ /^(pangpa-only|pangpa-and-pangps)$/) problem("agent_layout must be pangpa-only or pangpa-and-pangps.")
        if (values["persistence_event"] !~ /^(logout-login|reboot)$/) problem("persistence_event must be logout-login or reboot.")
        for (i = 1; i <= step_count; i++) expect("result_" steps[i], "pass")
        for (i = 1; i <= report_count; i++) {
          path = values["report_" steps[i]]
          if (path in reports) problem("Each lifecycle snapshot needs a distinct report path: " path ".")
          reports[path] = 1
        }
        if (invalid) exit 1
        print "source_revision=" values["source_revision"]
        print "artifact=" values["manual_results"]
        for (i = 1; i <= report_count; i++) print "artifact=" values["report_" steps[i]]
      }
    ' "$manifest")"; then
      compatibility_failure "Incomplete or invalid lifecycle manifest: ${manifest#"$ROOT_DIR/"}"
    fi

    while IFS='=' read -r key value; do
      if [[ "$key" == source_revision ]]; then
        revision="$value"
        git -C "$ROOT_DIR" merge-base --is-ancestor "$revision" HEAD 2>/dev/null \
          || compatibility_failure "source_revision $revision must be an existing ancestor of HEAD (or HEAD itself)."
        # Evidence can be committed after testing without a circular commit SHA.
        # Only evidence and its three release documents may change afterward.
        git -C "$ROOT_DIR" diff --quiet "$revision" -- . \
          ':(exclude)Evidence/GlobalProtect' \
          ':(exclude)GLOBALPROTECT_COMPATIBILITY.md' \
          ':(exclude)RELEASE.md' ':(exclude)CHANGELOG.md' \
          || compatibility_failure "Candidate content differs from tested source_revision $revision. Retest the current candidate and update the manifest."
      else
        [[ "$value" == "$evidence_dir/"* ]] \
          || compatibility_failure "Artifact '$value' must be retained under $evidence_dir/."
        validate_compatibility_file "$value"
      fi
    done <<< "$parsed"
    count=$((count + 1))
  done

  [[ "$count" -gt 0 ]] \
    || compatibility_failure "No lifecycle manifests found at $evidence_dir/*.evidence. Fixtures and read-only observations are insufficient."
  echo "GlobalProtect lifecycle evidence gate passed ($count tested environment(s)); claims remain limited to the recorded combinations."
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
  require_command git

  # Build numbers must increase for every distributed artifact: refuse to
  # release a build number that is not greater than every v* tag's.
  taskscope_validate_build_number_history "$ROOT_DIR" "$APP_BUILD_NUMBER" || exit 1

  # The release notes must exist before the artifact does.
  if ! /usr/bin/grep -Eq "^## \[$APP_VERSION\]" "$ROOT_DIR/CHANGELOG.md"; then
    fail "CHANGELOG.md lacks a '## [$APP_VERSION]' heading for this release."
  fi

  validate_compatibility_evidence

  require_command codesign
  require_command ditto
  require_command dwarfdump
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

  entitlements="$(/usr/bin/codesign -d --entitlements - --xml "$bundle" 2>/dev/null || true)"
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
[[ "${TASKSCOPE_EXPECTED_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "TASKSCOPE_EXPECTED_TEAM_ID must be a 10-character Apple Team ID."
[[ -n "${TASKSCOPE_NOTARY_KEYCHAIN_PROFILE:-}" ]] \
  || fail "TASKSCOPE_NOTARY_KEYCHAIN_PROFILE is required."

# Accept a name or SHA-1, then sign by SHA-1 so duplicate names are not ambiguous.
SIGNING_IDENTITY="$(taskscope_find_signing_identity "$TASKSCOPE_CODE_SIGN_IDENTITY")" \
  || fail "The requested Developer ID Application identity is not available with its private key."
[[ "${SIGNING_IDENTITY#* }" == "Developer ID Application:"* ]] \
  || fail "TASKSCOPE_CODE_SIGN_IDENTITY must name a Developer ID Application identity."
SIGNING_IDENTITY_HASH="${SIGNING_IDENTITY%% *}"

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
TASKSCOPE_CODE_SIGN_IDENTITY="$SIGNING_IDENTITY_HASH" \
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
