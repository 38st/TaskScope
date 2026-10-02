#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
INSTALL_SCRIPT="$ROOT_DIR/script/install.sh"
RELEASE_SCRIPT="$ROOT_DIR/script/release.sh"
COMMON_SCRIPT="$ROOT_DIR/script/packaging_common.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-packaging.XXXXXX")"

cleanup_test() {
  rm -rf "$TEST_DIR"
}
trap cleanup_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash -n "$BUILD_SCRIPT"
bash -n "$INSTALL_SCRIPT"
bash -n "$RELEASE_SCRIPT"
bash -n "$COMMON_SCRIPT"
source "$COMMON_SCRIPT"

(
  /bin/sleep 30 &
  identity_test_pid="$!"
  identity_test_value="$(
    taskscope_wait_for_process_identity "$identity_test_pid" 20 /bin/sleep
  )"
  identity_test_executable="$(taskscope_process_executable_path "$identity_test_pid")"
  trap 'taskscope_signal_process_if_identity_matches KILL "$identity_test_pid" "$identity_test_value" "$identity_test_executable" >/dev/null 2>&1 || true' EXIT

  if taskscope_signal_process_if_identity_matches \
    TERM "$identity_test_pid" "not-the-captured-identity" \
    "$identity_test_executable" >/dev/null 2>&1; then
    echo "Process signalling accepted a mismatched stable identity." >&2
    exit 1
  fi
  if ! /bin/kill -0 "$identity_test_pid" >/dev/null 2>&1; then
    echo "Mismatched process identity terminated the controlled process." >&2
    exit 1
  fi

  taskscope_signal_process_if_identity_matches \
    TERM "$identity_test_pid" "$identity_test_value" \
    "$identity_test_executable" >/dev/null
  wait "$identity_test_pid" 2>/dev/null || true
  trap - EXIT
)

(
  forged_executable="$TEST_DIR/Forged/TaskScope"
  mkdir -p "$(dirname "$forged_executable")"
  cp /bin/sleep "$forged_executable"

  bash -c 'exec -a "$1" /bin/sleep 30' taskscope-forged-argv "$forged_executable" &
  forged_pid="$!"
  forged_identity="$(
    taskscope_wait_for_process_identity "$forged_pid" 20 "$forged_executable"
  )"
  actual_executable="$(taskscope_process_executable_path "$forged_pid")"
  trap 'taskscope_signal_process_if_identity_matches KILL "$forged_pid" "$forged_identity" "$actual_executable" >/dev/null 2>&1 || true' EXIT

  forged_command=""
  for _ in {1..20}; do
    forged_command="$(taskscope_process_command "$forged_pid" 2>/dev/null || true)"
    [[ "$forged_command" == "$forged_executable"* ]] && break
    /bin/sleep 0.05
  done
  if [[ "$forged_command" != "$forged_executable"* ]]; then
    echo "Could not establish the forged argv0 regression fixture." >&2
    exit 1
  fi

  taskscope_stop_processes_for_executable "$forged_executable"
  if ! /bin/kill -0 "$forged_pid" >/dev/null 2>&1; then
    echo "Forged argv0 caused the wrong executable to be terminated." >&2
    exit 1
  fi
  if taskscope_signal_process_if_identity_matches \
    TERM "$forged_pid" "$forged_identity" "$forged_executable" >/dev/null 2>&1; then
    echo "Kernel executable verification accepted forged argv0." >&2
    exit 1
  fi

  taskscope_signal_process_if_identity_matches \
    TERM "$forged_pid" "$forged_identity" "$actual_executable" >/dev/null
  wait "$forged_pid" 2>/dev/null || true
  trap - EXIT
)

(
  expected_executable="$TEST_DIR/Genuine/TaskScope"
  mkdir -p "$(dirname "$expected_executable")"
  cp /bin/sleep "$expected_executable"
  # A copied platform binary is killed at launch; an ad-hoc signature runs.
  /usr/bin/codesign --force --sign - "$expected_executable" >/dev/null 2>&1

  "$expected_executable" 30 &
  expected_pid="$!"
  expected_identity="$(
    taskscope_wait_for_process_identity "$expected_pid" 20 "$expected_executable"
  )"
  trap 'taskscope_signal_process_if_identity_matches KILL "$expected_pid" "$expected_identity" "$expected_executable" >/dev/null 2>&1 || true' EXIT

  taskscope_stop_processes_for_executable "$expected_executable"
  if /bin/kill -0 "$expected_pid" >/dev/null 2>&1; then
    echo "Guarded stop helper did not terminate the genuine expected executable." >&2
    exit 1
  fi
  wait "$expected_pid" 2>/dev/null || true
  trap - EXIT
)

(
  rejected_executable="/bin/sleep"
  taskscope_list_processes() {
    printf '4242 %s 30\n' "$rejected_executable"
  }
  taskscope_process_identity() {
    printf 'captured-identity'
  }
  taskscope_process_command() {
    printf '%s 30' "$rejected_executable"
  }
  taskscope_process_matches_identity() {
    return 0
  }
  taskscope_process_matches_executable() {
    return 0
  }
  taskscope_send_signal() {
    return 1
  }
  taskscope_pause() {
    return 0
  }

  if taskscope_stop_processes_for_executable "$rejected_executable" >/dev/null 2>&1; then
    echo "Guarded stop helper reported success after every signal was rejected." >&2
    exit 1
  fi
)

