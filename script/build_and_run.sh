#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"

case "$MODE" in
  run|--stage|stage|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--stage|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-}"
PRODUCT_NAME="TaskScope"
APP_NAME="TaskScope"
BUNDLE_ID="com.local.TaskScope"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/AppIcon.icns"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"

read_release_value() {
  local path="$1"
  local label="$2"
  local value

  if [[ ! -f "$path" ]]; then
    echo "Missing $label source: $path" >&2
    exit 1
  fi

  value="$(tr -d '[:space:]' < "$path")"
  if [[ -z "$value" ]]; then
    echo "$label source is empty: $path" >&2
    exit 1
  fi

  printf '%s' "$value"
}

resolve_code_sign_identity() {
  if [[ -n "${TASKSCOPE_CODE_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$TASKSCOPE_CODE_SIGN_IDENTITY"
    return
  fi

  local development_identity
  development_identity="$(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk -F '"' '/Apple Development:/ { print $2; exit }'
  )"
  if [[ -n "$development_identity" ]]; then
    printf '%s' "$development_identity"
  else
    printf '%s' "-"
  fi
}

APP_VERSION="$(read_release_value "$VERSION_FILE" "version")"
APP_BUILD_NUMBER="$(read_release_value "$BUILD_NUMBER_FILE" "build number")"
CODE_SIGN_IDENTITY="$(resolve_code_sign_identity)"

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Invalid VERSION value: $APP_VERSION" >&2
  exit 1
fi

if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid BUILD_NUMBER value: $APP_BUILD_NUMBER" >&2
  exit 1
fi

if [[ -z "$BUILD_CONFIGURATION" ]]; then
  case "$MODE" in
    --debug|debug)
      BUILD_CONFIGURATION="debug"
      ;;
    *)
      BUILD_CONFIGURATION="release"
      ;;
  esac
fi

case "$BUILD_CONFIGURATION" in
  debug|release)
    ;;
  *)
    echo "BUILD_CONFIGURATION must be debug or release." >&2
    exit 2
    ;;
esac

verify_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Bundle verification failed: $key is '$actual' (expected '$expected')." >&2
    return 1
  fi
}

verify_bundle() {
  local bundle="$1"
  local contents="$bundle/Contents"
  local executable="$contents/MacOS/$APP_NAME"
  local plist="$contents/Info.plist"
  local icon="$contents/Resources/AppIcon.icns"
  local app_intents_metadata="$contents/Resources/Metadata.appintents"

  [[ -d "$bundle" ]] || {
    echo "Bundle verification failed: missing $bundle" >&2
    return 1
  }
  [[ -x "$executable" ]] || {
    echo "Bundle verification failed: missing executable $executable" >&2
    return 1
  }
  [[ -s "$icon" ]] || {
    echo "Bundle verification failed: missing icon $icon" >&2
    return 1
  }
  if ! /usr/bin/sips -g format "$icon" 2>/dev/null | /usr/bin/grep -q "format: icns"; then
    echo "Bundle verification failed: AppIcon.icns is not a valid ICNS image." >&2
    return 1
  fi

  /usr/bin/plutil -lint "$plist" >/dev/null
  verify_plist_value "$plist" "CFBundleExecutable" "$APP_NAME"
  verify_plist_value "$plist" "CFBundleIdentifier" "$BUNDLE_ID"
  verify_plist_value "$plist" "CFBundleShortVersionString" "$APP_VERSION"
  verify_plist_value "$plist" "CFBundleVersion" "$APP_BUILD_NUMBER"
  verify_plist_value "$plist" "LSMinimumSystemVersion" "$MIN_SYSTEM_VERSION"
  verify_plist_value "$plist" "CFBundleURLTypes:0:CFBundleURLSchemes:0" "taskscope"

  local obsolete_privacy_key
  for obsolete_privacy_key in NSAppleEventsUsageDescription NSServerUsageDescription; do
    if /usr/libexec/PlistBuddy -c "Print :$obsolete_privacy_key" "$plist" >/dev/null 2>&1; then
      echo "Bundle verification failed: obsolete $obsolete_privacy_key is present." >&2
      return 1
    fi
  done

  [[ -s "$app_intents_metadata/version.json" ]] || {
    echo "Bundle verification failed: App Intents version metadata is missing." >&2
    return 1
  }
  [[ -s "$app_intents_metadata/extract.actionsdata" ]] || {
    echo "Bundle verification failed: App Intents action metadata is missing." >&2
    return 1
  }
  local metadata_version
  local metadata_tools_version
  metadata_version="$(
    /usr/bin/plutil -extract version raw -o - "$app_intents_metadata/version.json" 2>/dev/null || true
  )"
  metadata_tools_version="$(
    /usr/bin/plutil -extract toolsVersion raw -o - "$app_intents_metadata/version.json" 2>/dev/null || true
  )"
  if [[ "$metadata_version" != "3.0" || -z "$metadata_tools_version" ]]; then
    echo "Bundle verification failed: App Intents version metadata is invalid." >&2
    return 1
  fi

  local metadata_path
  for metadata_path in \
    "actions.OpenWatchedAppIntent" \
    "actions.RefreshTaskScopeIntent" \
    "actions.StopWatchedAppIntent" \
    "entities.WatchedPresetEntity" \
    "queries.WatchedPresetEntityQuery"; do
    if ! /usr/bin/plutil -extract "$metadata_path" json -o - \
      "$app_intents_metadata/extract.actionsdata" >/dev/null 2>&1; then
      echo "Bundle verification failed: App Intents metadata lacks $metadata_path." >&2
      return 1
    fi
  done

  local shortcut_metadata
  shortcut_metadata="$(
    /usr/bin/plutil -extract autoShortcuts json -o - \
      "$app_intents_metadata/extract.actionsdata"
  )"
  for phrase in \
    'Refresh ${applicationName}' \
    'Stop ${app} in ${applicationName}' \
    'Open ${app} in ${applicationName}'; do
    if ! /usr/bin/grep -Fq "$phrase" <<< "$shortcut_metadata"; then
      echo "Bundle verification failed: App Shortcut phrase '$phrase' is missing." >&2
      return 1
    fi
  done

  /usr/bin/codesign --verify --deep --strict "$bundle"
}

