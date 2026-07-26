#!/usr/bin/env bash
set -euo pipefail

OPEN_AFTER_INSTALL=1
APP_NAME="TaskScope"
BUNDLE_ID="com.local.TaskScope"

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
DEST_DIR="${DEST_DIR:-/Applications}"
DEST_BUNDLE="$DEST_DIR/$APP_NAME.app"
STAGED_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INSTALLING_BUNDLE="$DEST_DIR/.$APP_NAME.installing.$$"
BACKUP_BUNDLE="$DEST_DIR/.$APP_NAME.backup.$$"
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
  local pid
  local command
  local -a matching_pids=()

  if [[ ! -x "$executable" ]]; then
    return 0
  fi

  while read -r pid command; do
    if [[ "$command" == "$executable" || "$command" == "$executable "* ]]; then
      matching_pids+=("$pid")
    fi
  done < <(/bin/ps -axo pid=,command=)

  if [[ "${#matching_pids[@]}" -eq 0 ]]; then
    return 0
  fi

  /bin/kill -TERM "${matching_pids[@]}" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    local any_running=0
    for pid in "${matching_pids[@]}"; do
      if /bin/kill -0 "$pid" >/dev/null 2>&1; then
        any_running=1
        break
      fi
    done
    [[ "$any_running" -eq 0 ]] && return
    /bin/sleep 0.1
  done

  /bin/kill -KILL "${matching_pids[@]}" >/dev/null 2>&1 || true
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

if [[ "${TASKSCOPE_SKIP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/script/build_and_run.sh" --stage >/dev/null
fi

if [[ ! -d "$STAGED_BUNDLE" ]]; then
  echo "Build did not produce $STAGED_BUNDLE" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$STAGED_BUNDLE"

STAGED_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$STAGED_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$STAGED_ID" != "$BUNDLE_ID" ]]; then
  echo "Refusing to install staged bundle with identifier '$STAGED_ID'." >&2
  exit 1
fi

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
fail_if_requested "after_copy"

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
fail_if_requested "after_verify"

INSTALL_STATE="complete"
if [[ -d "$BACKUP_BUNDLE" ]]; then
  rm -rf "$BACKUP_BUNDLE"
fi

if [[ "$OPEN_AFTER_INSTALL" -eq 1 ]]; then
  /usr/bin/open "$DEST_BUNDLE"
fi

echo "Installed $DEST_BUNDLE"