RELEASE_PUBLISH_LINE="$(
  /usr/bin/grep -nF 'mv "$OUTPUT_DIR" "$FINAL_DIR"' "$RELEASE_SCRIPT" \
    | /usr/bin/cut -d: -f1
)"
if [[ -z "$RELEASE_PUBLISH_LINE" ]]; then
  echo "Release script does not publish through the expected atomic move." >&2
  exit 1
fi
if /usr/bin/tail -n "+$((RELEASE_PUBLISH_LINE + 1))" "$RELEASE_SCRIPT" \
  | /usr/bin/grep -Eq '^[[:space:]]*(shasum|verify_[[:alnum:]_]+)'; then
  echo "Release script performs fallible artifact verification after publication." >&2
  exit 1
fi

FAKE_BIN="$TEST_DIR/bin"
SWIFT_MARKER="$TEST_DIR/swift-was-called"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/swift" <<EOF
#!/usr/bin/env bash
touch "$SWIFT_MARKER"
exit 99
EOF
chmod +x "$FAKE_BIN/swift"

if PATH="$FAKE_BIN:$PATH" "$BUILD_SCRIPT" --definitely-invalid >/dev/null 2>&1; then
  echo "Invalid build mode unexpectedly succeeded." >&2
  exit 1
fi
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Invalid build mode caused a build side effect." >&2
  exit 1
fi

rm -f "$SWIFT_MARKER"
if TASKSCOPE_BUNDLE_ID='invalid bundle id' PATH="$FAKE_BIN:$PATH" \
  "$BUILD_SCRIPT" --stage >/dev/null 2>&1; then
  echo "Invalid bundle identifier unexpectedly succeeded." >&2
  exit 1
fi
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Invalid bundle identifier caused a build side effect." >&2
  exit 1
fi

rm -f "$SWIFT_MARKER"
if TASKSCOPE_BUNDLE_ID='com.example.TaskScopeTests' \
  TASKSCOPE_SIGNING_STYLE=distribution \
  TASKSCOPE_CODE_SIGN_IDENTITY='Apple Development: Not Distribution' \
  PATH="$FAKE_BIN:$PATH" "$BUILD_SCRIPT" --stage >/dev/null 2>&1; then
  echo "Distribution mode accepted a non-Developer-ID identity." >&2
  exit 1
fi
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Invalid distribution identity caused a build side effect." >&2
  exit 1
fi

RELEASE_PREFLIGHT_OUTPUT="$TEST_DIR/release-preflight.out"
if TASKSCOPE_BUNDLE_ID='com.local.TaskScope' \
  "$RELEASE_SCRIPT" --preflight >"$RELEASE_PREFLIGHT_OUTPUT" 2>&1; then
  echo "Release preflight accepted the development bundle identifier." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq \
  "Public releases cannot use the development bundle identifier 'com.local.TaskScope'." \
  "$RELEASE_PREFLIGHT_OUTPUT"; then
  echo "Release preflight did not reject the development bundle identifier." >&2
  cat "$RELEASE_PREFLIGHT_OUTPUT" >&2
  exit 1
fi
# Lifecycle evidence cases use a disposable repository, never invented passes
# in the real compatibility matrix or a managed GlobalProtect installation.
bash "$ROOT_DIR/script/test_release_compatibility.sh"

PACKAGE_LOCK="$ROOT_DIR/dist/build.noindex/.TaskScope.package.lock"
mkdir -p "$ROOT_DIR/dist/build.noindex"
/usr/bin/shlock -f "$PACKAGE_LOCK" -p "$$"
rm -f "$SWIFT_MARKER"
if TASKSCOPE_BUNDLE_ID='com.example.TaskScopeTests' PATH="$FAKE_BIN:$PATH" \
  "$BUILD_SCRIPT" --stage >/dev/null 2>&1; then
  echo "Packaging unexpectedly ignored an active packaging lock." >&2
  rm -f "$PACKAGE_LOCK"
  exit 1
fi
rm -f "$PACKAGE_LOCK"
if [[ -e "$SWIFT_MARKER" ]]; then
  echo "Packaging lock rejection caused a build side effect." >&2
  exit 1
fi

TEST_BUNDLE_ID='com.example.TaskScopeTests'
VERIFIED_COPY_DIR="$TEST_DIR/VerifiedCopy"
VERIFIED_COPY_BUNDLE="$VERIFIED_COPY_DIR/TaskScope.app"
mkdir -p "$VERIFIED_COPY_DIR"
TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  TASKSCOPE_VERIFIED_BUNDLE_COPY="$VERIFIED_COPY_BUNDLE" \
  "$BUILD_SCRIPT" --stage >/dev/null

STAGED_PLIST="$ROOT_DIR/dist/build.noindex/TaskScope.app/Contents/Info.plist"
STAGED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_PLIST")"
if [[ "$STAGED_ID" != "$TEST_BUNDLE_ID" ]]; then
  echo "Staged bundle did not use the configured identifier." >&2
  exit 1