verify_startup_readiness() {
  local bundle="$1"
  local executable="$bundle/Contents/MacOS/$APP_NAME"
  local verify_pid=""
  local attempt
  local registered_bundle_id=""
  local is_ready=0

  "$executable" --automation >/dev/null 2>&1 &
  verify_pid="$!"

  cleanup_readiness_process() {
    if [[ -n "$verify_pid" ]] && /bin/kill -0 "$verify_pid" >/dev/null 2>&1; then
      /bin/kill -TERM "$verify_pid" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        if ! /bin/kill -0 "$verify_pid" >/dev/null 2>&1; then
          wait "$verify_pid" 2>/dev/null || true
          return
        fi
        /bin/sleep 0.1
      done
      /bin/kill -KILL "$verify_pid" >/dev/null 2>&1 || true
      wait "$verify_pid" 2>/dev/null || true
    fi
  }
  trap cleanup_readiness_process EXIT

  for attempt in {1..50}; do
    if ! /bin/kill -0 "$verify_pid" >/dev/null 2>&1; then
      wait "$verify_pid" 2>/dev/null || true
      echo "Bundle verification failed: packaged app exited during startup." >&2
      return 1
    fi

    registered_bundle_id="$(
      /usr/bin/lsappinfo info -only bundleid -app "$verify_pid" 2>/dev/null || true
    )"
    if [[ "$registered_bundle_id" == *"$BUNDLE_ID"* ]]; then
      is_ready=1
      break
    fi

    /bin/sleep 0.1
  done

  if [[ "$is_ready" -ne 1 ]]; then
    echo "Bundle verification failed: app did not register with Launch Services within 5 seconds." >&2
    return 1
  fi

  cleanup_readiness_process
  trap - EXIT
}

