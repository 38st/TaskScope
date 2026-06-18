# TaskScope

TaskScope is a native macOS menu bar utility for monitoring running processes and stopping selected tasks without opening Activity Monitor. It includes a GlobalProtect preset for opening, checking, and quitting the common GlobalProtect user-facing and helper processes.

It does not uninstall GlobalProtect, delete launch files, rename launch files, disable launch daemons, or control the privileged PanGPS service. TaskScope only manages the visible app and user-level helper processes.

## Build and Run

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM app, stages `dist/TaskScope.app`, and opens it as a menu-bar-only app.
It uses a Release build by default so the menu bar app runs with lower overhead.

## Install Locally

```bash
./script/install.sh
```

The installer builds a Release app, generates the icon, signs the app ad hoc for local use, verifies the signature, copies `TaskScope.app` to `/Applications`, and opens the installed copy.
After a successful install, it removes the temporary `dist/TaskScope.app` staging copy so Finder and Spotlight do not show duplicate TaskScope apps.

After installing, use the app's **Launch at Login** toggle from the installed `/Applications/TaskScope.app` copy.

## Menu Actions

- Searchable process list sorted by CPU usage
- CPU and memory columns
- Stop selected user processes after confirmation
- GlobalProtect preset for `GlobalProtect` and user-level helpers
- GlobalProtect service-health note for `PanGPS`
- Refresh Status
- Launch at Login
- Quit TaskScope

PanGPS is managed by GlobalProtect and launchd. If PanGPS is missing and GlobalProtect cannot connect to its service, reboot first, then update or reinstall GlobalProtect through your company/IT installer. TaskScope intentionally leaves that service alone.
