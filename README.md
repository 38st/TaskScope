# TaskScope

TaskScope is a native macOS process monitor and task controller that lives in the Dock and menu bar. It combines a searchable process list with watched-app presets, lifecycle controls, saved selections, auto-stop rules, notifications, Shortcuts actions, and process-history charts.

TaskScope includes a GlobalProtect preset. It can open the GlobalProtect app, manage its configured user launch agent, and request macOS administrator approval when the protected `PanGPS` service must be restored. It does not uninstall GlobalProtect, delete or rename launch files, or stop the protected system daemon during a normal close operation.

## Requirements

- macOS 14 or newer
- Xcode Command Line Tools with Swift tools 5.9 or newer
- A writable install destination; `/Applications` may require administrator-managed permissions

SwiftPM builds the executable for the current Mac architecture. The packaging scripts create a locally ad-hoc-signed app; they do not produce a Developer ID-signed, notarized, universal distribution.

## Build, verify, and run

Run the default release build, stage `dist/TaskScope.app`, and open it:

```bash
./script/build_and_run.sh
```

Other modes:

```bash
./script/build_and_run.sh --stage       # build and stage without opening or stopping a running app
./script/build_and_run.sh --verify      # validate the bundle and run its deterministic startup check
./script/build_and_run.sh --debug       # build debug and start the executable in LLDB
./script/build_and_run.sh --logs        # open the staged app and stream its process logs
./script/build_and_run.sh --telemetry   # open the staged app and stream its subsystem logs
```

Set `BUILD_CONFIGURATION=debug` or `BUILD_CONFIGURATION=release` to override the build configuration where appropriate. The version and build shown by Finder and About TaskScope come from `VERSION` and `BUILD_NUMBER`.

Run the source-level checks directly with:

```bash
swift test
swift build -c release
bash -n script/*.sh
```

## Install locally

Build and install the app:

```bash
./script/install.sh
```

Use `--no-open` to install without launching. Set `DEST_DIR` to install into another existing writable directory:

```bash
DEST_DIR="$PWD/local-apps" ./script/install.sh --no-open
```

The installer validates the staged bundle, preserves an existing TaskScope installation until replacement succeeds, and restores it if replacement fails. After installing, enable **Launch at Login** in TaskScope settings if wanted.

## Features

- Search, filter, and sort processes by CPU, memory, name, or PID.
- Switch between flat and expandable process-tree views.
- Inspect process details, copy a command, or locate a process in Activity Monitor.
- Select visible processes and review immutable targets before sending a normal Stop (`SIGTERM`) or explicit Force Stop (`SIGKILL`).
- Save selections using durable command/name matching, preview matches, and manage saved names.
- Create, edit, reorder, import, and export watched-app presets, including optional user-agent and system-daemon lifecycle jobs.
- Open or close watched apps through one verified lifecycle path with per-job result reporting.
- Create prompt, auto-stop, or log-only runtime rules with a persistent event history.
- View continuously sampled process CPU and RSS history with Live, Paused, and Unavailable states.
- Opt into watched-process notifications and recover from denied notification permission in System Settings.
- Show TaskScope using a configurable global keyboard shortcut; the default is Command-Shift-T.
- Start nonintrusively at login or for automation.

Normal process actions never target TaskScope itself. Selection and automation targets are revalidated against process identity immediately before an action.

## URL automation

The packaged app registers the `taskscope` URL scheme. Preset lookup accepts either the preset display name or its main process name, case-insensitively. Percent-encode spaces and other URL path characters.

```bash
open "taskscope://refresh"
open "taskscope://open/GlobalProtect"
open "taskscope://stop/GlobalProtect"
open "taskscope://quit"
```

The supported routes are:

- `taskscope://refresh` — refresh watched-app status.
- `taskscope://open/<preset>` — run the preset's managed open lifecycle.
- `taskscope://stop/<preset>` — stop the preset's configured killable app and helper processes.
- `taskscope://quit` — quit TaskScope.

Unknown routes and missing preset targets are rejected. Commands received during cold launch are queued until the single application command runtime is ready.

## Shortcuts

After the packaged app is installed and launched, macOS Shortcuts can discover:

- **Refresh TaskScope**
- **Open Watched App**
- **Stop Watched App**

Open and Stop use a watched-app entity chosen from the presets stored in TaskScope. The App Shortcut phrases bind that preset to the action, and all three actions use the same lifecycle and result reporting as the app and URL routes.

## Permissions and behavior notes

- Activity Monitor integration asks macOS for Apple Events automation permission the first time selection is requested. If permission is denied, Activity Monitor still opens and TaskScope reports how to recover.
- Notifications are off on a new install and are requested only after explicit opt-in.
- Some process details and extended network/disk counters may be unavailable under macOS privacy or tool limitations; TaskScope displays an unavailable value rather than a fabricated zero.
- Watched-app lifecycle jobs must name existing `.plist` paths and a valid `.app` bundle. Protected daemon operations can require administrator approval.
- Auto Stop is intentionally destructive. Use Prompt or Log Only while validating a new rule.
- GlobalProtect file locations, job labels, and managed-service behavior are controlled by the installed GlobalProtect version and your organization. If its protected service cannot be restored, use your company/IT installer or support process.

## Local packaging limitation

`script/build_and_run.sh` and `script/install.sh` are development and personal-install workflows. The staged app uses the local bundle identifier `com.local.TaskScope`, is ad-hoc signed, and is not notarized. External distribution requires an owned bundle identifier, Developer ID signing, hardened runtime/notarization, and an architecture/release strategy outside these scripts.
