#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
INSTALL_SCRIPT="$ROOT_DIR/script/install.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-packaging.XXXXXX")"

cleanup_test() {
  rm -rf "$TEST_DIR"
}
trap cleanup_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash -n "$BUILD_SCRIPT"
bash -n "$INSTALL_SCRIPT"

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

"$BUILD_SCRIPT" --stage >/dev/null

STAGED_PLIST="$ROOT_DIR/dist/TaskScope.app/Contents/Info.plist"
for stale_key in NSAppleEventsUsageDescription NSServerUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$stale_key" "$STAGED_PLIST" >/dev/null 2>&1; then
    echo "Staged bundle contains obsolete privacy key $stale_key." >&2
    exit 1
  fi
done

"$BUILD_SCRIPT" --verify >/dev/null

DEST_DIR="$TEST_DIR/Applications" "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1 && {
  echo "Install unexpectedly accepted a missing destination." >&2
  exit 1
}

TEST_APPLICATIONS="$TEST_DIR/Applications"
mkdir -p "$TEST_APPLICATIONS"
DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 "$INSTALL_SCRIPT" --no-open >/dev/null

INSTALLED_BUNDLE="$TEST_APPLICATIONS/TaskScope.app"
INSTALLED_PLIST="$INSTALLED_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 777" "$INSTALLED_PLIST"
/usr/bin/codesign --force --deep --sign - "$INSTALLED_BUNDLE" >/dev/null

if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 TASKSCOPE_INSTALL_FAIL_AT=after_backup \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Injected install failure unexpectedly succeeded." >&2
  exit 1
fi

RESTORED_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALLED_PLIST")"
if [[ "$RESTORED_BUILD" != "777" ]]; then
  echo "Rollback did not restore the previous app bundle." >&2
  exit 1
fi

if DEST_DIR="$TEST_APPLICATIONS" TASKSCOPE_SKIP_BUILD=1 TASKSCOPE_INSTALL_FAIL_AT=after_replace \
  "$INSTALL_SCRIPT" --no-open >/dev/null 2>&1; then
  echo "Post-replacement injected failure unexpectedly succeeded." >&2
  exit 1
fi

RESTORED_AFTER_REPLACE="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALLED_PLIST"
)"
if [[ "$RESTORED_AFTER_REPLACE" != "777" ]]; then
  echo "Post-replacement rollback did not restore the previous app bundle." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$INSTALLED_BUNDLE"

if find "$TEST_APPLICATIONS" -maxdepth 1 \
  \( -name '.TaskScope.installing.*' -o -name '.TaskScope.backup.*' \) -print -quit | grep -q .; then
  echo "Installer left transaction artifacts behind." >&2
  exit 1
fi

echo "Packaging tests passed."