stop_staged_app_instances() {
  local executable="$APP_BINARY"
  local pid
  local command
  local -a matching_pids=()

  while read -r pid command; do
    if [[ "$command" == "$executable" || "$command" == "$executable "* ]]; then
      matching_pids+=("$pid")
    fi
  done < <(/bin/ps -axo pid=,command=)

  if [[ "${#matching_pids[@]}" -eq 0 ]]; then
    return
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

cd "$ROOT_DIR"
STAGING_BUNDLE="$DIST_DIR/.$APP_NAME.staging.$$"
STAGING_CONTENTS="$STAGING_BUNDLE/Contents"
STAGING_MACOS="$STAGING_CONTENTS/MacOS"
STAGING_RESOURCES="$STAGING_CONTENTS/Resources"
STAGING_BINARY="$STAGING_MACOS/$APP_NAME"
STAGING_PLIST="$STAGING_CONTENTS/Info.plist"
STAGING_ICON="$STAGING_RESOURCES/AppIcon.icns"
METADATA_BUILD_CONFIGURATION="release"
METADATA_WORK_DIR="$ROOT_DIR/.build/taskscope-app-intents/$METADATA_BUILD_CONFIGURATION"
APP_INTENTS_CONST_VALUES="$METADATA_WORK_DIR/TaskScope.swiftconstvalues"
APP_INTENTS_SOURCE_LIST="$METADATA_WORK_DIR/app-intents-sources.txt"
APP_INTENTS_CONST_LIST="$METADATA_WORK_DIR/app-intents-const-values.txt"
APP_INTENTS_PROTOCOLS="$METADATA_WORK_DIR/app-intents-protocols.json"

cleanup_packaging_work() {
  if [[ -d "$STAGING_BUNDLE" ]]; then
    rm -rf "$STAGING_BUNDLE"
  fi
}
trap cleanup_packaging_work EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_BUNDLE"
mkdir -p "$METADATA_WORK_DIR"

TOOLCHAIN_DIR="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
APP_INTENTS_PROTOCOL_SOURCE="$TOOLCHAIN_DIR/usr/share/swift/SwiftConstantValues/AppIntents.json"
if [[ ! -s "$APP_INTENTS_PROTOCOL_SOURCE" ]]; then
  echo "Missing App Intents compiler protocol metadata: $APP_INTENTS_PROTOCOL_SOURCE" >&2
  exit 1
fi
/usr/bin/plutil -extract constValueProtocols json -o "$APP_INTENTS_PROTOCOLS" \
  "$APP_INTENTS_PROTOCOL_SOURCE"

if [[ "$BUILD_CONFIGURATION" == "debug" ]]; then
  swift build -c debug --disable-index-store
fi

swift build -c "$METADATA_BUILD_CONFIGURATION" --disable-index-store \
  -Xswiftc -emit-const-values \
  -Xswiftc -Xfrontend \
  -Xswiftc -const-gather-protocols-file \
  -Xswiftc -Xfrontend \
  -Xswiftc "$APP_INTENTS_PROTOCOLS" \
  -Xswiftc -emit-const-values-path \
  -Xswiftc "$APP_INTENTS_CONST_VALUES"
BUILD_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/$PRODUCT_NAME"

if [[ ! -s "$APP_INTENTS_CONST_VALUES" ]]; then
  echo "App Intents constant-value extraction produced no metadata." >&2
  exit 1
fi

printf '%s\n' "$ROOT_DIR/Sources/TaskScope/Services/TaskScopeIntents.swift" > "$APP_INTENTS_SOURCE_LIST"
printf '%s\n' "$APP_INTENTS_CONST_VALUES" > "$APP_INTENTS_CONST_LIST"

mkdir -p "$STAGING_MACOS" "$STAGING_RESOURCES"
cp "$BUILD_BINARY" "$STAGING_BINARY"
chmod +x "$STAGING_BINARY"

swift "$ROOT_DIR/script/render_icon.swift" "$STAGING_ICON"

/usr/libexec/PlistBuddy -c "Clear dict" "$STAGING_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD_NUMBER" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_SYSTEM_VERSION" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool false" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass string NSApplication" "$STAGING_PLIST"

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string $BUNDLE_ID" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$STAGING_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string taskscope" "$STAGING_PLIST"

APP_INTENTS_PROCESSOR="$(xcrun --find appintentsmetadataprocessor)"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
XCODE_BUILD_VERSION="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
TARGET_TRIPLE="$(uname -m)-apple-macos${MIN_SYSTEM_VERSION}"

"$APP_INTENTS_PROCESSOR" \
  --output "$STAGING_RESOURCES" \
  --toolchain-dir "$TOOLCHAIN_DIR" \
  --module-name "$PRODUCT_NAME" \
  --sdk-root "$SDK_ROOT" \
  --xcode-version "$XCODE_BUILD_VERSION" \
  --platform-family macOS \
  --deployment-target "$MIN_SYSTEM_VERSION" \
  --target-triple "$TARGET_TRIPLE" \
  --source-file-list "$APP_INTENTS_SOURCE_LIST" \
  --swift-const-vals-list "$APP_INTENTS_CONST_LIST" \
  --force \
  --no-app-shortcuts-localization

/usr/bin/codesign --force --deep --timestamp=none --sign "$CODE_SIGN_IDENTITY" "$STAGING_BUNDLE"
verify_bundle "$STAGING_BUNDLE"

rm -rf "$APP_BUNDLE"
mv "$STAGING_BUNDLE" "$APP_BUNDLE"
trap - EXIT INT TERM

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --stage|stage)
    echo "$APP_BUNDLE"
    ;;
  run)
    stop_staged_app_instances
    open_app
    ;;
  --debug|debug)
    stop_staged_app_instances
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_staged_app_instances
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_staged_app_instances
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    verify_bundle "$APP_BUNDLE"
    verify_startup_readiness "$APP_BUNDLE"
    echo "Verified $APP_BUNDLE"
    ;;
esac
