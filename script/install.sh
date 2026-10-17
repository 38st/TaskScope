#!/usr/bin/env bash
set -euo pipefail

OPEN_AFTER_INSTALL=1
APP_NAME="TaskScope"

case "${1:-}" in
  --no-open)
    OPEN_AFTER_INSTALL=0
    ;;
  "")
    ;;
  *)
    echo "usage: $0 [--no-open]" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/packaging_common.sh"
BUNDLE_ID="$(taskscope_resolve_bundle_id)"
DEST_DIR="${DEST_DIR:-/Applications}"
DEST_BUNDLE="$DEST_DIR/$APP_NAME.app"
STAGED_BUNDLE="$ROOT_DIR/dist/build.noindex/$APP_NAME.app"
INSTALLING_BUNDLE="$DEST_DIR/.$APP_NAME.installing.$$"
BACKUP_BUNDLE="$DEST_DIR/.$APP_NAME.backup.$$"
INSTALL_LOCK="$DEST_DIR/.$APP_NAME.install.lock"
INSTALL_LOCK_ACQUIRED=0
PACKAGING_LOCK="$ROOT_DIR/dist/build.noindex/.$APP_NAME.package.lock"
PACKAGING_LOCK_ACQUIRED=0
INSTALL_STATE="preparing"

cleanup_install() {
  local exit_code="$?"

  if [[ "$exit_code" -ne 0 ]]; then
    case "$INSTALL_STATE" in
      backing-up|backed-up|replacing|replaced)
        if [[ -d "$BACKUP_BUNDLE" ]]; then
          rm -rf "$DEST_BUNDLE"
          mv "$BACKUP_BUNDLE" "$DEST_BUNDLE"
          echo "Install failed; restored the previous $DEST_BUNDLE." >&2
        fi
        ;;
      installing|installed)
        rm -rf "$DEST_BUNDLE"
        echo "Install failed; removed the incomplete $DEST_BUNDLE." >&2
        ;;
    esac
  fi

  if [[ -d "$INSTALLING_BUNDLE" ]]; then
    rm -rf "$INSTALLING_BUNDLE"
  fi

  if [[ "$INSTALL_STATE" == "complete" && -d "$BACKUP_BUNDLE" ]]; then
    rm -rf "$BACKUP_BUNDLE"
  fi
  if [[ "$INSTALL_LOCK_ACQUIRED" -eq 1 ]]; then
    rm -f "$INSTALL_LOCK"
  fi
  if [[ "$PACKAGING_LOCK_ACQUIRED" -eq 1 ]]; then
    rm -f "$PACKAGING_LOCK"
  fi

  exit "$exit_code"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_if_requested() {
  local point="$1"
  if [[ "${TASKSCOPE_INSTALL_FAIL_AT:-}" == "$point" ]]; then
    echo "Injected install failure at $point." >&2
    return 1
  fi
}

stop_destination_app() {
  local executable="$DEST_BUNDLE/Contents/MacOS/$APP_NAME"

  if [[ ! -x "$executable" ]]; then
    return 0
  fi

  taskscope_stop_processes_for_executable "$executable"
}

verify_install_bundle_metadata() {
  local bundle="$1"
  local key
  local expected
  local actual

  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
    case "$key" in
      CFBundleIdentifier) expected="$BUNDLE_ID" ;;
      CFBundleShortVersionString) expected="$APP_VERSION" ;;
      CFBundleVersion) expected="$APP_BUILD_NUMBER" ;;
    esac
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$actual" != "$expected" ]]; then
      echo "Refusing to install $bundle: $key is '$actual' (expected '$expected')." >&2
      return 1
    fi
  done
}

if [[ ! -d "$DEST_DIR" ]]; then
  echo "Install destination does not exist: $DEST_DIR" >&2
  exit 1
fi

if [[ ! -w "$DEST_DIR" ]]; then
  echo "Install destination is not writable: $DEST_DIR" >&2
  echo "Run with DEST_DIR set to a writable folder, or install manually with admin privileges." >&2
  exit 1
fi

if ! /usr/bin/shlock -f "$INSTALL_LOCK" -p "$$"; then
  echo "Another TaskScope installer owns $INSTALL_LOCK." >&2
  exit 1
fi
INSTALL_LOCK_ACQUIRED=1

if [[ "${TASKSCOPE_SKIP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/script/build_and_run.sh" --stage >/dev/null
fi

# The stage child releases its lock on exit. Acquire it again before reading
# the shared bundle, including when the caller deliberately skips the build.
mkdir -p "$(dirname "$PACKAGING_LOCK")"
if ! /usr/bin/shlock -f "$PACKAGING_LOCK" -p "$$"; then
  echo "Another TaskScope packaging process owns $PACKAGING_LOCK." >&2
  exit 1
fi
PACKAGING_LOCK_ACQUIRED=1
APP_VERSION="$(taskscope_read_release_value "$ROOT_DIR/VERSION" "version")"
APP_BUILD_NUMBER="$(taskscope_read_release_value "$ROOT_DIR/BUILD_NUMBER" "build number")"

if [[ ! -d "$STAGED_BUNDLE" ]]; then
  echo "Build did not produce $STAGED_BUNDLE" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$STAGED_BUNDLE"

verify_install_bundle_metadata "$STAGED_BUNDLE"

if [[ -d "$DEST_BUNDLE" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace $DEST_BUNDLE because it is not $BUNDLE_ID." >&2
    exit 1
  fi
fi

rm -rf "$INSTALLING_BUNDLE" "$BACKUP_BUNDLE"
/usr/bin/ditto "$STAGED_BUNDLE" "$INSTALLING_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$INSTALLING_BUNDLE"
verify_install_bundle_metadata "$INSTALLING_BUNDLE"
fail_if_requested "after_copy"

# The private copy is now validated; destination replacement needs only the
# installer lock and no longer depends on the shared staged bundle.
rm -f "$PACKAGING_LOCK"
PACKAGING_LOCK_ACQUIRED=0

stop_destination_app

if [[ -d "$DEST_BUNDLE" ]]; then
  INSTALL_STATE="backing-up"
  mv "$DEST_BUNDLE" "$BACKUP_BUNDLE"
  INSTALL_STATE="backed-up"
fi
fail_if_requested "after_backup"

if [[ "$INSTALL_STATE" == "backed-up" ]]; then
  INSTALL_STATE="replacing"
else
  INSTALL_STATE="installing"
fi
mv "$INSTALLING_BUNDLE" "$DEST_BUNDLE"
if [[ "$INSTALL_STATE" == "replacing" ]]; then
  INSTALL_STATE="replaced"
else
  INSTALL_STATE="installed"
fi
fail_if_requested "after_replace"

/usr/bin/codesign --verify --deep --strict "$DEST_BUNDLE"
verify_install_bundle_metadata "$DEST_BUNDLE"
fail_if_requested "after_verify"

INSTALL_STATE="complete"
if [[ -d "$BACKUP_BUNDLE" ]]; then
  rm -rf "$BACKUP_BUNDLE"
fi

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  taskscope_require_no_other_app_instance "$DEST_BUNDLE" "$BUNDLE_ID"
  /usr/bin/open "$DEST_BUNDLE"
fi

echo "Installed $DEST_BUNDLE"
