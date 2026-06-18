#!/usr/bin/env bash
set -euo pipefail

OPEN_AFTER_INSTALL=1
APP_NAME="TaskScope"
BUNDLE_ID="com.local.TaskScope"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${DEST_DIR:-/Applications}"
DEST_BUNDLE="$DEST_DIR/$APP_NAME.app"
STAGED_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"

case "${1:-}" in
  --no-open)
    OPEN_AFTER_INSTALL=0
    ;;
  "" )
    ;;
  *)
    echo "usage: $0 [--no-open]" >&2
    exit 2
    ;;
esac

if [[ ! -d "$DEST_DIR" ]]; then
  echo "Install destination does not exist: $DEST_DIR" >&2
  exit 1
fi

if [[ ! -w "$DEST_DIR" ]]; then
  echo "Install destination is not writable: $DEST_DIR" >&2
  echo "Run with DEST_DIR set to a writable folder, or install manually with admin privileges." >&2
  exit 1
fi

"$ROOT_DIR/script/build_and_run.sh" --stage >/dev/null

if [[ ! -d "$STAGED_BUNDLE" ]]; then
  echo "Build did not produce $STAGED_BUNDLE" >&2
  exit 1
fi

/usr/bin/codesign --force --deep --sign - "$STAGED_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$STAGED_BUNDLE"

if [[ -d "$DEST_BUNDLE" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"

  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace $DEST_BUNDLE because it is not $BUNDLE_ID." >&2
    exit 1
  fi
fi

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.5

TMP_BUNDLE="$DEST_DIR/.$APP_NAME.installing.$$"
rm -rf "$TMP_BUNDLE"
/usr/bin/ditto "$STAGED_BUNDLE" "$TMP_BUNDLE"
rm -rf "$DEST_BUNDLE"
mv "$TMP_BUNDLE" "$DEST_BUNDLE"

/usr/bin/codesign --verify --deep --strict "$DEST_BUNDLE"

rm -rf "$STAGED_BUNDLE"

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  /usr/bin/open "$DEST_BUNDLE"
fi

echo "Installed $DEST_BUNDLE"