fi
VERIFIED_COPY_ID="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$VERIFIED_COPY_BUNDLE/Contents/Info.plist"
)"
if [[ "$VERIFIED_COPY_ID" != "$TEST_BUNDLE_ID" ]]; then
  echo "Lock-protected verified bundle copy has the wrong identifier." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$VERIFIED_COPY_BUNDLE"
for stale_key in NSAppleEventsUsageDescription NSServerUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$stale_key" "$STAGED_PLIST" >/dev/null 2>&1; then
    echo "Staged bundle contains obsolete privacy key $stale_key." >&2
    exit 1
  fi
done

TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" "$BUILD_SCRIPT" --verify >/dev/null

# A startup check launches the staged bundle. It must leave no duplicate
# launcher registration even though the build folder is excluded from metadata.
swift - "$ROOT_DIR/dist/build.noindex/TaskScope.app" "$TEST_BUNDLE_ID" <<'SWIFT'
import AppKit
let stagedPath = CommandLine.arguments[1]
let bundleID = CommandLine.arguments[2]
if NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains(where: { $0.path == stagedPath }) {
    print("Startup verification left the staged app registered with Launch Services.")
    exit(1)
}
SWIFT

DEST_DIR="$TEST_DIR/Applications" TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1 && {
  echo "Install unexpectedly accepted a missing destination." >&2
  exit 1
}

TEST_APPLICATIONS="$TEST_DIR/Applications"
mkdir -p "$TEST_APPLICATIONS"
INSTALL_LOCK="$TEST_APPLICATIONS/.TaskScope.install.lock"
/usr/bin/shlock -f "$INSTALL_LOCK" -p "$$"
if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Installer unexpectedly ignored an active destination lock." >&2
  rm -f "$INSTALL_LOCK"
  exit 1
fi
rm -f "$INSTALL_LOCK"
if [[ -e "$TEST_APPLICATIONS/TaskScope.app" ]]; then
  echo "Rejected concurrent installer changed the destination." >&2
  exit 1
fi

DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null

INSTALLED_BUNDLE="$TEST_APPLICATIONS/TaskScope.app"
INSTALLED_PLIST="$INSTALLED_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 777" "$INSTALLED_PLIST"
/usr/bin/codesign --force --deep --sign - "$INSTALLED_BUNDLE" >/dev/null

for failure_point in after_copy after_backup after_replace after_verify; do
  if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
    TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TASKSCOPE_INSTALL_FAIL_AT="$failure_point" \
    "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
    echo "Injected install failure at $failure_point unexpectedly succeeded." >&2
    exit 1
  fi

  RESTORED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALLED_PLIST")"
  if [[ "$RESTORED_BUILD" != "777" ]]; then
    echo "Rollback at $failure_point did not restore the previous app bundle." >&2
    exit 1
  fi
done
/usr/bin/codesign --verify --deep --strict "$INSTALLED_BUNDLE"

if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID='com.example.DifferentTaskScope' \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Installer accepted a staged bundle identifier mismatch." >&2
  exit 1
fi

FOREIGN_APPLICATIONS="$TEST_DIR/ForeignApplications"
mkdir -p "$FOREIGN_APPLICATIONS"
/usr/bin/ditto "$INSTALLED_BUNDLE" "$FOREIGN_APPLICATIONS/TaskScope.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.ForeignApp' \
  "$FOREIGN_APPLICATIONS/TaskScope.app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$FOREIGN_APPLICATIONS/TaskScope.app" >/dev/null
if DEST_DIR="$FOREIGN_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
  TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Installer replaced an unrelated existing application." >&2
  exit 1
fi

for failure_point in after_copy after_backup after_replace after_verify; do
  FRESH_APPLICATIONS="$TEST_DIR/Fresh-$failure_point"
  mkdir -p "$FRESH_APPLICATIONS"
  if DEST_DIR="$FRESH_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 \
    TASKSCOPE_BUNDLE_ID="$TEST_BUNDLE_ID" \
    TASKSCOPE_INSTALL_FAIL_AT="$failure_point" \
    "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
    echo "Fresh install failure at $failure_point unexpectedly succeeded." >&2
    exit 1
  fi
  if [[ -e "$FRESH_APPLICATIONS/TaskScope.app" ]]; then
    echo "Fresh install failure at $failure_point left an application behind." >&2
    exit 1
  fi
done

if find "$TEST_APPLICATIONS" -maxdepth 1 \
  \( -name '.TaskScope.installing.*' -o -name '.TaskScope.backup.*' \
    -o -name '.TaskScope.install.lock' \) -print -quit | grep -q .; then
  echo "Installer left transaction artifacts behind." >&2
  exit 1
fi

"$BUILD_SCRIPT" --stage >/dev/null
DEFAULT_STAGED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_PLIST")"
if [[ "$DEFAULT_STAGED_ID" != 'com.local.TaskScope' ]]; then
  echo "Default packaging no longer uses the development bundle identifier." >&2
  exit 1
fi

echo "Packaging tests passed."
